;;;; render/preload.lisp — load the GPU driver's GL before anything else.
;;;;
;;;; This file exists because of a real, and initially baffling, failure —
;;;; README §5.4 calls it the libGL trap.
;;;;
;;;; cl-opengl's foreign-library definition asks the loader for
;;;; "libGL.so.1", and on a machine that ships both Mesa and NVIDIA the
;;;; loader may hand it Mesa's.  The EGL context, meanwhile, comes up on
;;;; the NVIDIA vendor.  Nothing errors: GL entry points resolve, buffers
;;;; and framebuffer names are handed out — but they are handed out by a
;;;; dispatch layer that has no current context, so `glGetString` returns
;;;; NULL, `glCheckFramebufferStatus` returns 0, and every rendered pixel
;;;; comes back black.  The symptom looks like a broken renderer; the
;;;; cause is two GL implementations in one process.
;;;;
;;;; Loading the driver's libEGL/libGL *first* fixes it: by the time
;;;; cl-opengl asks, the process already has GL resolved against the
;;;; vendor our context belongs to.  This must therefore happen before
;;;; cl-opengl is loaded, which is why antsim/render pulls this in through
;;;; :defsystem-depends-on rather than :depends-on — the latter would not
;;;; be ordered against cl-opengl.
;;;;
;;;; On Guix, run under `guix shell nvda@580 -- ...`; $GUIX_ENVIRONMENT
;;;; then points at a profile whose lib/ holds the matching driver.  The
;;;; Makefile's GPU targets already do this.
;;;;
;;;; The test suite guards the trap directly: a null GL version string is
;;;; an explicit assertion failure in tests/render.lisp, not a mystery.

(defpackage #:antsim-gl
  (:use #:cl)
  (:export #:driver-library-directory #:preload-driver-gl #:*preloaded*))

(in-package #:antsim-gl)

(defparameter *fallback-directories*
  '("/run/current-system/profile/lib/" "/usr/lib/" "/usr/lib64/"
    "/usr/lib/x86_64-linux-gnu/")
  "Searched after $GUIX_ENVIRONMENT/lib.")

(defun driver-library-directory ()
  "Directory holding the libEGL/libGL we intend to use, or NIL.

Both must come from the *same* directory: the failure this file prevents
is precisely a mismatched pair, so finding one here and one elsewhere is
not good enough."
  (let* ((env (uiop:getenv "GUIX_ENVIRONMENT"))
         (dirs (append (when env (list (concatenate 'string env "/lib/")))
                       *fallback-directories*)))
    (loop for d in dirs
          when (and (ignore-errors (probe-file (merge-pathnames "libEGL.so.1" d)))
                    (ignore-errors (probe-file (merge-pathnames "libGL.so.1" d))))
            do (return d))))

(defvar *preloaded* nil
  "The directory the driver libraries were loaded from, once done.")

(defun preload-driver-gl ()
  "Load libEGL/libGL from the driver directory.  Idempotent."
  (or *preloaded*
      (let ((dir (driver-library-directory)))
        (unless dir
          (warn "antsim: no libEGL.so.1 + libGL.so.1 found. ~
                 On Guix run under: guix shell nvda@580 -- ...~@
                 Rendering will probably produce black frames.")
          (return-from preload-driver-gl nil))
        (cffi:load-foreign-library
         (namestring (merge-pathnames "libEGL.so.1" dir)))
        (cffi:load-foreign-library
         (namestring (merge-pathnames "libGL.so.1" dir)))
        (setf *preloaded* dir))))

(preload-driver-gl)
