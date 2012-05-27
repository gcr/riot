#lang racket
(require (planet gcr/riot))

(define cloud (connect-to-queue "localhost" 2355))

(define workunits
  (for/list ([i (in-range 10)])
    (do-work cloud
      (+ i 5))))

(for/list ([p workunits]) (wait-until-done cloud p))

;; Queue would be responsible for
;; - generating a UUID for this director node
;; - Gathering data about each client
;; - Ensuring the server is still alive, expiring "dead" workunits
;;   with the UUID
;; - Saving workunit results from clients and relaying them
;;   back to the server
;; - Serializing (require racket/serialize) parameters and results

;; Maybe use web-server/lang/serial-lambda ?

;; racket -p gcr/bonk/client --queue localhost:6344 --file test.rkt