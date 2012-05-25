#lang racket
(require racket/async-channel
         mzlib/thread
         "queue.rkt")

(define (start-queue-server port)
  (define chan (make-async-channel))
  (define q (make-queue))
  (thread (λ() (let loop () ((async-channel-get chan)) (loop))))
  ;; put thunks on this channel to execute them.
  (define-syntax-rule (q-action body ...)
    (async-channel-put chan (λ() body ...)))
  (define (handle-cxn in out)
    ;; TODO: limit memory right here
    (define (send datum)
      (write datum out)
      (display "\n" out)
      (flush-output out))
    (let/ec exit
      (let loop ()
        (flush-output out)
        (match (read in)
          [eof (exit)]
          [(list 'workunit-status wu-key)
           (q-action
            (send (list 'wu-status (workunit-status q wu-key))))]
          [(list 'workunit-result wu-key)
           (q-action
            (send (list 'wu-result (workunit-result q wu-key))))]
          [(list 'workunit-client wu-key)
           (q-action
            (send (list 'wu-client (workunit-client q wu-key))))]
          [(list 'workunit-data wu-key)
           (q-action
            (send (list 'wu-data (workunit-data q wu-key))))]
          [(list 'workunit-last-status-change wu-key)
           (q-action
            (send (list 'wu-last-status-change
                        (workunit-last-status-change q wu-key))))]
          [(list 'add-workunit! data)
           (q-action
            (send (list 'added-workunit
                        (queue-add-workunit! q data))))]
          [other (error "Wasn't expecting THIS from client!" other)])
        (loop))))

  (run-server port handle-cxn #f))