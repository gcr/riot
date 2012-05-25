#lang racket
(require (planet gcr/bonk))

(define queue (queue "localhost" 6344))

(define workunits
  (for/list ([i (in-range 10)])
    (queue (workunit-λ
            (do-stuff i j k)))))

(for/list ([p workunits]) (workunit-result p))

(workunit-status (first p))

;; Queue would be responsible for
;; - generating a UUID for this director node
;; - Gathering data about each client
;; - Ensuring the server is still alive, expiring "dead" workunits
;;   with the UUID
;; - Saving workunit results from clients and relaying them
;;   back to the server
;; - Serializing (require racket/serialize) parameters and results
;;   using fasl

;; Maybe use web-server/lang/serial-lambda ?


;; racket -p gcr/bonk/client --queue localhost:6344 --file test.rkt