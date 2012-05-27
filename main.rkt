#lang racket

(require "client.rkt"
         racket/serialize
         web-server/lang/serial-lambda)

(define workunit? string?)
(provide do-work connect-to-queue)
(provide/contract
 ;; Ask for workers to dynamic-require the module path and call the
 ;; symbol with the given args. Registering this workunit costs one
 ;; roundtrip.
 [do-work/call (->* (client? module-path? symbol?)
                    #:rest (listof serializable?)
                    workunit?)]
 ;; Asks workers to eval the given datum. Costs one roundtrip.
 [do-work/eval (-> client? serializable? workunit?)]
 ;; Asks workers to evaluate the given serial-lambda.
 [do-work/serial-lambda (-> client? serializable? workunit?)]
 ;; Wait until the cluster has finished the given workunit, and
 ;; either erorr with the given message or throw an exception
 [wait-until-done (-> client? workunit? any/c)]
 ;; Calls the given thunk in a new thread when the workunit completes.
 ;; The first argument is #t if it error'd and #f if not. The second
 ;; argument is the client that finished this workunit, and the final
 ;; argument is the result.
 [call-when-done (-> client? workunit? (-> boolean? any/c any/c any/c)
                     any/c)])

(define-syntax-rule (do-work client body ...)
  (do-work/serial-lambda client (serial-lambda () body ...)))

(define (do-work/call client module-path symbol . args)
  (client-add-workunit client
                       (list* 'call-module module-path symbol
                              (map cleanup-serialize args))))

(define (do-work/serial-lambda client lambda)
  (client-add-workunit client
                       (list* 'serial-lambda (cleanup-serialize lambda))))

(define (do-work/eval client datum)
  (client-add-workunit client
                       (list* 'eval datum)))

(define (wait-until-done client workunit)
  (match-define (list key status client-name result)
                (client-wait-for-finished-workunit client workunit))
  (if (equal? status 'done)
      ;; Finished
      result
      ;; Error
      (error 'wait-until-done
             "Workunit failed: ~a\nClient: ~s\nMessage: ~a"
             workunit
             client-name
             result)))

(define (call-when-done client workunit thunk)
  (client-call-with-finished-workunit client workunit
    (λ (key status client-name result)
       (if (equal? status 'done)
           (thunk #f client result)
           (thunk #t client result)))))

(define (cleanup-serialize datum)
  ;; Serialize datum, while being sure to clean up the paths
  ;; http://docs.racket-lang.org/reference/serialization.html?q=serialize#(def._((lib._racket/private/serialize..rkt)._deserialize))
  (match-define (list '(3)
                      s-count
                      structure-defs
                      g-count
                      graph
                      pairs
                      serial)
                (serialize datum))
  (list '(3) s-count
        (for/list ([struct-def (in-list structure-defs)])
          (match struct-def
            [(cons (and mod (? bytes?)) ident)
             (define better-file (find-relative-path
                                  (current-directory)
                                  (bytes->path mod)))
             (if (equal? 'up (first (explode-path better-file)))
                 struct-def
                 (cons (path->bytes better-file) ident))]
            [(cons (list 'file file) ident)
             (define better-file (find-relative-path
                                  (current-directory)
                                  (string->path file)))
             (if (equal? 'up (first (explode-path better-file)))
                 struct-def
                 (cons (list 'file (path->string better-file)) ident))]
            [else struct-def]))
        g-count graph pairs serial))

