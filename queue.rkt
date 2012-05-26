#lang racket
(require racket/async-channel
         file/md5)

;; A queue is a list of workunits along with an asynchronous channel
;; that performs unsafe actions on that queue.
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
 [make-queue (-> queue?)]
 [queue-ref (-> queue? workunit-key? (or/c workunit? #f))]
 [queue-add-workunit! (-> queue? any/c workunit-key?)]
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
(define (queue-add-workunit! queue data)
  (define key (make-workunit-key data))
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
   (cons client-thunk-data (queue-clients-waiting-for-work queue)))
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
