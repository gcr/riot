#lang racket

(require "client.rkt"
         racket/date
         mzlib/os)

(define (process-workunit q key serialized-data)
  ;; Deserialize data
  ;; Parse it
  ;; Run it, with error handling
  ;; Submit results or failure message
  (sleep 1)
  (client-complete-workunit! q key #f 42)
  )

(module+ main
  (define port (make-parameter 2355))
  (define name (make-parameter (gethostname)))
  (define queue-host
    (command-line
     #:once-each
     [("--port") p
      "Queue port to connect to. Default: 2355"
      (port (string->number p))]
     [("--name") client-name
      "Client name to report to server. Default is this machine's hostname"
      (name client-name)]
     #:args (host)
     host))
  (date-display-format 'iso-8601)
  (define (log . msg)
    (printf "[~a] ~a\n" (date->string (current-date) (current-seconds))
            (apply format msg))
    (flush-output))

  (log "Connecting to ~a port ~a" queue-host (port))
  (define q (connect-to-queue queue-host (port) (name)))
  (log "Connected")

  (let loop ()
    (log "Waiting for more work")
    (match-define
     (list key serialized-data)
     (client-wait-for-work q))
    (log "Starting workunit ~a" key)
    (if (process-workunit q key serialized-data)
        (log "Successfully completed workunit ~a" key)
        (log "Failed workunit ~a" key))
    (loop)))
