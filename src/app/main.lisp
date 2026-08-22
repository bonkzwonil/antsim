;;;; app/main.lisp — the command line of the shipped binary.
;;;;
;;;; Everything above this file is a library: you load a system into a
;;;; REPL and call a function.  That is the right shape for the work, and
;;;; the wrong shape for handing somebody a simulation to look at.  This
;;;; file is the only place that knows a *program* exists — argv, exit
;;;; codes, a usage message, and the small amount of care a saved image
;;;; needs that a fresh SBCL does not.
;;;;
;;;; Scope, deliberately: the binary opens the live window (§5.5).  It is
;;;; not a headless renderer.  The headless path goes through EGL, which
;;;; is a driver library on Linux and simply absent on Windows, so making
;;;; it part of the shipped surface would mean shipping two different
;;;; programs under one name.  `make smoke` and `make gallery` stay
;;;; developer targets, run from a checkout.

(in-package #:antsim)

(defparameter *version* "0.0.0-dev"
  "Set at build time by scripts/build-binary.lisp from antsim.asd's
:version, so the binary cannot claim a version the system does not.
A checkout that calls MAIN from a REPL sees the placeholder, which is
honest: a REPL is not a release.")

(defparameter *program-name* "antsim")

;;; --- where the shipped files are -------------------------------------
;;;
;;; A binary with no scenarios can only ever show the demo, so both
;;; packages ship `scenarios/` beside the executable.  The two layouts
;;; differ and neither is guessable from inside Lisp, hence a search path
;;; rather than a single answer:
;;;
;;;   AppImage   $APPDIR/usr/share/antsim/scenarios/   ($APPDIR is set by
;;;              the AppImage runtime before our process starts)
;;;   Windows    <dir of antsim.exe>\scenarios\
;;;   checkout   ./scenarios/, relative to the current directory
;;;
;;; ANTSIM_SCENARIOS overrides all of it, which is what makes a packaged
;;; binary testable against a working tree.

(defun executable-directory ()
  "Directory holding the running executable, or NIL if we cannot tell."
  (let ((argv0 (or (uiop:argv0) "")))
    (when (plusp (length argv0))
      (let ((true (ignore-errors (truename (pathname argv0)))))
        (when true
          (make-pathname :name nil :type nil :version nil :defaults true))))))

(defun scenario-search-path ()
  "Directories to search for a scenario given by name rather than path."
  (let ((override (uiop:getenv "ANTSIM_SCENARIOS"))
        (appdir (uiop:getenv "APPDIR"))
        (exe (executable-directory)))
    (remove nil
            (list (when override (uiop:ensure-directory-pathname override))
                  (when appdir
                    (uiop:ensure-directory-pathname
                     (concatenate 'string appdir "/usr/share/antsim/scenarios")))
                  (when exe (merge-pathnames "scenarios/" exe))
                  #p"scenarios/"))))

(defun find-scenario (name)
  "Resolve NAME to a scenario file, or NIL.

An existing path wins outright, so a file anywhere on disk can always be
run.  Otherwise NAME is the name of a shipped scenario, with or without
the .json — `antsim goss-double-bridge` is what somebody who has read
the list will actually type."
  (or (ignore-errors (probe-file name))
      (let ((file (if (equal "json" (pathname-type (pathname name)))
                      name
                      (concatenate 'string name ".json"))))
        (loop for dir in (scenario-search-path)
              for hit = (ignore-errors (probe-file (merge-pathnames file dir)))
              when hit do (return hit)))))

(defun shipped-scenarios ()
  "The scenario files found on the search path; the first directory that
has any wins, so a checkout's ./scenarios does not get mixed into an
installed set."
  (loop for dir in (scenario-search-path)
        for files = (ignore-errors (directory (merge-pathnames "*.json" dir)))
        when files do (return (sort files #'string< :key #'pathname-name))))

;;; --- waking up in a different process --------------------------------
;;;
;;; A saved image remembers everything, including several things it has
;;; no business remembering across machines.  Three of them matter here,
;;; and all three fail *silently* rather than loudly, which is why this
;;; runs unconditionally at startup rather than being left to whoever
;;; notices the black window:
;;;
;;;   1. Foreign libraries.  SBCL reopens each one *by the path it was
;;;      opened with*, and cl-opengl's resolves to an absolute path on the
;;;      build machine — measured, not feared: a build here recorded
;;;      /gnu/store/…-mesa-26.0.2/lib/libGL.so.1.  A user has no such
;;;      directory, and the image would die before printing anything.  So
;;;      the build closes those and lists them here, and we open them
;;;      again by *name*, which is the one form that re-resolves through
;;;      the loader — and therefore the form that lets an AppImage's
;;;      bundled copy win on LD_LIBRARY_PATH.  Libraries already recorded
;;;      by soname (GLFW) are left alone; they relocate by themselves.
;;;
;;;   2. antsim-gl::*preloaded* holds the driver directory of the build
;;;      machine.  Left set, PRELOAD-DRIVER-GL is a no-op on the user's
;;;      machine and the libGL trap (§5.4) is back, with the twist that
;;;      the directory it is proud of having resolved no longer exists.
;;;
;;;   3. cl-opengl caches every extension entry point as a raw pointer
;;;      into the GL implementation that was loaded when the pointer was
;;;      taken.  In a fresh process those addresses are meaningless.  The
;;;      library provides RESET-GL-POINTERS for exactly this moment; it is
;;;      internal, so we look it up rather than depend on the symbol.
;;;
;;;   4. *default-pathname-defaults* is the build directory.  A relative
;;;      scenario path typed by the user must resolve against *their*
;;;      working directory, not against a path on a CI runner.
;;;
;;; None of this is needed when MAIN is called from a REPL, and none of it
;;; does any harm there either — which is what makes it testable without
;;; building an image.

(defparameter *reopen-libraries* '()
  "Names of CFFI foreign libraries the build closed, to be opened again on
startup.  Filled in by scripts/build-binary.lisp; empty in a REPL, where
nothing was closed and there is nothing to reopen.")

(defparameter *missing-libraries* '()
  "(name . reason) for each of *REOPEN-LIBRARIES* that would not open.

Recorded rather than signalled.  A missing GLFW means no window, and
nothing else — `--version`, `--help` and `--list` have no business
failing because a graphics library is absent, and a user diagnosing why
the window will not open is exactly the user who needs `--list` to
work.")

(defun image-restart-init ()
  "Undo the parts of image state that do not survive a change of machine.
Installed as an SBCL init hook by scripts/build-binary.lisp."
  (setf *default-pathname-defaults* (uiop:getcwd))
  (setf antsim-gl::*preloaded* nil
        *egl-loaded* nil)
  ;; The driver first, then everything else: the whole point of the
  ;; preload is to be the GL that is already in the process by the time
  ;; cl-opengl's library is opened (§5.4).  Quiet, because the live
  ;; window's GL comes from GLFW and never touches EGL — a machine with no
  ;; libEGL runs the shipped binary perfectly well and deserves no
  ;; warning.
  (ignore-errors (antsim-gl:preload-driver-gl :quiet t))
  (setf *missing-libraries* '())
  (dolist (name *reopen-libraries*)
    (handler-case (cffi:load-foreign-library name)
      (error (c)
        (push (cons name (princ-to-string c)) *missing-libraries*))))
  (setf *missing-libraries* (nreverse *missing-libraries*))
  (let ((reset (find-symbol (string '#:reset-gl-pointers) '#:cl-opengl-bindings)))
    (when (and reset (fboundp reset))
      (ignore-errors (funcall reset))))
  (values))

;;; --- argv -------------------------------------------------------------

(define-condition usage-error (error)
  ((text :initarg :text :reader usage-error-text))
  (:report (lambda (c s) (write-string (usage-error-text c) s))))

(defun parse-integer-arg (flag value)
  (or (and value (ignore-errors (parse-integer value)))
      (error 'usage-error
             :text (format nil "~a wants a number, got ~:[nothing~;~:*~s~]"
                           flag value))))

(defun usage ()
  (format nil "~
antsim ~a — a 2D ant colony simulation on real behavioural science.

usage: ~a [options] [scenario]

  scenario          a .json scenario file, or the name of a shipped one
                    (see --list).  With none, the built-in demo runs.

options:
  --seed N          repeat an earlier run exactly.  Without it a fresh
                    seed is drawn and printed, so no two sessions match.
  --width N         window width in pixels (default 1100)
  --height N        window height in pixels (default 800)
  --tui             watch it in this terminal instead of a window, drawn
                    in characters.  Needs no graphics stack at all.
                    Linux and BSD only — it is termios, which Windows
                    does not have.
  --ascii           plain ASCII glyphs rather than arrows.  Shows the
                    axis an ant is walking on, but not which way along it
  --no-colour       no colour, for a terminal or a log that wants none
  --cols N          force the width in columns (default: ask the terminal)
  --rows N          force the height in rows (default: ask the terminal)
  --list            list the scenarios shipped with this binary
  --version         print the version and exit
  -h, --help        this text

in the terminal (--tui):
  arrows or hjkl    pan; hold shift, or use HJKL, to move a page
  z / Z             zoom in and out
  space             pause
  .                 advance a single tick
  + / -             time compression, halving and doubling
  f                 frame the whole world
  t                 show the next colony's trail
  a                 switch between ASCII and arrows
  c                 colour on or off
  ?                 show or hide the key legend
  q or escape       quit

in the window:
  wheel             zoom, anchored at the cursor
  right-drag        pan
  left-click        inspect the ant under the pointer
  a                 drop a food source at the cursor
  o                 drop a block of terrain at the cursor; hold to draw a wall
  p                 poke the nest under the cursor, and watch it erupt
  n                 resting ants block, or are walked through
  c                 ant-ant contact on or off
  space             pause
  + / -             time compression, halving and doubling
  home              frame the whole world
  h or ?            show or hide the key legend
  q or escape       quit
"
          *version* *program-name*))

(defstruct (cli (:conc-name cli-))
  (scenario nil)
  (seed nil)
  (width 1100)
  (height 800)
  ;; The terminal view's three.  COLS and ROWS are NIL by default and
  ;; stay that way in normal use — the terminal knows its own size and it
  ;; changes while the program runs, so asking is right and guessing is
  ;; not.  They exist for the case where a size has to be forced.
  (cols nil)
  (rows nil)
  (charset :unicode)
  (colour t)
  (action :run))                        ; :run :tui :list :version :help

(defun parse-command-line (args)
  "ARGS is argv without the program name.  Returns a CLI, or signals
USAGE-ERROR."
  (let ((cli (make-cli)))
    (loop while args
          for arg = (pop args)
          do (cond
               ((string= arg "--list")    (setf (cli-action cli) :list))
               ((string= arg "--version") (setf (cli-action cli) :version))
               ((or (string= arg "-h") (string= arg "--help"))
                (setf (cli-action cli) :help))
               ((string= arg "--seed")
                (setf (cli-seed cli) (parse-integer-arg "--seed" (pop args))))
               ((string= arg "--width")
                (setf (cli-width cli) (parse-integer-arg "--width" (pop args))))
               ((string= arg "--height")
                (setf (cli-height cli) (parse-integer-arg "--height" (pop args))))
               ;; --- the terminal view (§5.6) ---------------------------
               ;; An action keyword rather than a subcommand.  There are
               ;; no subcommands in this program and inventing the first
               ;; one for a second view would change how every argument
               ;; is read, to say something a flag says just as well.
               ((string= arg "--tui")   (setf (cli-action cli) :tui))
               ((string= arg "--ascii") (setf (cli-charset cli) :ascii))
               ;; Both spellings.  The rest of the program is written in
               ;; British English and half the world is not, and an
               ;; option that rejects the other spelling teaches nothing
               ;; except that it was written by somebody in a hurry.
               ((or (string= arg "--no-colour") (string= arg "--no-color"))
                (setf (cli-colour cli) nil))
               ((string= arg "--cols")
                (setf (cli-cols cli) (parse-integer-arg "--cols" (pop args))))
               ((string= arg "--rows")
                (setf (cli-rows cli) (parse-integer-arg "--rows" (pop args))))
               ;; A lone "--" ends the options.  The only way to run a
               ;; file genuinely named "--list" — cheap, and the absence
               ;; of it is the kind of thing that is noticed once, in
               ;; anger, years later.
               ((string= arg "--")
                (when args (setf (cli-scenario cli) (pop args)))
                (setf args nil))
               ((and (> (length arg) 1) (char= #\- (char arg 0)))
                (error 'usage-error
                       :text (format nil "unknown option ~a~%~%~a" arg (usage))))
               ((cli-scenario cli)
                (error 'usage-error
                       :text (format nil "two scenarios given: ~a and ~a"
                                     (cli-scenario cli) arg)))
               (t (setf (cli-scenario cli) arg))))
    cli))

;;; --- the program ------------------------------------------------------

(defun print-scenario-list (stream)
  (let ((files (shipped-scenarios)))
    (if (null files)
        (format stream "~&No scenarios found.  Looked in:~%~{  ~a~%~}"
                (scenario-search-path))
        (progn
          (format stream "~&Scenarios shipped with this binary~
                          ~%(run one with: ~a NAME)~%~%" *program-name*)
          (dolist (f files)
            (format stream "  ~a~%" (pathname-name f)))))))

(defun report-missing-libraries (stream)
  "Explain a failed startup reopen, in the terms of the thing the user is
holding.  Named libraries only, so the message can name the package to
install rather than a path we guessed."
  (format stream "~&~a: the graphics libraries this needs are not on this ~
                  machine.~%~%~{  ~a~%      ~a~%~}~%"
          *program-name*
          (loop for (name . reason) in *missing-libraries*
                collect name collect reason))
  (format stream "~
On Ubuntu and Debian:      sudo apt install libglfw3 libgl1~%~
On Fedora:                 sudo dnf install glfw mesa-libGL~%~
On Guix:                   guix shell glfw mesa -- ~a~%~%~
The AppImage bundles GLFW, so a plain binary showing this is usually a~%~
binary that was unpacked out of one.~%"
          *program-name*))

(defun resolve-scenario (name)
  "The path a scenario name resolves to, or NIL having said why.

One copy, because two views now want a scenario and the message names
the search path and the next step — the sort of text that is quietly
corrected in one place and left stale in the other."
  (let ((path (find-scenario name)))
    (unless path
      (format *error-output*
              "~&~a: no scenario ~s.  Looked in:~%~{  ~a~%~}~%Try --list.~%"
              *program-name* name (scenario-search-path)))
    path))

(defun run-cli (cli)
  "Do what CLI says.  Returns a process exit code."
  (ecase (cli-action cli)
    (:help    (write-string (usage) *standard-output*) 0)
    (:version (format t "~&antsim ~a~%" *version*) 0)
    (:list    (print-scenario-list *standard-output*) 0)
    (:run
     ;; Checked here and not at startup: a window is the only thing that
     ;; needs these, and a program that complains about graphics while
     ;; being asked for its version number is a program nobody trusts.
     ;; Note that :TUI below is not guarded — a terminal view refusing to
     ;; start because libGL is absent would be exactly backwards, that
     ;; being the case it exists for.
     (when *missing-libraries*
       (report-missing-libraries *error-output*)
       (return-from run-cli 3))
     (let ((name (cli-scenario cli)))
       (if (null name)
           (live-demo :width (cli-width cli) :height (cli-height cli)
                      :seed (cli-seed cli))
           (let ((path (resolve-scenario name)))
             (unless path (return-from run-cli 2))
             (live-scenario path :width (cli-width cli) :height (cli-height cli)
                                 :seed (cli-seed cli)))))
     0)
    (:tui
     ;; Windows has no terminal view: it is termios and TIOCGWINSZ, and
     ;; sb-posix there does not have those symbols at all, so antsim/tui
     ;; is not built into this binary (see antsim.asd).  The flag is still
     ;; *parsed* everywhere, deliberately — a Windows user who copies a
     ;; command line off the README should be told what is going on, not
     ;; told `--tui` is an unknown option, which reads like a typo.
     #+windows
     (progn
       (format *error-output*
               "~&~a: --tui is not available on this build.~%~
                The terminal view needs POSIX termios, which Windows does ~
                not provide.~%Run it without --tui to open the window ~
                instead.~%"
               *program-name*)
       2)
     #-windows
     (let ((name (cli-scenario cli)))
       (if (null name)
           (tui-demo :seed (cli-seed cli)
                     :charset (cli-charset cli) :colour (cli-colour cli)
                     :cols (cli-cols cli) :rows (cli-rows cli))
           (let ((path (resolve-scenario name)))
             (unless path (return-from run-cli 2))
             (tui-scenario path :seed (cli-seed cli)
                                :charset (cli-charset cli)
                                :colour (cli-colour cli)
                                :cols (cli-cols cli) :rows (cli-rows cli))))))))

(defun main (&optional (args (uiop:command-line-arguments)))
  "Entry point of the shipped binary.  Returns a process exit code.

Every error becomes a printed line and a non-zero code rather than a
debugger prompt: a saved image has no REPL to drop into, and a windowed
program that dies into an SBCL backtrace produces a bug report nobody
can read.  The backtrace is still there — ANTSIM_DEBUG=1 lets the
condition through, so a developer running the shipped binary gets the
real thing rather than our summary of it."
  (flet ((go! () (run-cli (parse-command-line args))))
    (if (uiop:getenv "ANTSIM_DEBUG")
        (go!)
        (handler-case (go!)
          (usage-error (c)
            (format *error-output* "~&~a: ~a~%" *program-name* c)
            2)
          ;; ^C is a way to quit a window that will not close, not a crash.
          (sb-sys:interactive-interrupt ()
            (format *error-output* "~&~%interrupted~%")
            130)
          (error (c)
            (format *error-output* "~&~a: ~a~%~
                                    (set ANTSIM_DEBUG=1 for a backtrace)~%"
                    *program-name* c)
            1)))))
