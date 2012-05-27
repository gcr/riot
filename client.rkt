#lang racket/base

(require racket/contract
         racket/tcp
         racket/match
         racket/function
         mzlib/os
         racket/serialize)

;; A queue client manages a connection to a queue server.

;; Workers use this client to:
;;  - gather workunits from the queue
;;  - submit completed workunit results or errors
;;  - wait for work, if there isn't any

;; Managers use this client to:
;;  - submit work to the queue
;;  - check up on the status of previously issued workunits
;;  - wait for results from said workunits

(define wu-key? any/c)

(struct client (out lock pending-actions) #:mutable)
(provide/contract
 [connect-to-queue (->* (string? exact-integer?) (string?) client?)]
 [client-workunit-info (-> client? string?
                           (list/c symbol? any/c any/c any/c))]
 [client-call-with-workunit-info (-> client? string?
                                     (-> symbol? any/c any/c any/c any/c)
                                     any/c)]
 [client-wait-for-work (-> client?
                           (list/c wu-key? any/c))]
 [client-call-with-work (-> client?
                            (-> wu-key? any/c any/c) any/c)]
 [client-add-workunit (-> client? serializable? wu-key?)]
 [client-call-with-new-workunit (-> client? serializable?
                                    (-> wu-key? any/c) any/c)]
 [client-wait-for-finished-workunit (-> client? wu-key?
                                         (list/c wu-key? symbol? any/c))]
 [client-call-with-finished-workunit (-> client? wu-key?
                                         (-> wu-key? any/c any/c any/c)
                                         any/c)]
 [client-complete-workunit! (-> client? wu-key? boolean? serializable?
                                any/c)])

;; React from a message sent by the server. Only let the event loop
;; call this; don't call it yourself.
(define (client-react client datum)
  (call-with-semaphore (client-lock client)
    (λ()
      ;; This datum should satisfy one of the pending actions. The
      ;; pending action that consumes the datum will return #t.
      ;; We will then remove it from the list.
      (define eaten-proc
        (for/first ([proc (in-list (client-pending-actions client))]
                    #:when (proc datum))
          proc))
      (cond
       [eaten-proc
        (set-client-pending-actions! client
         (remove eaten-proc (client-pending-actions client)))]
       [else
        (error "Server sent us something we weren't expecting:" datum)]))))

;; Registers 'expect' to run when the server sends us a datum. Proc
;; should return #t if it consumed the datum and #f otherwise.
(define (client-register-expector client proc)
  (call-with-semaphore (client-lock client)
    (λ()
      (set-client-pending-actions! client
       (append (client-pending-actions client) (list proc))))))

;; Send something to the client, then wait for a response. Blocks this
;; current thread until the server sends us something that matches
;; pattern. Then, return value. (this works because the reactor is in
;; a different thread)
(define-syntax-rule (client-request-response client send pattern value)
  (begin
    (define chan (make-channel))
    (client-register-expector client
     (λ(datum)
       (match datum
         [pattern (channel-put chan value) #t]
         [else #f])))
    (client-send client send)
    (channel-get chan)))

;; Waits for the server to send something back to us, then evaluates
;; value in its own thread.
(define-syntax-rule (client-expect/callback client pattern value)
  (begin
    (client-register-expector client
      (λ(datum)
        (match datum
          [pattern (thread (λ() value)) #t]
          [else #f])))))

(define (client-send client datum)
  ;;(display "--> ") (printf "~s\n" datum)
  (write datum (client-out client))
  (flush-output (client-out client)))

(define (connect-to-queue host port [client-name (gethostname)])
  (define-values (in out) (tcp-connect host port))
  (define cl (client out (make-semaphore 1) '()))
  (client-send cl (list 'hello-from client-name))
  (thread (λ() (let loop ()
                 (define datum (read in))
                 ;;(display "<-- ") (printf "~s\n" datum) (flush-output)
                 (client-react cl datum)
                 (loop))))
  cl)

;; Gather info about the workunit. Costs one round-trip.
(define (client-workunit-info client key)
  (client-request-response client
    (list 'workunit-info key)
    (list 'workunit (? (curry equal? key)) status wu-client result last-change)
    (list status wu-client result last-change)))
;; Gathers info about the workunit, but calls this function when it
;; arrives.
(define (client-call-with-workunit-info client key thunk)
  (client-expect/callback client
    (list 'workunit (? (curry equal? key)) status wu-client result last-change)
    (thunk status wu-client result last-change))
  (client-send client (list 'workunit-info key)))

;; Blocks until we have work. Costs one round-trip.
(define (client-wait-for-work client)
  (client-request-response client
    (list 'wait-for-work)
    (list 'assigned-workunit key data)
    (list key data)))

;; Like client-wait-for-work, but doesn't block. Will call thunk in
;; its own thread. (I don't want your bad error handling to screw up
;; the client's reactor thread)
(define (client-call-with-work client thunk)
  (client-expect/callback client
    (list 'assigned-workunit key data)
    (thunk key data))
  (client-send client (list 'wait-for-work)))

;; Returns the key of the new workunit.
(define (client-add-workunit client data)
  (client-request-response client
    (list 'add-workunit! data)
    (list 'added-workunit key)
    key))
(define (client-call-with-new-workunit client data thunk)
  (client-expect/callback client
    (list 'added-workunit key)
    (thunk key))
  (client-send client (list 'add-workunit! data)))

(define (client-wait-for-finished-workunit client key)
  (client-request-response client
    (list 'monitor-workunit-completion key)
    (list 'workunit-complete (? (curry equal? key) wu-key) status result)
    (list wu-key status result)))

(define (client-call-with-finished-workunit client key thunk)
  (client-expect/callback client
    (list 'workunit-complete (? (curry equal? key) wu-key) status result)
    (thunk wu-key status result))
  (client-send client (list 'monitor-workunit-completion key)))

;; Mark this one as completed.
(define (client-complete-workunit! client key error? result)
  (client-send client (list 'complete-workunit! key error? result)))
