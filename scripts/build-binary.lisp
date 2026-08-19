;;;; scripts/build-binary.lisp — save the shipped executable.
;;;;
;;;; Run it as:  sbcl --script scripts/build-binary.lisp [output-path]
;;;; or, from the top of the tree, `make binary`.
;;;;
;;;; The output is one file: an SBCL runtime with the whole image glued to
;;;; it.  What it is *not* is self-contained — the GL implementation and
;;;; GLFW are shared libraries and stay shared libraries, because the
;;;; first of them belongs to the user's graphics driver and cannot be
;;;; shipped by us at all.  Making that difference disappear is the
;;;; packaging step's job, not this file's: see packaging/ and
;;;; docs/shipping.md.
;;;;
;;;; Environment:
;;;;   ANTSIM_BINARY        output path (also positional argv[1])
;;;;   ANTSIM_COMPRESS      "1" to zstd-compress the core, when this SBCL
;;;;                        was built with :sb-core-compression.  Off by
;;;;                        default: it roughly halves a ~60 MB file at
;;;;                        the cost of a slower start, and not every
;;;;                        distribution's SBCL has the feature.
;;;;   ANTSIM_VERSION       override the version string (CI passes the tag)

(require :asdf)

;;; Quicklisp, if the machine has it.  CI installs it; a Guix checkout may
;;; instead have the dependencies on the source registry already, and then
;;; ASDF alone is enough.  Trying both, in that order, is what lets one
;;; script serve both.
(let ((setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file setup) (load setup)))

;;; The same trick the Makefile uses: make this checkout findable without
;;; anything having been symlinked into ~/quicklisp/local-projects, so a
;;; clean CI job needs no setup step beyond installing Quicklisp itself.
(let ((here (uiop:pathname-parent-directory-pathname
             (uiop:pathname-directory-pathname *load-truename*))))
  (push here asdf:*central-registry*)
  (setf (uiop:getenv "CL_SOURCE_REGISTRY")
        (concatenate 'string (namestring here) ":")))

(defun quickload (system)
  (let ((ql (find-symbol (string '#:quickload) '#:ql)))
    (if ql (funcall ql system) (asdf:load-system system))))

(quickload :antsim/app)

;;; --- version ----------------------------------------------------------
;;;
;;; antsim.asd's :version is the single source of truth.  CI checks the
;;; release tag against it and refuses a mismatch, so by the time we get
;;; here the two already agree; ANTSIM_VERSION exists for nightly and
;;; dispatch builds, which want to say so in the string rather than claim
;;; to be the release.

(setf (symbol-value (find-symbol (string '#:*version*) '#:antsim))
      (or (uiop:getenv "ANTSIM_VERSION")
          (asdf:component-version (asdf:find-system "antsim"))))

;;; --- unhook the build machine -----------------------------------------
;;;
;;; SBCL records every shared object it has opened and reopens each one
;;; *by the path it was opened with* — inside REINIT, before the toplevel
;;; runs and before any hook of ours could have an opinion.  Measured on a
;;; build machine, the image had recorded:
;;;
;;;   libglfw.so.3
;;;   /gnu/store/…-mesa-26.0.2/lib/libGL.so.1
;;;   /gnu/store/…-profile/lib/libEGL.so.1
;;;
;;; The absolute two are obviously wrong to ship: a user has no
;;; /gnu/store, an Ubuntu path is wrong on Fedora, and even here the build
;;; profile is garbage-collected eventually.  The soname is subtler and
;;; was the one that actually bit.  It resolves through the loader, which
;;; sounds fine and is fine — right up until a machine has no GLFW, and
;;; then `antsim --version` dies in REINIT with an SBCL backtrace about a
;;; shared object, having never reached a line of antsim.  Printing a
;;; version number is not a thing that should require a window toolkit.
;;;
;;; So: close all of them, and let ANTSIM::IMAGE-RESTART-INIT open them
;;; again by *name*, on the machine that is actually running.  By name is
;;; also the only form that re-resolves through the loader, which is what
;;; lets the AppImage's bundled copy win via LD_LIBRARY_PATH.  A failure
;;; there is recorded rather than fatal, so the subcommands that need no
;;; graphics keep working and the one that does says why it cannot.
;;;
;;; Anonymous libraries — the driver preload, which loads by absolute path
;;; on purpose — have no name worth keeping.  IMAGE-RESTART-INIT re-runs
;;; that whole search instead.

(let ((reopen '()))
  (dolist (lib (cffi:list-foreign-libraries :loaded-only t))
    (let ((path (cffi:foreign-library-pathname lib))
          (name (cffi:foreign-library-name lib)))
      (format t "~&;; build-binary: unhooking ~a (~a)~%" name path)
      (when (symbol-package name)       ; a named library, not a gensym
        (push name reopen))
      (ignore-errors (cffi:close-foreign-library lib))))
  (setf (symbol-value (find-symbol (string '#:*reopen-libraries*) '#:antsim))
        (nreverse reopen)))

(setf (symbol-value (find-symbol (string '#:*preloaded*) '#:antsim-gl)) nil)

;;; Nothing should be left.  Say so out loud rather than trust it: this is
;;; the check that would catch a new dependency arriving with a foreign
;;; library we did not think to unhook, and it costs one line.
#+sbcl
(when sb-sys:*shared-objects*
  (format t "~&;; build-binary: *** still open, the binary may not run ~
                elsewhere: ***~%~{;;   ~a~%~}"
          (mapcar #'sb-alien::shared-object-namestring sb-sys:*shared-objects*)))

;;; --- save -------------------------------------------------------------

(defun output-path ()
  (let ((given (or (second sb-ext:*posix-argv*) (uiop:getenv "ANTSIM_BINARY"))))
    (uiop:ensure-absolute-pathname
     (or given #+windows "out/antsim.exe" #-windows "out/antsim")
     (uiop:getcwd))))

(defun compression ()
  "NIL, or the compression argument SAVE-LISP-AND-DIE should get."
  (and (equal "1" (uiop:getenv "ANTSIM_COMPRESS"))
       (member :sb-core-compression *features*)
       t))

(let ((out (output-path)))
  (ensure-directories-exist out)
  (format t "~&;; build-binary: saving ~a (antsim ~a)~%"
          out (symbol-value (find-symbol (string '#:*version*) '#:antsim)))
  (push (find-symbol (string '#:image-restart-init) '#:antsim) sb-ext:*init-hooks*)
  (sb-ext:disable-debugger)
  (sb-ext:save-lisp-and-die
   out
   :executable t
   ;; The user's argv is the program's argv, whole.  Without this the
   ;; runtime would eat --dynamic-space-size and friends out of the middle
   ;; of it, which is a fine thing for `sbcl` to do and an absurd one for
   ;; a program whose arguments are scenario names.  The cost is that the
   ;; heap size is fixed here, at whatever the build was given.
   :save-runtime-options t
   ;; Nothing in the image should be lazily compiled on a user's machine.
   :toplevel (lambda ()
               (sb-ext:exit :code (funcall (find-symbol (string '#:main)
                                                        '#:antsim))
                            :abort nil))
   #+sb-core-compression :compression #+sb-core-compression (compression)))
