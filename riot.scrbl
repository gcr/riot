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

TODO: change error? to success?

@table-of-contents[]




@section{Quick start}

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


-------
#lang racket
(require (planet gcr/riot))
(define dictionary
  (for/set ([word (in-list (file->lines "/usr/share/dict/words"))]
            #:when (>= (string-length word) 3))
           word))
(define (word-combinations)
   (apply append ;; This flattens the list
          (for/work ([first-word (in-set dictionary)])
            (for/list ([second-word (in-set dictionary)]
                       #:when (set-member? dictionary
                                           (string-append first-word
                                                          second-word)))
              (printf "Found ~s-~s\n" first-word second-word)
              (flush-output)
              (cons first-word second-word)))))
(module+ main
  (connect-to-riot-server! "localhost")
  (define words (time (word-combinations)))
  (printf "There are ~a words.\n" (length words))
  (write (take (shuffle words) 20))
  (newline))

--------

With ???? workers, I get 105 workunits per second.
9 workers on alfred (running queue server),
3 jarvis,
4 lurch,
4 kato,

= 20 total.

$ ~/racket/bin/racket dict.rkt
cpu time: 51903 real time: 1121990 gc time: 1732
There are 17658 words.
(("nick" . "name's") ("head" . "lights") ("ran" . "sacks") ("disc" . "lose") ("build" . "ups") ("wind" . "breaks") ("hot" . "headed") ("god" . "parent") ("main" . "frame") ("fiddle" . "sticks") ("pro" . "verbs") ("Volta" . "ire") ("select" . "ions") ("trail" . "blazer") ("bat" . "ten's") ("sniff" . "led") ("over" . "joys") ("down" . "hill") ("panel" . "led") ("tempera" . "ting"))


The second time:
$ ~/racket/bin/racket dict.rkt
cpu time: 30133 real time: 63214 gc time: 772


Without riot: