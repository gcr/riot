#lang racket

;; Call this file to start a new queue server!

(require "main.rkt")

(module+ main
  (define port (make-parameter 2355))
  (command-line
   #:once-each
   [("--port") p
                    "Queue port to serve on"
                    (port (string->number p))])
  (start-queue-server (port)))