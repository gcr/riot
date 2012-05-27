#lang racket/base
(require racket/contract
         racket/list
         racket/match
         racket/tcp
         racket/async-channel
         racket/date
         mzlib/thread
         file/md5)

;; A queue is a list of workunits along with an asynchronous channel
;; that serializes unsafe actions on that queue.
(struct queue (workunits clients-waiting-for-work) #:mutable)

(define workunit-key? any/c)
(define workunit-status? (or/c 'waiting 'running 'done 'error))

;; A workunit is a (potentially completed) item of work to be handed
;; out to clients.
(struct workunit (key
                  status
                  client
                  result
                  data
                  on-complete-thunks
                  last-status-change)
        #:mutable)

(provide (struct-out workunit))
(provide/contract
 [start-queue-server (-> exact-integer? any/c)]
 ;; don't use these:
 [make-queue (-> queue?)]
 [queue-ref (-> queue? workunit-key? (or/c workunit? #f))]
 [make-workunit-key (-> any/c workunit-key?)]
 [queue-add-workunit! (-> queue? workunit-key? any/c any/c)]
 [queue-on-workunit-completion (-> queue? workunit-key? any/c any/c)]
 [queue-call-with-work! (-> queue? any/c (-> workunit-key? boolean?) any/c)]
 [queue-complete-workunit! (-> queue? workunit-key? boolean? any/c any/c)])

(define (make-queue)
  (queue (make-hash) (list)))

;; Get the given workunit.
(define (queue-ref queue key [default #f])
  (hash-ref (queue-workunits queue) key default))

(define (make-workunit-key data)
  (bytes->string/utf-8 (md5 (format "~s" data))))

(define (queue-pick-workunit queue status)
  (for/first ([(key wu) (in-hash (queue-workunits queue))]
              #:when (eq? status (workunit-status wu)))
    wu))

(define (queue-dispatch-work! queue)
  ;; If there are clients waiting for work, well send it to them gosh
  ;; golly
  (when (not (empty? (queue-clients-waiting-for-work queue)))
    (define next-wu (queue-pick-workunit queue 'waiting))
    (when next-wu
      (match-define (list client client-thunk)
                    (first (queue-clients-waiting-for-work queue)))
      (set-queue-clients-waiting-for-work!
       queue
       (rest (queue-clients-waiting-for-work queue)))
      ;; The client thunk can choose to reject this workunit, for
      ;; example if the client disconnects before we can give them
      ;; something to work on. In that case, we'll just remove their
      ;; thunk from our list of idle clients.
      (when (client-thunk next-wu)
        (set-workunit-status! next-wu 'running)
        (set-workunit-client! next-wu client)
        (set-workunit-last-status-change!
         next-wu
         (current-inexact-milliseconds)))
      (queue-dispatch-work! queue))))

;; Add work to the queue
(define (queue-add-workunit! queue key data)
  (unless (hash-has-key? (queue-workunits queue) key)
    (define wu (workunit key 'waiting #f #f data '()
                         (current-inexact-milliseconds)))
    (hash-set! (queue-workunits queue) key wu)
    (queue-dispatch-work! queue))
  key)

;; Call thunk with a workunit key when there's more work available.
;; A client will call this to register their willingness to perform
;; work, for example.
(define (queue-call-with-work! queue client thunk)
  (define client-thunk-data (list client thunk))
  (set-queue-clients-waiting-for-work!
   queue
   (append (queue-clients-waiting-for-work queue)
           (list client-thunk-data)))
  (queue-dispatch-work! queue))

;; Add a thunk to be called when the given workunit finishes.
(define (queue-on-workunit-completion queue key thunk)
  (define wu (queue-ref queue key))
  (when wu
    (case (workunit-status wu)
     [(done error) (thunk wu)]
     [else (set-workunit-on-complete-thunks! wu
            (cons thunk (workunit-on-complete-thunks wu)))])))

;; Called when a client finishes a workunit.
(define (queue-complete-workunit! queue key error? result)
  (define wu (queue-ref queue key))
  (when wu
    (set-workunit-status! wu (if error? 'error 'done))
    (set-workunit-result! wu result)
    (set-workunit-last-status-change! wu
     (current-inexact-milliseconds))
    (for ([thunk (in-list (workunit-on-complete-thunks wu))])
      (thunk wu))
    (set-workunit-on-complete-thunks! wu '())))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The actual server.


(define (start-queue-server port)
  (date-display-format 'iso-8601)
  (define (log . msg)
    (printf "[~a] ~a\n" (date->string (current-date) (current-seconds))
            (apply format msg))
    (flush-output))
  (define chan (make-async-channel))
  (define q (make-queue))
  (thread (λ() (let loop () ((async-channel-get chan)) (loop))))
  ;; put thunks on this channel to execute them.
  (define (handle-cxn in out)
    (define handler-cust (current-custodian))
    (define-syntax-rule (errguard-λ (args ...) body ...)
      (λ (args ...)
         (with-handlers ([exn:fail:network? (λ(ex) (displayln "Net err"))]
                         [exn:fail?
                          (λ(ex)
                            ((error-display-handler)
                             (format "Client error: ~a"
                                     (exn-message ex))
                             ex)
                            (flush-output)
                            (custodian-shutdown-all handler-cust)
                            #f)])
           body ...)))
    (define-syntax-rule (q-action body ...)
      (async-channel-put chan
                         (errguard-λ () body ...)))
    (custodian-limit-memory handler-cust (* 10 1024 1024))
    (define (send datum)
      (write datum out)
      (display "\n" out)
      (flush-output out))
    (let/ec exit
      (match-define (list 'hello-from client) (read in))
      (define-values (my-ip your-ip) (tcp-addresses out))
      (log "new connection: ~s ip: ~a" client your-ip)
      (let loop ()
        (match (read in)
          [(? eof-object?) (log "disconnect: ~a" client) (exit)]
          [(list 'workunit-info wu-key)
           (q-action
            (define wu (queue-ref q wu-key))
            (match-define
             (workunit key status wu-client result data _ last-change)
             (or wu (workunit wu-key #f #f #f #f #f #f)))
            (send (list 'workunit key status wu-client result last-change)))]
          [(list 'wait-for-work)
           (log "~s is waiting for work" client)
           (q-action
            (queue-call-with-work! q client
              (errguard-λ (wu)
                 (log "assigned ~a to ~s" (workunit-key wu) client)
                 (send (list 'assigned-workunit
                             (workunit-key wu)
                             (workunit-data wu)))
                 (flush-output)
                 #t ;; accept this one
                 )))]
          [(list 'add-workunit! data)
           (q-action
            (define new-key (make-workunit-key data))
            (log "workunit: ~a" new-key)
            (queue-add-workunit! q new-key data)
            (send (list 'added-workunit new-key)))]
          [(list 'monitor-workunit-completion key)
           (q-action
            (queue-on-workunit-completion
             q
             key
             (errguard-λ (wu)
               (send (list 'workunit-complete
                           key
                           (workunit-status wu) ;; may be error, for ex
                           (workunit-result wu))))))]
          [(list 'complete-workunit! key error? result)
           (if error?
               (log "~s FAILED workunit: ~a" client key)
               (log "~s completed workunit: ~a" client key))
           (q-action
            (queue-complete-workunit! q key error? result))]
          [other (error "wasn't expecting this from client:" other)])
        (loop))))
  (log "Listening for connections on port ~a" port)
  (run-server port handle-cxn #f))