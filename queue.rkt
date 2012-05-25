#lang racket
(require racket/async-channel)

;; TODO
;; - Sign workunits on data. They couldn't cause side effects anyway.
;; - Provide queue-workunit-on-complete-thunks, and be sure to run
;;   them right away when (on-complete) runs on a finished thunk.
;; - Remove (let) and other ugly code


;; A queue is a list of workunits along with an asynchronous channel
;; that performs unsafe actions on that queue.
(struct queue (workunits
               [clients-waiting-for-work #:mutable]))
(define workunit-key? any/c)
(define workunit-status? (or/c 'waiting 'running 'done 'error))

(provide/contract
 [make-queue (-> queue?)]
 [workunit-status (-> queue? workunit-key? (or/c #f workunit-status?))]
 [workunit-client (-> queue? workunit-key? any/c)]
 [workunit-result (-> queue? workunit-key? any/c)]
 [workunit-data (-> queue? workunit-key? any/c)]
 [workunit-last-status-change (-> queue? workunit-key? any/c)]
 [queue-add-workunit! (-> queue? any/c workunit-key?)])

(define (make-queue)
  ;; This event loop constantly runs requests from other threads.
  (queue (make-hash) (list)))

;; Get the given workunit.
(define (queue-ref queue key [default #f])
  (hash-ref (queue-workunits queue) key default))

;; A workunit is a (potentially completed) item of work to be handed
;; out to clients.
(struct queue-workunit (status
                        client
                        result
                        data
                        last-status-change) #:mutable)

(define (workunit-status queue key)
  (define wu (hash-ref (queue-workunits queue) key #f))
  (and wu (queue-workunit-status wu)))
(define (workunit-client queue key)
  (define wu (hash-ref (queue-workunits queue) key #f))
  (and wu (queue-workunit-client wu)))
(define (workunit-result queue key)
  (define wu (hash-ref (queue-workunits queue) key #f))
  (and wu (queue-workunit-result wu)))
(define (workunit-data queue key)
  (define wu (hash-ref (queue-workunits queue) key #f))
  (and wu (queue-workunit-data wu)))
(define (workunit-last-status-change queue key)
  (define wu (hash-ref (queue-workunits queue) key #f))
  (and wu (queue-workunit-last-status-change wu)))

(define current-seed (make-parameter
                      (inexact->exact (floor (* 10000000 (random))))))
(define (make-unique-hash-key)
  (current-seed (add1 (current-seed)))
  (current-seed))


(define (queue-pick-workunit queue status)
  (for/first ([(key wu) (in-hash (queue-workunits queue))]
              #:when (eq? status (queue-workunit-status wu)))
    key))

(define (queue-dispatch-work! queue)
  ;; If there are clients waiting for work, well send it to them gosh
  ;; golly
  (when (not (empty? (queue-clients-waiting-for-work queue)))
    (define next-wu
      (queue-ref queue (queue-pick-workunit queue 'waiting)))
    (when next-wu
      (match-define (list client client-thunk)
                    (first (queue-clients-waiting-for-work queue)))
      (set-queue-clients-waiting-for-work!
       queue
       (rest (queue-clients-waiting-for-work queue)))
      (set-queue-workunit-status! next-wu 'running)
      (client-thunk (queue-workunit-data next-wu))
      (queue-dispatch-work! queue))))

;; Add work to the queue
(define (queue-add-workunit! queue data)
  (define key (make-unique-hash-key))
  (define wu (queue-workunit 'waiting #f #f data
                             (current-inexact-milliseconds)))
  (hash-set! (queue-workunits queue) key wu)
  (queue-dispatch-work! queue)
  key)

;; Call thunk with a workunit key when there's more work
(define (queue-call-with-work! queue client thunk)
  (define client-thunk-data (list client thunk))
  (set-queue-clients-waiting-for-work!
   queue
   (cons client-thunk-data (queue-clients-waiting-for-work queue)))
  (queue-dispatch-work! queue))