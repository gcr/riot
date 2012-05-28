#lang racket/base

(require "client.rkt"
         racket/date
         racket/cmdline
         racket/match
         racket/serialize
         mzlib/os
         compiler/cm)

(define (connect-and-work host name port)
  (date-display-format 'iso-8601)
  (define (log . msg)
    (printf "[~a] ~a\n" (date->string (current-date) (current-seconds))
            (apply format msg))
    (flush-output))

  (log "Connecting to ~a port ~a" host port)
  (define q (connect-to-tracker host port name))
  (log "Connected. We are ~a" (client-who-am-i q))

  (define (process-data serialized-data)
    (match serialized-data
      [(list-rest 'call-module mod-path symbol sargs)
       (define args (map deserialize sargs))
       (log "Running mod: ~s symbol: ~a args: ~s" mod-path symbol args)
       (apply (dynamic-require mod-path symbol) args)]
      [(list 'serial-lambda tag sthunk)
       (log "Running serialized lambda")
       (match-define thunk (deserialize sthunk))
       ;; Thunk will error out if it has a different tag than it expects.
       (thunk tag)]
      [(list 'eval datum)
       (log "Evaluating: ~s" datum)
       (let ([ns (make-base-empty-namespace)])
         (namespace-attach-module (current-namespace)
                                  'racket/base
                                  ns)
         (parameterize ([current-namespace ns])
           (namespace-require 'racket/base)
           (eval datum)))]))

  (define (run-workunit q key serialized-data)
    ;; Deserialize data
    ;; Parse it
    ;; Run it, with error handling
    ;; Submit results or failure message
    (with-handlers ([exn:fail?
                     (λ (ex)
                        (log "Failed ~a:\n~a"
                             key
                             (exn-message ex))
                        (client-complete-workunit! q key #t
                                                   (exn-message ex))
                        #f)])
      (client-complete-workunit! q key #f (process-data serialized-data))
      #t))


  (let loop ()
    (log "Waiting for more work")
    (match-define
     (list key serialized-data)
     (client-wait-for-work q))
    (log "Starting workunit ~a" key)
    (if (run-workunit q key serialized-data)
        (log "Successfully completed workunit ~a" key)
        (log "Failed workunit ~a" key))
    (loop)))

(module+ main
  (define port (make-parameter 2355))
  (define name (make-parameter (gethostname)))
  (define tracker-host
    (command-line
     #:once-each
     [("--port") p
      "Port to connect to. Default: 2355"
      (port (string->number p))]
     [("--name") client-name
      "Client name to report to server. Default is this machine's hostname"
      (name client-name)]
     #:args (host)
     host))

  (connect-and-work tracker-host (name) (port)))