;;;; tests/app.lisp — the shipped binary's command line.
;;;;
;;;; A separate suite, and a separate system, for one reason: antsim/app
;;;; sits on antsim/live, which loads GLFW at load time.  The core suite
;;;; must keep running on a machine with no graphics stack at all — that
;;;; is the point of the split in §4.1 — so these tests cannot live in it.
;;;;
;;;; They test the part of the program that has no window in it: argv, the
;;;; scenario search path, the exit codes.  That is not a modest target.
;;;; The window is exercised every time anybody runs the thing; the argv
;;;; parser is exercised by a user typing something slightly wrong, once,
;;;; and it either says so or does something surprising.  Of the two, this
;;;; is the half that fails quietly.

(defpackage #:antsim/app-test
  (:use #:cl #:fiveam)
  (:export #:app))

(in-package #:antsim/app-test)

(def-suite app)
(in-suite app)

(defun %parse (&rest args)
  (ant:parse-command-line args))

(defmacro %usage-error (&body args)
  `(signals ant:usage-error (%parse ,@args)))

;;; --------------------------------------------------------------- argv

(test defaults-with-no-arguments
  "No arguments is the commonest invocation there is: somebody
double-clicked it.  It has to mean the demo, at a sane size."
  (let ((c (%parse)))
    (is (eq :run (ant::cli-action c)))
    (is (null (ant::cli-scenario c)))
    (is (null (ant::cli-seed c)))
    (is (= 1100 (ant::cli-width c)))
    (is (= 800 (ant::cli-height c)))))

(test a-bare-argument-is-the-scenario
  (is (equal "foraging" (ant::cli-scenario (%parse "foraging"))))
  (is (equal "/tmp/x.json" (ant::cli-scenario (%parse "/tmp/x.json")))))

(test options-are-read
  (let ((c (%parse "--seed" "42" "--width" "640" "--height" "480" "goss")))
    (is (= 42 (ant::cli-seed c)))
    (is (= 640 (ant::cli-width c)))
    (is (= 480 (ant::cli-height c)))
    (is (equal "goss" (ant::cli-scenario c)))))

(test options-may-follow-the-scenario
  "Nobody remembers whether the flags come first.  Both orders mean the
same thing, and this is the test that keeps it that way."
  (let ((c (%parse "goss" "--seed" "7")))
    (is (equal "goss" (ant::cli-scenario c)))
    (is (= 7 (ant::cli-seed c)))))

(test actions
  (is (eq :list    (ant::cli-action (%parse "--list"))))
  (is (eq :version (ant::cli-action (%parse "--version"))))
  (is (eq :help    (ant::cli-action (%parse "--help"))))
  (is (eq :help    (ant::cli-action (%parse "-h")))))

(test double-dash-ends-the-options
  "The escape hatch for a file whose name starts with a dash.  Cheap to
have, and impossible to add later without breaking someone."
  (let ((c (%parse "--" "--list")))
    (is (eq :run (ant::cli-action c)))
    (is (equal "--list" (ant::cli-scenario c)))))

(test bad-input-is-a-usage-error-not-a-surprise
  "Each of these used to have an obvious wrong behaviour available to it:
silently ignoring the flag, taking zero for the number, or quietly
forgetting the first of two scenarios.  A signalled error is the whole
point — MAIN turns it into a message and exit code 2."
  (%usage-error "--nonsense")
  (%usage-error "--seed")                ; nothing after it
  (%usage-error "--seed" "banana")
  (%usage-error "--width" "wide")
  (%usage-error "--height")
  (%usage-error "one.json" "two.json"))

(test negative-and-zero-seeds-are-accepted-as-typed
  "The seed is folded into 32 bits by LIVE-SEED, not here.  Parsing must
not reject a number it is not the judge of."
  (is (= 0 (ant::cli-seed (%parse "--seed" "0"))))
  (is (= -1 (ant::cli-seed (%parse "--seed" "-1")))))

;;; ------------------------------------------------- the scenario search

(defun %scenarios-dir ()
  (merge-pathnames "scenarios/" (asdf:system-source-directory "antsim")))

(defmacro %with-scenario-path (&body body)
  "Point the search path at this checkout's scenarios, the way a package
points it at its own."
  `(let ((old (uiop:getenv "ANTSIM_SCENARIOS")))
     (unwind-protect
          (progn (setf (uiop:getenv "ANTSIM_SCENARIOS")
                       (namestring (%scenarios-dir)))
                 ,@body)
       (setf (uiop:getenv "ANTSIM_SCENARIOS") (or old "")))))

(test scenarios-resolve-by-name
  (%with-scenario-path
    (is-true (ant:find-scenario "foraging"))
    (is-true (ant:find-scenario "foraging.json"))
    (is-true (ant:find-scenario "goss-double-bridge"))))

(test an-unknown-scenario-resolves-to-nil
  "NIL and not an error: RUN-CLI turns it into a message that lists the
directories it looked in, which is the only form of this failure a user
can act on."
  (%with-scenario-path
    (is (null (ant:find-scenario "no-such-scenario")))))

(test an-existing-path-wins-over-the-search
  "A file on disk is run because it is a file on disk, wherever it is —
otherwise the program could only ever run its own shipped set."
  (%with-scenario-path
    (let ((p (merge-pathnames "foraging.json" (%scenarios-dir))))
      (is (equal (truename p) (ant:find-scenario (namestring p)))))))

(test the-shipped-set-is-found-and-sorted
  (%with-scenario-path
    (let ((names (mapcar #'pathname-name (ant:shipped-scenarios))))
      (is-true (member "foraging" names :test #'string=))
      (is-true (member "goss-double-bridge" names :test #'string=))
      (is (equal names (sort (copy-list names) #'string<))))))

(test the-env-override-comes-first
  "ANTSIM_SCENARIOS is what makes a packaged binary testable against a
working tree, so it has to outrank everything the binary infers."
  (%with-scenario-path
    (is (equal (uiop:ensure-directory-pathname (%scenarios-dir))
               (first (ant:scenario-search-path))))))

;;; -------------------------------------------------------------- exits

(defun %quietly (thunk)
  "Run THUNK with its output discarded, and return what it returned.
Only the call is muffled, not the assertion about it — muffling the whole
test would take FiveAM's own progress output with it."
  (let ((*standard-output* (make-broadcast-stream)))
    (funcall thunk)))

(test help-and-version-report-success
  (is (zerop (%quietly (lambda () (ant:run-cli (%parse "--help"))))))
  (is (zerop (%quietly (lambda () (ant:run-cli (%parse "--version"))))))
  (%with-scenario-path
    (is (zerop (%quietly (lambda () (ant:run-cli (%parse "--list"))))))))

(test an-unknown-scenario-exits-2-without-opening-anything
  (%with-scenario-path
    (let ((*error-output* (make-broadcast-stream)))
      (is (= 2 (ant:run-cli (%parse "definitely-not-a-scenario")))))))

(test main-turns-a-usage-error-into-an-exit-code
  "The contract MAIN exists for: no debugger, no backtrace, a number."
  (let ((*error-output* (make-broadcast-stream)))
    (is (= 2 (ant:main '("--nonsense"))))))

(test the-usage-text-carries-the-version
  (is (search ant:*version* (ant:usage)))
  (is (search "--seed" (ant:usage)))
  (is (search "--list" (ant:usage))))

;;; ------------------------------------------------------- the terminal view

(test the-terminal-view-is-an-action-like-the-others
  "A flag rather than a subcommand: there are none in this program, and
inventing the first one for a second view would change how every argument
is read to say what a flag says just as well."
  (is (eq :tui (ant::cli-action (%parse "--tui"))))
  (is (eq :run (ant::cli-action (%parse))))
  ;; and it composes with everything else, in either order
  (let ((c (%parse "--tui" "--seed" "9" "goss")))
    (is (eq :tui (ant::cli-action c)))
    (is (= 9 (ant::cli-seed c)))
    (is (equal "goss" (ant::cli-scenario c))))
  (let ((c (%parse "goss" "--seed" "9" "--tui")))
    (is (eq :tui (ant::cli-action c)))
    (is (equal "goss" (ant::cli-scenario c)))))

(test the-terminal-views-own-options
  "--cols and --rows default to NIL and mean \"ask the terminal\".  A
default of eighty by twenty-four would be a guess wearing the clothes of
a measurement."
  (let ((c (%parse)))
    (is (null (ant::cli-cols c)))
    (is (null (ant::cli-rows c)))
    (is (eq :unicode (ant::cli-charset c)))
    (is (eq t (ant::cli-colour c))))
  (let ((c (%parse "--tui" "--cols" "120" "--rows" "40" "--ascii")))
    (is (= 120 (ant::cli-cols c)))
    (is (= 40 (ant::cli-rows c)))
    (is (eq :ascii (ant::cli-charset c)))))

(test colour-is-spelled-both-ways
  "The program is written in British English and half the world is not.
An option that rejects the other spelling teaches nothing except that it
was written by somebody in a hurry."
  (is (null (ant::cli-colour (%parse "--no-colour"))))
  (is (null (ant::cli-colour (%parse "--no-color")))))

(test the-terminal-view-is-not-blocked-by-missing-graphics-libraries
  "The guard belongs to the window and stays there.  A terminal view
refusing to start because libGL is absent would be exactly backwards —
that is the case it exists for."
  (%with-scenario-path
    (let ((*error-output* (make-broadcast-stream))
          (ant::*missing-libraries* '(("libGL.so.1" . "not found"))))
      ;; Exit 2 for the unresolvable scenario, and specifically not 3,
      ;; which is what the missing-library guard would have returned.
      (is (= 2 (ant:run-cli (%parse "--tui" "definitely-not-a-scenario")))))))

(test the-usage-text-mentions-the-terminal-view
  (is (search "--tui" (ant:usage)))
  (is (search "--ascii" (ant:usage)))
  (is (search "--no-colour" (ant:usage)))
  (is (search "--cols" (ant:usage))))
