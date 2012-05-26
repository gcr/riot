#lang racket
(require racket/async-channel
         mzlib/thread
         "queue.rkt")

(define (start-queue-server port)
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
      (let loop ()
        (flush-output out)
        (match (read in)
          [(? eof-object?) (exit)]
          [(list 'workunit-info wu-key)
           (q-action
            (define wu (queue-ref q wu-key))
            (match-define
             (workunit key status client result data _ last-change)
             (or wu (workunit wu-key #f #f #f #f #f #f)))
            (send (list 'workunit key status client result last-change)))]
          [(list 'wait-for-work client)
           (q-action
            (queue-call-with-work! q client
              (errguard-λ (wu)
                 (send (list 'assigned-workunit
                             (workunit-key wu)
                             (workunit-data wu)))
                 (flush-output)
                 #t ;; accept this one
                 )))]
          [(list 'add-workunit! data)
           (q-action
            (send (list 'added-workunit
                        (queue-add-workunit! q data))))]
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
           (q-action
            (queue-complete-workunit! q key error? result))]
          [other (error "Wasn't expecting THIS from client!" other)])
        (loop))))

  (run-server port handle-cxn #f))