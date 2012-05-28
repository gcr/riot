#lang scribble/doc
@(require scribble/manual
          planet/scribble
          (for-label racket)
          (for-label racket/gui)
          (for-label racket/serialize)
          (for-label web-server/lang/serial-lambda)
          (for-label (this-package-in main)))

@title{@bold{riot}: Distributed computing for the masses}
@author{gcr}

Riot is a distributed computing system for racket. With Riot, you can run
parallel tasks on multiple machines accross the network with minimal changes to
your code.

You need a Racket that supports submodules. At the time of writing, only the
@hyperlink["http://pre.racket-lang.org/installers/"]{nightly builds} will work.

@local-table-of-contents[]

@section{TODO}
TODO: Ensure that workers actually exit when the tracker misbehaves.

TODO: Change server/start to just server

TODO: Progress reporting?

TODO: change error? to success?



@section{In which we construct a networked mapreduce cluster from scratch in
about thirty seconds}
@itemlist[#:style 'ordered]{@item{To get started, first start the tracker server. In a terminal, run:
@verbatim{
$ racket -p gcr/riot/server
}}@item{
Parellel code looks like this:
@codeblock{
;; Save to simple-demo.rkt
#lang racket
(require (planet gcr/riot))

(define (run)
  (for/work ([i (in-range 10)])
    (sleep 3) ; or some big task
    (* 10 i)))

(module+ main
  (connect-to-riot-server! "localhost")
  (displayln (run))
  ;; Note that (run) must be in a separate function--see below
  (displayln "Complete"))
}

You just wrote the ``master'' program that hands out work and processes the
results. The @racket[(for/work ...)] form acts just like @racket[for/list], but
it runs in parallell: @racket[for/work] packages its body into ``workunits''
that will be run by other worker processes. @racket[for/work] will generate one
workunit for each iteration. (Using @racket[for/work] is not the only way to
control riot and it has @seclink["restrictions"]{restrictions and odd
behavior}, but it is the easiest.)

Go ahead and start your program:
@verbatim{
$ racket simple-demo.rkt
}

The loop runs 10 times, so your program will register 10 units of work with the
tracker. It will then appear to freeze because there aren't any workers to run
the work yet. Once we make some workers, the tracker will assign workunits to
them and will return results back to your program once the workers finish.
Workers can even run on other machines; in these cases, the tracker will simply
send workunits accross the network. There's no difference between local and
networked workers, so commandeer your entire computer lab if you like.
}@item{
Let's start some worker processes. If you want your workers to run on
other machines, copy @tt{simple-demo.rkt} there.

From the same directory that contains @tt{simple-demo.rkt}, run
@verbatim{
$ racket -p gcr/riot/worker -- localhost
}

where @tt{localhost} is the hostname of the tracker server you ran earlier.
Once you start a worker, it will immediately start to process workunits. Once
all workunits are finished, the master program will un-freeze and the
@racket[for/work] form will return the results of each workunit to the caller.

Add as many workers as you like. The more workers you run, the faster your
program goes. If you kill a worker with Ctrl+C or subject it to some other
horrible fate, the tracker server should notice and will reassign abandoned
workunits to other workers.

If one of the workers throws an exception, the tracker will forward the
exception to @racket[for/work], which will in turn will throw an exception with
a message about which worker caused the problem. Don't worry --- the tracker
remembers completed workunits after your program exits, so if you run your
program again, it will pick up where it left off.

If you change your program, be sure to copy the new version to all of the
workers and restart them all too. If you don't, they might complain (throw
exceptions) if you're lucky, or they just might give results generated from the
older code if you're unlucky. }}

@section{In which we gain significant speedups through the copious application of spare machinery}

Her's an anecdote where I gained a 10x speedup by changing two lines of code
and borrowing five machines for an hour.

In this example, we find all compound dictionary words: words in
@tt{/usr/share/dict/words} that are made by concatenating two other dictionary
words.

Here's some simple code to do that:

@codeblock{
#lang racket
;; dict.rkt
(require (planet gcr/riot))

(define dictionary
  ;; List of words
  (for/set ([word (in-list (file->lines "/usr/share/dict/words"))]
            #:when (>= (string-length word) 3))
           word))

(define (word-combinations)
   (apply append ; This flattens the list
          (for/list ([first-word (in-set dictionary)])
            (for/list ([second-word (in-set dictionary)]
                       #:when (set-member? dictionary
                                           (string-append first-word
                                                          second-word)))
              (cons first-word second-word)))))

(module+ main
  (define words (time (word-combinations)))
  (printf "There are ~a words.\n" (length words))
  ;; Print a random subset of the results.
  (write (take (shuffle words) 20)) (newline))
}

There are definitely better ways to do this. We naively loop through the
dictionary for each dictionary word and see if the concatenation is also part
of the dictionary--an O(n²) operation assuming constant @racket[set-member?]
time. As written, this code is an ideal candidate for parallelization:
@itemlist{@item{We can split up the outer loop of this dictionary search into
parts
}@item{Each iteration of the outer loop doesn't depend on any other iteration; each is @bold{``self-contained''}
}@item{There isn't very much processing to do after we have the word list}}

Running this on an Intel Xeon 1.86GHz CPU produced this output:
@verbatim{
cpu time: 11233134 real time: 11231587 gc time: 103748
There are 17658 words.
(("for" . "going") ("tail" . "gating") ("minima" . "list's") ("wise" . "acres") ("mill" . "stone's") ("hare" . "brained") ("under" . "bids") ("Chi" . "lean") ("clod" . "hopper") ("reap" . "points") ("dis" . "missal's") ("scholars" . "hip's") ("over" . "load") ("kilo" . "watts") ("trash" . "cans") ("snaps" . "hot") ("lattice" . "work") ("mast" . "head") ("over" . "coming") ("whole" . "sales"))
}
We can see that it took 187.2 minutes.

To parallelize this code, I made three changes:
@itemlist{@item{I changed the outer @racket[for/list] form to a
@racket[for/work] form
}@item{I added a @racket[(connect-to-riot-server!)] call in the main submodule
}@item{I ran twenty total workers on four spare lab machines and started the
tracker server on @tt{alfred}}}

The new code looks like this:
@codeblock{
#lang racket
;; dict.rkt
(require (planet gcr/riot))

(define dictionary
  ;; List of words
  (for/set ([word (in-list (file->lines "/usr/share/dict/words"))]
            #:when (>= (string-length word) 3))
           word))

(define (word-combinations)
   (apply append ; This flattens the list
          (for/work ([first-word (in-set dictionary)])
            (for/list ([second-word (in-set dictionary)]
                       #:when (set-member? dictionary
                                           (string-append first-word
                                                          second-word)))
              (cons first-word second-word)))))

(module+ main
  (connect-to-riot-server! "alfred")
  (define words (time (word-combinations)))
  (printf "There are ~a words.\n" (length words))
  ;; Print a random subset of the results.
  (write (take (shuffle words) 20)) (newline))
}

This program generates this output:
@verbatim{
$ ~/racket/bin/racket dict.rkt
cpu time: 51903 real time: 1121990 gc time: 1732
There are 17658 words.
(("nick" . "name's") ("head" . "lights") ("ran" . "sacks") ("disc" . "lose") ("build" . "ups") ("wind" . "breaks") ("hot" . "headed") ("god" . "parent") ("main" . "frame") ("fiddle" . "sticks") ("pro" . "verbs") ("Volta" . "ire") ("select" . "ions") ("trail" . "blazer") ("bat" . "ten's") ("sniff" . "led") ("over" . "joys") ("down" . "hill") ("panel" . "led") ("tempera" . "ting"))
}

This version took 18.7 minutes, which is a factor of 10 improvement. We still
found all 17658 compound words because @tt{/usr/share/dict/words} is the same
on all machines.

Running the program a second time...
@verbatim{
$ ~/racket/bin/racket dict.rkt
cpu time: 30133 real time: 63214 gc time: 772
}
...took 63 seconds because the tracker remembered the 100,000 completed
workunits so the program spent all of its time in network traffic and
appending/shuffling the huge list of results.

@section{In which we present an overview and clarity is achieved}

Riot clusters consist of three parts:
@itemlist{@item{A @bold{master program}
}@item{A @bold{tracker} server
}@item{One or more @bold{worker processeses}}}

@subsection{The master program}
The master program sends workunits to the tracker and waits for the tracker to
send results back.



@subsection{The tracker}
@defmodule/this-package[server]{
The tracker server's only job is to accept workunits from master programs,
assign them to workers, and return worker results back to the master program.
It's essentially nothing more than a database of workunits. You can query that
database using the functions described in the @seclink["lowlevel"]{low-level
client API section}.
}

To start your own tracker server, run:
@verbatim{
$ racket -p gcr/riot/server
}
The server can also run on a different port, like this:
@verbatim{
$ racket -p gcr/riot/server -- --port 12345
}
The @tt{--} separates racket's commandline arguments from the server's.

@subsection{The workers}
@defmodule/this-package[worker]{
Workers are processes that do work. You can start them by running:
@verbatim{
racket -p gcr/riot/worker -- --port 1234 --name worker-name server-host
}
where @tt{--port} and @tt{--name} are optional.

Each worker has a ``client name'' that identifies itself. This defaults to the
machine's hostname followed by a dash and a random string of consonants. To
change this, use @tt{--name}.

In workunits created by @racket[for/work] and @racket[do-work], each worker
will @racket[require] the module that contains that form. In the case of
@racket[do-work/call] workunits, the worker will @racket[require] the module
named by the @racket[do-work/call] form. To be sure that the worker can find
the module, you must run the worker in the same directory that you ran the
master program relative to the module. For example, if you ran:
@verbatim{
$ cd /tmp/demo; racket simple-demo.rkt
}
on the master and copied @tt{simple-demo.rkt} to
@racket{/home/worker/demo/simple-demo.rkt} on the worker, you must run the
worker like this:
@verbatim{
$ cd /home/worker/demo; racket -p gcr/riot/worker -- tracker-server
}

This also means that each worker must have identical copies of
@tt{simple-demo.rkt}. If the body of a worker's @racket[for/work] form does not
exactly match the master's @racket[for/work] form, it will complain about a
code mismatch. The @racket[for/work] and @racket[do-work] forms check for this,
but @racket[do-work/call] cannot check the version of the module it requires,
so workers with differing versions of those modules will silently misbehave.

A worker shouldn't generate its own workunits; it should only run work. This
means you musn't use @racket[for/work] or @racket[do-work] forms in the
toplevel (or in any function that runs when the module is required) or else
your workers will attempt to generate workunits of their own! See the
@seclink["restrictions"]{for/work section} for more details.

}

@section[#:tag "restrictions"]{In which we dispel all manner of shenanigans and peculiarities about for/work and do-work}
@defmodule/this-package[main]{
The two easiest ways of submitting workunits are @racket[do-work] and
@racket[for/work].
}
@defform[(do-work (for-clause ...) body ...)]{

Packages up the @racket[body ...] expressions to be evaluated in a workunit.
This form returns instantly (after one round-trip to the tracker) and returns a
workunit ID, a string representing a promise to do the work.

Any expressions can appear in the @racket[body ...] form as long as they:
@itemlist{@item{Only refer to @bold{serializable values}, else the workunit
cannot be packaged up for transmission accross the network to workers
}@item{Do not cause and do not depend on @bold{global side effects}, else each worker
may have different state, causing unpredictable behavior
}}

The @racket[do-work] form works by wrapping all of the @racket[body ...]
expressions inside a @racket[serial-lambda] with no arguments. This effectively
makes each workunit its own closure. Free variables are @racket[serialize]d
when the workunit is sent to the tracker, and the resulting value is serialized
on the return trip.

Workunits created by @racket[do-work] (and, by extension, @racket[for/work])
can refer to free variables, like this:



that
contains all of the free variables in the @racket[body ...] expressions.

Free variables.

Code Checking.

}
@defform[(for/work (for-clause ...) body ...)]{
Acts just like @racket[for/list], but arranges for each @racket[body ...]
to run in parallell: each iteration creates a workunit using @racket[do-work]; then calls @racket[wait-until-done] on the resulting workunit.
}

- free variables

@subsection{Restrictions and limitations}
- Must be in a module that wokers can see; won't work from REPL

- Doesn't work from within submodules.

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


@section{In which we describe the numerous kinds of workunits}
There's more to riot than @racket[for/work] and @racket[do-work].

do-work/call
- Takes a module path
- Still must restart workers
do-work/eval
- Can use from the REPL
- Only one where the workers don't require any extra code

@section[#:tag "lowlevel"]{In which we present a lower-level client API for communicating with the tracker}


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

The second time:
$ ~/racket/bin/racket dict.rkt
cpu time: 30133 real time: 63214 gc time: 772


Without riot: