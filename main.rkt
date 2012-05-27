#lang racket

(require "client.rkt"
         (for-syntax file/md5)
         racket/serialize
         mzlib/os
         web-server/lang/serial-lambda)

(define workunit? string?)
(provide current-client
         do-work
         for/work
         )
(provide/contract
 ;; Ask for workers to dynamic-require the module path and call the
 ;; symbol with the given args. Registering this workunit costs one
 ;; roundtrip.
 [connect-to-riot-server!
  (->* (string?) (exact-integer? string?) any/c)]
 [do-work/call (->* (module-path? symbol?)
                    #:rest (listof serializable?)
                    workunit?)]
 ;; Asks workers to eval the given datum. Costs one roundtrip.
 [do-work/eval (-> serializable? workunit?)]
 ;; Asks workers to evaluate the given serial-lambda.
 [do-work/serial-lambda (-> serializable? any/c workunit?)]
 ;; Wait until the cluster has finished the given workunit, and
 ;; either erorr with the given message or throw an exception
 [wait-until-done (-> workunit? any/c)]
 ;; Calls the given thunk in a new thread when the workunit completes.
 ;; The first argument is #t if it error'd and #f if not. The second
 ;; argument is the client that finished this workunit, and the final
 ;; argument is the result.
 [call-when-done (-> workunit? (-> boolean? any/c any/c any/c)
                     any/c)])

(define-syntax (do-work stx)
  (syntax-case stx ()
      [(_ body ...)
       (let ([t (bytes->string/utf-8
                 (md5 (format "~s" (syntax->datum stx))))])
         ;; A 'tag' is an md5sum of the body of the code. Checking
         ;; this ensures that the client will run the same version of
         ;; the code that master does.
         #`(do-work/serial-lambda #,t
              (serial-lambda (tag)
                 (cond
                  [(equal? tag #,t) body ...]
                  [else (error 'worker "Code mismatch: This worker has a different version of the code than the master does. Please restart this worker with the correct version.")]))))]))

(define-syntax-rule (for/work for-decl body ...)
  (let ([workunits
         (for/list for-decl (do-work body ...))])
    (for/list ([p workunits]) (wait-until-done p))))

(define current-client (make-parameter "not connected to a server"))
(define (connect-to-riot-server! host [port 2355] [client-name (gethostname)])
  (current-client (connect-to-queue host port client-name)))


(define (do-work/call module-path symbol . args)
  (client-add-workunit (current-client)
                       (list* 'call-module module-path symbol
                              (map cleanup-serialize args))))

(define (do-work/serial-lambda nonce lambda)
  (client-add-workunit (current-client)
                       (list 'serial-lambda nonce
                             (cleanup-serialize lambda))))

(define (do-work/eval datum)
  (client-add-workunit (current-client)
                       (list 'eval datum)))

(define (wait-until-done workunit)
  (match-define (list key status client-name result)
                (client-wait-for-finished-workunit
                 (current-client) workunit))
  (if (equal? status 'done)
      ;; Finished
      result
      ;; Error
      (error 'wait-until-done
             "Workunit ~a failed\nWorker: ~s\nMessage: ~a"
             workunit
             client-name
             result)))

(define (call-when-done workunit thunk)
  (client-call-with-finished-workunit (current-client) workunit
    (λ (key status client-name result)
       (if (equal? status 'done)
           (thunk #f client-name result)
           (thunk #t client-name result)))))

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

