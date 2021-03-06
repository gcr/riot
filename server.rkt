#lang racket/base

;; Call this file to start a new queue server!

(require racket/cmdline
         "private/server.rkt")

(module+ main
  (define port (make-parameter 2355))
  (command-line
   #:once-each
   [("--port") p
                    "Port to serve on default: 2355"
                    (port (string->number p))])
  (start-tracker-server (port)))