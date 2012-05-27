#lang racket
(require mzlib/os
         (planet gcr/riot))


(define (run)
  (displayln "Running")
  (for/work ([i (in-range 10)])
            (displayln "Hello from client")
            (sleep 30)
            (* 5 i)))

(module+ main
  ;; Note that we're NOT running this in the toplevel. If you use the
  ;; special `do-work' form, workers will (require) the module that
  ;; contains the code to run, and we don't want them submitting their
  ;; own workunits.
  (connect-to-riot-server! "localhost" 2355)
  (run))

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

;; REMEMBER to NEVER put a (do-work) call in the toplevel! If this
;; file gets required by workers (which happens if you use do-work or
;; friends), each worker might queue up workunits themselves!


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#|

Constraints on (do-work) and (for/work):
- Must be in its own file; won't work from toplevel.

- All variables that the body refers to must be serializable. This means
  using serialize-struct instead of normal struct()s.

- Related: When workers attempt to execute a workunit created by a
  do-work form, they (require) the module and search for the code to be
  executed. This has a number of implications:

  - If you're running workers on other machines accross a network, the
    module you're running must be present on all of the worker machines.

  - You must start the worker process in the same working directory
    relative to your master, so each of the workers can find the module.
    For example, if test.rkt lives in /home/michael/project/test.rkt on
    the master machine and in /tmp/project/test.rkt on the workers, you
    must start your racket process like this on the master:
    cd /home/michael/project; racket test.rkt
    and this on the workers:
    cd /tmp/project; racket -p gcr/riot/worker

  - If you change the code, you must copy the module to each of the
    worker machines in turn and restart the workers.

- If a worker process crashes while executing a workunit, that
  workunit may never complete.

|#