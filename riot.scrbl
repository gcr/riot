#lang scribble/doc
@(require scribble/manual
          planet/scribble
          (for-label racket)
          (for-label racket/gui)
          (for-label slideshow/pict)
          (for-label (this-package-in main)))

@title{@bold{riot}: Distributed computing for the masses}
@author{gcr}

Riot is a distributed computing system for racket. With Riot, you can run
parallel tasks on multiple machines accross the network with minimal changes to
your code.


TODO: Make queue actually a queue so it doesn't have to scan all those hashes
to pick the next workunit.

TODO: Progress reporting?

TODO: for/work; why does it only accept one variable in the for-clause?


@table-of-contents[]




@section{Getting started}

- Example: Something useful, but slow

- Concepts
  Master program picks work and farms it to the queue server. Master divides
  work into "workunits"; discrete pieces that don't depend on each other.
  Queue server keeps track of all pending, completed, and failed workunits.
  Queue server assigns workunits to workers and sends workunits back to the
  master when they're done. The queue server also caches completed workunits so
  the task can be restarted quickly if things break. Currently, the queue
  server just keeps all of this in memory which is bad.
  - Master
  - Queue server, how to run
  - Workers, how to run

@defmodule/this-package[main]{...}
- The many ways of running workunits

Constraints on (do-work) and (for/work):
- Must be in its own file; won't work from toplevel.

- All variables that the body refers to must be serializable. This
  means using serialize-struct instead of normal struct()s. Also,
  careful about referring to big variables that change.

- Related: When workers attempt to execute a workunit created by a
  do-work form, they (require) the module and search for the code to be
  executed. This has a number of implications:

  - Be sure not to run this code in the toplevel, or else your workers will try
    to create workunits of their own!

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

- Lower-level client API


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

$ ~/racket/bin/racket dict.rkt
cpu time: 36286 real time: 2533978 gc time: 1648
((bra . ids) (bra . ins) (bra . king) (bra . vest) (bra . very) (era . sure) (era . sing) (Ara . fat) (Ara . rat) (Ara . rat's) (Ara . fat's) (qua . hog) (qua . shed) (qua . king) (qua . hogs) (qua . shes) (qua . very) (qua . train) (qua . inter) (qua . hog's) (qua . drilling) (qua . trains) (qua . drilled) (boa . ting) (boa . sting) (Ana . baptist) (spa . red) (spa . ring) (spa . ding) (spa . rest) (spa . rely) (Lea . key) (Lea . key's) (yea . sty) (lea . fed) (lea . den) (lea . shed) (lea . sing) (lea . ping) (lea . king) (lea . ding) (lea . shes) (lea . nest) (tea . red) (tea . bag) (tea . cup) (tea . pot) (tea . time) (tea . sing) (tea . ring) (tea . room) (tea . pots) (tea . cups) (tea . spoon) (tea . rooms) (tea . pot's) (tea . cup's) (tea . spoonsful) (tea . kettle's) (tea . spoonfuls) (tea . spoonful) (tea . spoon's) (tea . spoonful's) (tea . spoons) (tea . room's) (tea . time's) (tea . kettle) (tea . kettles) (sea . red) (sea . led) (sea . bed) (sea . men) (sea . man) (sea . son) (sea . way) (sea . bird) (sea . ward) (sea . weed) (sea . food) (sea . side) (sea . ting) (sea . ring) (sea . sick) (sea . sons) (sea . ways) (sea . beds) (sea . port) (sea . board) (sea . plane) (sea . shore) (sea . going) (sea . shell) (sea . wards) (sea . birds) (sea . ports) (sea . sides) (sea . way's) (sea . son's) (sea . man's) (sea . coast))


The second time:
 $ ~/racket/bin/racket dict.rkt
cpu time: 27797 real time: 61069 gc time: 824