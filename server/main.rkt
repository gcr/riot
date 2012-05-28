#lang racket/base
(require racket/contract
         racket/list
         racket/match
         racket/tcp
         racket/async-channel
         racket/date
         data/queue
         mzlib/thread
         file/md5)

;; A workunit tracker is a hash of workunits along with a queue for
;; workunits waiting for a client and another queue for clients
;; waiting for a workunit.
(struct tracker (workunits
                 pending-workunits
                 pending-clients) #:mutable)

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
(define workunit-key? any/c)
(define workunit-status? (or/c 'waiting 'running 'done 'error))

(provide (struct-out workunit))
(provide/contract
 [start-tracker-server (-> exact-integer? any/c)]
 ;; don't use these:
 [make-tracker (-> tracker?)]
 [tracker-workunit-ref (-> tracker? workunit-key? (or/c workunit? #f))]
 [make-workunit-key (-> any/c workunit-key?)]
 [tracker-add-workunit! (-> tracker? workunit-key? any/c any/c)]
 [tracker-on-workunit-completion (-> tracker? workunit-key? any/c any/c)]
 [tracker-call-with-work! (-> tracker? any/c (-> workunit-key? boolean?) any/c)]
 [tracker-complete-workunit! (-> tracker? workunit-key? boolean? any/c any/c)]
 [remove-running-workunits! (-> tracker? any/c any/c)])

(define (make-tracker)
  (tracker (make-hash) (make-queue) (make-queue)))

;; Get the given workunit.
(define (tracker-workunit-ref tracker key [default #f])
  (hash-ref (tracker-workunits tracker) key default))

;; Hash the data to make a key.
(define (make-workunit-key data)
  (bytes->string/utf-8 (md5 (format "~s" data))))

(define (tracker-dispatch-work! tracker)
  ;; If there are clients waiting for work, well send it to them gosh
  ;; golly
  (unless (or (queue-empty? (tracker-pending-clients tracker))
              (queue-empty? (tracker-pending-workunits tracker)))
    (define workunit (dequeue! (tracker-pending-workunits tracker)))
    (match-define (list client client-thunk)
                  (dequeue! (tracker-pending-clients tracker)))
    (when (equal? 'waiting (workunit-status workunit))
      ;; The client thunk can choose to reject this workunit, for
      ;; example if the client disconnects before we can give them
      ;; something to work on. In that case, we'll just remove their
      ;; thunk from our list of idle clients.
      (cond
       [(client-thunk workunit)
        (set-workunit-status! workunit 'running)
        (set-workunit-client! workunit client)
        (set-workunit-last-status-change! workunit
         (current-inexact-milliseconds))]
       ;; If the client thunk rejected it, put it back on the queue!
       [else (enqueue! (tracker-pending-workunits tracker) workunit)])
      (tracker-dispatch-work! tracker))))

;; Add work to the tracker
(define (tracker-add-workunit! tracker key data)
  (when (or (not (hash-has-key? (tracker-workunits tracker) key))
            (equal? 'error (workunit-status (tracker-workunit-ref
                                             tracker key))))
    (define wu (workunit key 'waiting #f #f data '()
                         (current-inexact-milliseconds)))
    (hash-set! (tracker-workunits tracker) key wu)
    (enqueue! (tracker-pending-workunits tracker) wu)
    (tracker-dispatch-work! tracker))
  key)

;; Call thunk with a workunit key when there's more work available.
;; A client will call this to register their willingness to perform
;; work, for example.
(define (tracker-call-with-work! tracker client thunk)
  (define client-thunk-data (list client thunk))
  (enqueue! (tracker-pending-clients tracker)
            client-thunk-data)
  (tracker-dispatch-work! tracker))

;; Add a thunk to be called when the given workunit finishes.
(define (tracker-on-workunit-completion tracker key thunk)
  (define wu (tracker-workunit-ref tracker key))
  (when wu
    (case (workunit-status wu)
     [(done error) (thunk wu)]
     [else (set-workunit-on-complete-thunks! wu
            (cons thunk (workunit-on-complete-thunks wu)))])))

;; Called when a client finishes a workunit.
(define (tracker-complete-workunit! tracker key error? result)
  (define wu (tracker-workunit-ref tracker key))
  (when wu
    (set-workunit-status! wu (if error? 'error 'done))
    (set-workunit-result! wu result)
    (set-workunit-last-status-change! wu
     (current-inexact-milliseconds))
    (for ([thunk (in-list (workunit-on-complete-thunks wu))])
      (thunk wu))
    (set-workunit-on-complete-thunks! wu '())))

;; Re-assign all workunits for client to other, better clients.
;; Requires a walk of the ENTIRE hash, and may be inefficient!
(define (remove-running-workunits! q client)
  (for ([(key wu) (in-hash (tracker-workunits q))]
        #:when (and (equal? client (workunit-client wu))
                    (eq? 'running (workunit-status wu))))
    (set-workunit-status! wu 'waiting))
  (tracker-dispatch-work! q))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The actual server.


(define (start-tracker-server port)
  (date-display-format 'iso-8601)
  (define (log . msg)
    (printf "[~a] ~a\n" (date->string (current-date) (current-seconds))
            (apply format msg))
    (flush-output))
  ;; Event loop! Put thunks on this channel to execute them in a
  ;; threadsafe way.
  (define chan (make-async-channel))
  (thread (λ() (let loop () ((async-channel-get chan)) (loop))))
  (define tracker (make-tracker))
  (define (handle-cxn in out)
    (define handler-cust (current-custodian))
    (custodian-limit-memory handler-cust (* 10 1024 1024))
    (define-syntax-rule (errguard-λ (args ...) body ...)
      (λ (args ...)
         (with-handlers ([exn:fail:network? (λ(ex) (displayln "Net err"))]
                         [exn:fail?
                          (λ(ex)
                            (log "Client error: ~a" (exn-message ex))
                            (flush-output)
                            (custodian-shutdown-all handler-cust)
                            #f)])
           body ...)))
    (define-syntax-rule (tracker-action body ...)
      (async-channel-put chan
                         (errguard-λ () body ...)))
    (define (send datum)
      (write datum out)
      (display "\n" out)
      (flush-output out))
    ;; First things first: Get and uniquify the client name
    (match-define (list 'hello-from client-name) (read in))
    (define client (uniquify client-name))
    (define-values (my-ip your-ip) (tcp-addresses out))
    (log "new connection: ~s ip: ~a" client your-ip)
    (dynamic-wind ; releases the client's workunits on disconnection.
      void
      (λ()
        (let/ec exit
          (let loop ()
            (match (read in)
              [(? eof-object?) (log "disconnect: ~a" client) (exit)]
              [(list 'who-am-i)
               (send (list 'you-are client))]
              [(list 'workunit-info wu-key)
               (tracker-action
                (define wu (tracker-workunit-ref tracker wu-key))
                (match-define
                 (workunit key status wu-client result data _ last-change)
                 (or wu (workunit wu-key #f #f #f #f #f #f)))
                (send (list 'workunit
                            key status wu-client result last-change)))]
              [(list 'wait-for-work)
               (log "~s is waiting for work" client)
               (tracker-action
                (tracker-call-with-work! tracker client
                   (errguard-λ (wu)
                      (log "assigned ~a to ~s" (workunit-key wu) client)
                      (send (list 'assigned-workunit
                                  (workunit-key wu)
                                  (workunit-data wu)))
                      (flush-output)
                      #t ;; accept this one
                      )))]
              [(list 'add-workunit! data)
               (tracker-action
                (define new-key (make-workunit-key data))
                (log "workunit: ~a" new-key)
                (tracker-add-workunit! tracker new-key data)
                (send (list 'added-workunit new-key)))]
              [(list 'monitor-workunit-completion key)
               (tracker-action
                (tracker-on-workunit-completion
                 tracker
                 key
                 (errguard-λ (wu)
                   (send (list 'workunit-complete
                               key
                               (workunit-status wu) ;; may be error, for ex
                               (workunit-client wu)
                               (workunit-result wu))))))]
              [(list 'complete-workunit! key error? result)
               (if error?
                   (log "~s FAILED workunit: ~a" client key)
                   (log "~s completed workunit: ~a" client key))
               (tracker-action
                (tracker-complete-workunit! tracker key error? result))]
              [other (error "wasn't expecting this from client:" other)])
            (loop))))
      ;; this is the last action for dynamic-unwind.
      ;; note that i can't use errorguard-λ because not everything
      ;; is set up yet.
      (λ()
        (log "Re-assigning all of ~s's workunits" client)
        (tracker-action (remove-running-workunits! tracker client)))))

  (log "Listening for connections on port ~a" port)
  (run-server port handle-cxn #f))

(define (uniquify str)
  (string-append str "-"
                 (list->string
                  (for/list ([i 5])
                    (define chars (string->list "bcdfghjklmnpqrstvwxyz"))
                    (list-ref chars (inexact->exact (floor (* (random) (length chars)))))))))

