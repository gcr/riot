#lang racket

(require mzlib/os racket/serialize)

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
#;
(provide/contract
 [connect-to-queue (->* (string? exact-integer?) (string?) client?)]
 [client-wu-info (-> client? string?
                    (-> wu-key? any/c any/c any/c any/c any/c))]
 [client-wait-for-work (-> client? string?
                          (-> wu-key? any/c any/c))]
 [add-workunit! (-> client? serializable?
                    (-> wu-key? any/c))]
 [monitor-workunit-completion (-> client? wu-key?
                                  (-> wu-key? any/c any/c any/c))]
 [complete-workunit! (-> client? wu-key? boolean? any/c)])

;; React from a message sent by the server. Only let the event loop
;; call this; don't call it yourself.
(define (client-react client datum)
  (call-with-semaphore (client-lock client)
    (λ()
      ;; This datum should satisfy one of the pending actions.
      (define eaten-proc
        (for/first ([proc (in-list (client-pending-actions client))])
          (proc datum)))
      (cond
       [eaten-proc
        (set-client-pending-actions! client
         (remove eaten-proc (client-pending-actions client)))]
       [else
        (error "Server sent us something we weren't expecting:" datum)]))))

;; Registers 'expect' to run on the client
(define (client-expect client proc)
  (call-with-semaphore (client-lock client)
    (λ()
      (set-client-pending-actions! client
       (cons proc (client-pending-actions client))))))
(define-syntax-rule (client-expect/wait client pattern value)
  (begin
    (define chan (make-channel))
    (client-expect client
     (λ(datum)
       (match datum
         [pattern (channel-put chan value) #t]
         [else #f])))
  (channel-get chan)))

(define (client-send client datum)
  ;; (displayln "--> ") (printf "~s\n" datum)
  (write datum (client-out client))
  (flush-output (client-out client)))

(define (connect-to-queue host port [client-name (gethostname)])
  (define-values (in out) (tcp-connect host port))
  (define cl (client out (make-semaphore 1) '()))
  (write (list 'hello-from client-name) out)
  (thread (λ() (let loop ()
                 (define datum (read in))
                 ;; (display "<-- ") (printf "~s\n" datum) (flush-output)
                 (client-react cl datum)
                 (loop))))
  cl)

(define (client-wu-info client key)
  (client-send client (list 'workunit-info key))
  (client-expect/wait client
    (list 'workunit key status wu-client result last-change)
    (list key status wu-client result last-change)))

;;  [client-wu-info (-> client? string?
;;                     (-> wu-key? any/c any/c any/c any/c any/c))]
;;  [client-wait-for-work (-> client? string?
;;                           (-> wu-key? any/c any/c))]
;;  [add-workunit! (-> client? serializable?
;;                     (-> wu-key? any/c))]
;;  [monitor-workunit-completion (-> client? wu-key?
;;                                   (-> wu-key? any/c any/c any/c))]
;;  [complete-workunit! (-> client? wu-key? boolean? any/c)])