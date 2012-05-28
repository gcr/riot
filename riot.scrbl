#lang scribble/doc
@(require scribble/manual
          planet/scribble
          (for-label racket)
          (for-label mzlib/os)
          (for-label racket/gui)
          (for-label racket/serialize)
          (for-label web-server/lang/serial-lambda)
          (for-label (this-package-in main))
          (for-label (this-package-in client)))

@title{@bold{riot}: Distributed computing for the masses}
@author{gcr}

Riot is a distributed computing system for Racket. With Riot, you can run
parallel tasks on multiple machines accross the network with minimal changes to
your code.

You need a Racket that supports submodules. At the time of writing, only the
@hyperlink["http://pre.racket-lang.org/installers/"]{nightly builds} will work.

@local-table-of-contents[]

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

Here's a slightly more complicated example. Here, we find all compound
dictionary words: words in @tt{/usr/share/dict/words} that are made by
concatenating two other dictionary words.

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

There are definitely better ways to do this. We naively loop through the entire
dictionary for each dictionary word and see if the concatenation is also part
of the dictionary. There are two ways of making this faster: we can use a
smarter algorithm and more complicated data structures (also known as ``the
right way''), or we can just throw more hardware at the problem (also known as
``the fun way''). As written, this code is an ideal candidate for
parallelization because: @itemlist{@item{We can split up the outer loop of this
dictionary search into parts }@item{Each iteration of the outer loop doesn't
depend on any other iteration; each is @italic{self-contained} }@item{There
isn't very much processing to do after we have the final word list}}

Running this on an Intel Xeon 1.86GHz CPU produced this output:
@verbatim{
cpu time: 11233134 real time: 11231587 gc time: 103748
There are 17658 words.
(("for" . "going") ("tail" . "gating") ("minima" . "list's") ("wise" . "acres") ("mill" . "stone's") ("hare" . "brained") ("under" . "bids") ("Chi" . "lean") ("clod" . "hopper") ("reap" . "points") ("dis" . "missal's") ("scholars" . "hip's") ("over" . "load") ("kilo" . "watts") ("trash" . "cans") ("snaps" . "hot") ("lattice" . "work") ("mast" . "head") ("over" . "coming") ("whole" . "sales"))
}
The above code took 187.2 minutes.

To parallelize this code, we must make three changes:
@itemlist{@item{Change the outer @racket[for/list] form to a
@racket[for/work] form
}@item{Add a @racket[(connect-to-riot-server!)] call in the main submodule
}@item{Start workers. For this example, I ran twenty total workers on four spare lab machines and started the tracker server on @racket["alfred"]}}

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

This version took 18.7 minutes, which is about a factor of 10 improvement. Our
cluster completed about 100 workunits (outer loop iterations) per second. To
make this more efficient, we would want to find some way of splitting the work
up into larger and less workunits to lower the tracker's network overhead.

The tracker caches workunits in memory. Running the program a second time...
@verbatim{
$ ~/racket/bin/racket dict.rkt
cpu time: 30133 real time: 63214 gc time: 772
}
...takes 63 seconds because the tracker remembered the ~100,000 completed
workunits. The program now spent all of its time in network traffic and
appending/shuffling the huge list of results.

@section{In which we present an overview and clarity is achieved}
@defmodule/this-package[main]{
Riot clusters consist of three parts:
@itemlist{@item{A @bold{master program}
}@item{A @bold{tracker} server
}@item{One or more @bold{worker processeses}}}
}

@subsection{The master program}
The master program sends workunits to the tracker and waits for the tracker to
send results back. To do this, the master program uses @racket[for/work], which
sends units of work to the tracker and returns the results. The program can
also use @racket[do-work], @racket[do-work/call], and @racket[do-work/eval]
forms for lower-level control.


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
The double dash separates racket's commandline arguments from the tracker
server's arguments.

@subsection{The workers}
@defmodule/this-package[worker]{
Workers are processes that turn workunits into results. You can start a worker by
running:
@verbatim{
racket -p gcr/riot/worker -- server-host
}
or, more fancy:
@verbatim{
racket -p gcr/riot/worker -- --port 1234 --name worker-name server-host
}
where @tt{--port} and @tt{--name} are optional.

Each worker has a ``client name'' that identifies itself. This defaults to the
machine's hostname followed by a dash and a random string of letters that
uniquely identify multiple workers on that client. To change the first part of
the client name, use the @tt{--name} switch.

In workunits created by the @racket[for/work] and @racket[do-work] forms, each
worker will @racket[require] the module that contains that form. In the case of
@racket[do-work/call] workunits, the worker will @racket[require] the module
named by the @racket[do-work/call] form. To be sure that the worker can find
the module, you must run the worker in the same directory that you ran the
master program relative to the module. For example, if you ran: @verbatim{ $ cd
/tmp/demo; racket simple-demo.rkt } on the master and copied
@tt{simple-demo.rkt} to @tt{/home/worker/demo/simple-demo.rkt} on the
worker, you must run the worker like this: @verbatim{ $ cd /home/worker/demo;
racket -p gcr/riot/worker -- tracker-server }

This also means that each worker must have identical copies of
@tt{simple-demo.rkt}. If the body of a worker's @racket[for/work] form does not
exactly match the master's @racket[for/work] form, it will complain about a
code mismatch. The @racket[for/work] and @racket[do-work] forms check for this,
but @racket[do-work/call] cannot check the version of the module it requires,
so workers with differing versions of those modules will silently misbehave.

A worker shouldn't generate its own workunits. This means you musn't use
@racket[for/work] or @racket[do-work] forms in the top level of a module (or in
any function that runs when the module is required) or else your workers will
attempt to generate workunits of their own. See the
@seclink["problems"]{for/work section} for more details.

}

@subsection[#:tag "restrictions"]{In which we describe the peculiarities of for/work and do-work}
The two easiest ways of submitting workunits are @racket[do-work] and
@racket[for/work].
@defform[(do-work body ...)]{

Packages up the @racket[body ...] expressions to be evaluated in a workunit.
This form returns instantly (after one round-trip to the tracker) and returns a
workunit ID, a string representing a promise to do the work.
Pass this value to @racket[wait-until-done] to retrieve the result of the
@racket[do-work] form.
}
@defform[(for/work (for-clause ...) body ...)]{

Acts just like @racket[for/list], but arranges for each @racket[body ...] to
run in parallell: each iteration creates a workunit using @racket[do-work];
then calls @racket[wait-until-done] on the resulting workunit.

This is essentially equivalent to:
@codeblock{
(let ([workunits (for/list (for-clause ...)
                    (do-work body ...))])
    (for/list ([p workunits]) (wait-until-done p)))
}
}

For @racket[for/work] and @racket[do-work],
any expressions can appear in the @racket[body ...] form as long as they:
@itemlist{@item{@bold{...only refer to @racket[serializable?] values}. If a free variable
is unserializable, the workunit cannot be packaged up for transmission accross
the network to workers.
}@item{...do not cause and do not depend on @bold{global
side effects}. Otherwise, each worker may have different state, causing
unpredictable behavior. }}

The @racket[do-work] form works by wrapping all of the @racket[body ...]
expressions inside a @racket[serial-lambda] with no arguments. This effectively
makes each workunit its own closure. Free variables are @racket[serialize]d
when the workunit is sent to the tracker, and the resulting value is serialized
on the return trip.

Workunits created by @racket[do-work] (and, by extension, @racket[for/work])
can refer to free variables, like this:

@codeblock{
#lang racket
(require (planet gcr/riot))

(define (run)
  (define master-random-number (round (* 100 (random))))
  (define running-workunits
    (for/list ([x (in-range 10)])
      (do-work
       (format "Workunit #~a: Master chose ~a, but we choose ~a."
               x
               master-random-number
               (round (* 100 (random)))))))
  (for ([workunit (in-list running-workunits)])
    (displayln (wait-until-done workunit))))

(module+ main
 (connect-to-riot-server! "localhost")
 (run))
}
@verbatim{
Workunit #0: Master chose 67.0, but we choose 27.0.
Workunit #1: Master chose 67.0, but we choose 51.0.
Workunit #2: Master chose 67.0, but we choose 49.0.
Workunit #3: Master chose 67.0, but we choose 64.0.
Workunit #4: Master chose 67.0, but we choose 62.0.
Workunit #5: Master chose 67.0, but we choose 41.0.
Workunit #6: Master chose 67.0, but we choose 5.0.
Workunit #7: Master chose 67.0, but we choose 54.0.
Workunit #8: Master chose 67.0, but we choose 100.0.
Workunit #9: Master chose 67.0, but we choose 33.0.
}
In this example, the free variable @racket[master-random-number]'s value of
67.0 has been serialized along with the @racket[do-work] body and sent to the
workers.

To ensure that workers use the same version of the code that the master thinks
they're using, @racket[do-work] signs the code with an md5 hash of the
@racket[body ...] expressions. If a worker's hash of a @racket[do-work] body
does not match the master's hash, the worker will complain. Always keep all
worker code up to date.


@subsection[#:tag "problems"]{In which, with a heavy heart, we outline restrictions and limitations of for/work and do-work}

The @racket[for/work] and @racket[do-work] forms don't transmit their code;
they only transmit the free variables that the bodies refer to. This creates a
number of constraints:

@itemlist[
@item{@racket[for/work] and @racket[do-work] must be inside a module and this
module must be manually copied to each worker. These forms won't work from the REPL.}
@item{@racket[for/work] and @racket[do-work] do not currently work within
submodules.}
@item{As mentioned earlier, all free variables that the body refers to must be
  serializable. This means using serialize-struct instead of normal structs and
  taking care to ensure that all required libraries do the same.}

@item{Be careful about referring to large variables. Top-level variables are
OK, but if you dynamically generate a large variable in a function (say, our
dictionary) outside of the workunit, the network overhead of transferring
the entire dictionary will dwarf the computation time of the workunit.

In other words, this is perfectly fine because @racket[dictionary] is in the
top-level:

@codeblock{
;; Acceptable!
(define dictionary (list->set (file->lines "/usr/share/dict/words")))
(define (word-combinations)
   (for/work ([word (in-set dictionary)])
     ... word ...))
}

Each worker will load the dictionary once when the file is required and use
that copy for each workunit.

This, however, will send an entire copy of the dictionary along with each and
every workunit:
@codeblock{
;; Inefficient!
(define (word-combinations)
  (define dictionary (list->set (file->lines "/usr/share/dict/words")))
  (for/work ([word (in-set dictionary)])
     ... word ...))
}
}

@item{When workers attempt to execute a workunit created by a @racket[do-work]
  or @racket[for/work] form, they @racket[require] the module and search for the code
  to be executed. Be sure that workers won't execute either of these forms when
  the module is @racket[require]d, or else your workers will try to create
  workunits of their own!}
]

@subsection{In which we describe the numerous kinds of workunits and how to create them}
There's more to riot than @racket[for/work] and @racket[do-work]. If those
functions seem too magical, you may be more comfortable with these instead.

@defproc[(do-work/call [module module-path?]
                       [exported-fun symbol?]
                       [arg serializable?] ...)
                       any/c]{

Accepts a module path and an exported symbol in that module. Workers will
require @racket[module] and run @racket[(exported-fun arg ...)].
Be sure that workers have the latest version of the module, or you may get
incorrect results -- this function does not sign the module's code or perform
any version checking.

Returns instantly (after one round-trip to the tracker) and returns a workunit
ID, a string representing a promise to do the work. Pass this value to
@racket[wait-until-done] to return the value of the called function.

Example:

@codeblock{
#lang racket
;; This is do-work-call.rkt
(require (planet gcr/riot))

(provide double)
(define (double x)
  (* x 2))

(define (run)
  (define running-workunits
    (for/list ([x (in-range 10)])
      (do-work/call "do-work-call.rkt" 'double x)))
  (map wait-until-done running-workunits))

(module+ main
 (connect-to-riot-server! "localhost")
 (run))
}
This produces @racketresult[
'(0 2 4 6 8 10 12 14 16 18)
]
}

@defproc[(do-work/eval [datum any/c]) any/c]{
Creates a workunit that causes workers to @racket[(eval datum)], with all the
nightmarish implications that entails.

Returns instantly (after one round-trip to the tracker) and returns a workunit
ID, a string representing a promise to do the work. Pass this value to
@racket[wait-until-done] to return the evaluated value of @racket[datum].

This is the only function that does not require workers to share any code with
the master.

Example:

@codeblock{
#lang racket
(require (planet gcr/riot))
(connect-to-riot-server! "localhost")
(wait-until-done (do-work/eval '(+ 3 5)))
}
produces @racketresult[8].
}

@defproc[(wait-until-done [workunit-id any/c]) any/c]{

Waits until the given @racket[workunit-id] is finished, and returns the result.
If a worker throws an exception while running the workunit , this function
will throw an exception in the master program.
}

@defproc[(call-when-done [workunit-id any/c]
                         [thunk (-> boolean? any/c any/c any/c)]) any/c]{
Returns instantly, but sets up @racket[thunk] to be called in its own thread
once the given @racket[workunit-id] finishes.

Riot will call @racket[(thunk error? client-name result)]. If the workunit
succeeds, @racket[error?] is @racket[#f], @racket[client-name] is the ID of
the client that finished the workunit, and @racket[result] is the result of the
workunit. If the workunit fails, @racket[error?] is @racket[#t] and
@racket[result] is the message of the exception that caused the workunit to fail.
}

@defproc[(connect-to-riot-server! [hostname string?]
[port exact-integer? 2355]
[client-name exact-integer? (gethostname)]) any/c]{
Connects to the tracker server at @racket[hostname] and returns nothing. This function also sets @racket[current-client] to the
resulting @racket[client?] object.
}
@defparam[current-client client-obj client?]{
The parameter that represents the currently connected tracker. Used internally
by the above functions
}

@section[#:tag "lowlevel"]{In which we present a lower-level client API for communicating with the tracker}
@defmodule/this-package[client]{
This module contains lower-level bindings for communicating with the tracker.
Both the master prgoram and workers use it.
}

@defproc[(client? [maybe-client any/c]) boolean?]{
Returns @racket[#t] if @racket[maybe-client] is the result of
@racket[connect-to-tracker].
}

@defproc[(connect-to-tracker [hostname string?]
[port exact-integer? 2355]
[client-name exact-integer? (gethostname)]) client?]{
Connects to the tracker server at @racket[hostname], reports a client ID of
@racket[client-name], and returns a @racket[client?] upon successful
connection.
}
@defproc[(client-who-am-i [client client?]) any/c]{
The server will append a nonce to your client ID. Call this function to return
your full client ID as chosen by the server.
}
@defproc[(client-workunit-info [client client?] [workunit-id any/c])
         (list/c symbol? any/c any/c any/c)]{
Returns information about the given @racket[workunit-id]:
@racketblock[(list status wu-client result last-change)]
where @racket[status] is one of @racket['waiting], @racket['running],
@racket['done], or @racket['error]; @racket[wu-client] is the client ID of the
worker processing the workunit (or @racket[#f]); @racket[result] is the value
of the workunit if completed or the error message if broken; and
@racket[last-change] is the server's @racket[(current-inexact-milliseconds)]
when the workunit's status last changed.
}
@defproc[(client-call-with-workunit-info [client client?] [workunit-id any/c]
[thunk (-> symbol? any/c any/c any/c any/c)]) any/c]{
Like above, but immediately returns. Later, @racket[thunk] will be called in its own
thread with each of the arguments in the above list}

@defproc[(client-wait-for-work [client client?]) (list/c wu-key? any/c)]{
Signals that you're waiting for work and blocks until the tracker assigns you a
workunit. The result is @racket[(list workunit-key workunit-data)].

After this function returns, you will own that workunit; it will not be
assigned to other clients until you disconnect from the tracker or until you
call @racket[client-complete-workunit!].
}
@defproc[(client-call-with-work [client client?] [thunk
(-> wu-key? any/c any/c)]) any/c]{
Like above, but returns instantly. Later, @racket[thunk] will be called in its own
thread when the tracker assigns a workunit to us, with arguments @racket[workunit-key]
and @racket[data]..
Its return value is NOT used as the workunit's result; you must call @racket[client-complete-workunit!].
}
@defproc[(client-add-workunit [client client?] [data serializable?]) any/c]{
Adds a workunit with the given @racket[data] and blocks until the tracker
returns the new workunit's key.

Note that @racket[data] must be in a special format; you should rarely need to
call this function. Look at the source code for @tt{worker.rkt} to see how
workers parse this.
}
@defproc[(client-call-with-new-workunit [client client?] [data serializable?]
[thunk (-> any/c any/c)]) any/c]{
Like above, but returns instantly, calling @racket[(thunk new-workunit-key)] in
its own thread when the tracker assigns us a workunit.
}
@defproc[(client-wait-for-finished-workunit [client client?] [workunit any/c])
(list/c wu-key? symbol? any/c any/c)]{
Waits for the given @racket[workunit] to complete, returning @racket[(list
wu-key status client result)] as in @racket[client-workunit-info].
}
@defproc[(client-call-with-finished-workunit [client client?] [workunit any/c]
[thunk (-> wu-key? symbol? any/c any/c any/c)]) any/c]{
Arranges for @racket[thunk] to be called in its own thread when
@racket[workunit] finishes, with args like the above list.
}

@defproc[(client-complete-workunit! [client client?] [workunit any/c] [error?
boolean?] [result serializable?]) any/c]{
Sends @racket[result] to the tracker as the result of the @racket[workunit]. If
the workunit fails, @racket[error?] should be @racket[#t] and @racket[result]
should be a
message indicating what went wrong.
}

@section{In which we outline licensing and copyrights}

The code in this @tt{(planet gcr/riot)} package and this documentation is
under the zlib license, reproduced below.

@verbatim{
Copyright (c) 2012 gcr

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

   1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.

   2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.

   3. This notice may not be removed or altered from any source
   distribution.
}
