#lang racket

;; A queue client manages a connection to a queue server.

;; Workers use this client to:
;;  - gather workunits from the queue
;;  - submit completed workunit results or errors
;;  - wait for work, if there isn't any

;; Managers use this client to:
;;  - submit work to the queue
;;  - check up on the status of previously issued workunits
;;  - wait for results from said workunits

(struct queue-client (in out workunits))