;;;; render/egl.lisp — headless OpenGL 4.5 context via EGL.
;;;;
;;;; Headless is not a fallback here, it is the point (README §5.4).  A
;;;; renderer that can only draw into a visible window cannot be tested,
;;;; cannot produce a gallery in CI, and cannot show me what a run looked
;;;; like.  The live GLFW window arrives in M2 as the *second* way to get
;;;; a picture, not the first.
;;;;
;;;; Measured on this machine: a 4.5 core context comes up with no window
;;;; server involvement beyond EGL itself — GL 4.5.0 NVIDIA 580.159.04,
;;;; GLSL 4.50, RTX 3070.

(in-package #:antsim)

(defstruct (gl-context (:constructor %make-gl-context))
  #+darwin (window (cffi:null-pointer) :type cffi:foreign-pointer)
  #-darwin (display (cffi:null-pointer) :type cffi:foreign-pointer)
  #-darwin (surface (cffi:null-pointer) :type cffi:foreign-pointer)
  #-darwin (context (cffi:null-pointer) :type cffi:foreign-pointer)
  (width 0 :type fixnum)
  (height 0 :type fixnum))

#+darwin
(progn
  (defvar *egl-loaded* t)
  (defun load-gl-libraries () (values))

  (defun make-headless-context (&key (width 1280) (height 800))
    "Create and make current a headless GL 4.1 core context on macOS via GLFW."
    (unless (glfw:init)
      (error "glfwInit failed on macOS"))
    (glfw:window-hint :visible nil)
    (glfw:window-hint :context-version-major 4)
    (glfw:window-hint :context-version-minor 1)
    (glfw:window-hint :opengl-profile :opengl-core-profile)
    (glfw:window-hint :opengl-forward-compat t)
    (let ((win (glfw:create-window 16 16 "antsim-headless" (cffi:null-pointer) (cffi:null-pointer))))
      (when (cffi:null-pointer-p win)
        (error "glfwCreateWindow (headless) failed on macOS"))
      (glfw:make-context-current win)
      (%make-gl-context :window win :width width :height height)))

  (defun destroy-gl-context (c)
    (declare (type gl-context c))
    (unless (cffi:null-pointer-p (gl-context-window c))
      (glfw:destroy-window (gl-context-window c))
      (setf (gl-context-window c) (cffi:null-pointer)))
    (values)))

#-darwin
(progn
  (defparameter *gl-library-paths*
    '("/usr/lib/" "/usr/lib64/" "/usr/lib/x86_64-linux-gnu/"
      "/run/current-system/profile/lib/")
    "Fallback locations for libEGL/libGL.  $GUIX_ENVIRONMENT/lib is searched
  before any of these — see GL-LIBRARY-SEARCH-PATH.")

  (defun gl-library-search-path ()
    "Directories to search for the driver libraries, most specific first.

  On Guix the driver must come from a `guix shell` profile: run the program
  as `guix shell nvda@580 -- sbcl ...` and this picks up the resulting
  $GUIX_ENVIRONMENT/lib.  Nothing puts the driver on the loader path
  otherwise, and hardcoding the system profile would tie us to one host."
    (let ((env (uiop:getenv "GUIX_ENVIRONMENT")))
      (append (when env (list (concatenate 'string env "/lib/")))
              *gl-library-paths*)))

  (defun %find-lib (names)
    (loop for dir in (gl-library-search-path)
          do (loop for n in names
                   for p = (ignore-errors (probe-file (merge-pathnames n dir)))
                   when p do (return-from %find-lib (namestring p))))
    nil)

  (defvar *egl-loaded* nil)

  (defun load-gl-libraries ()
    "Ensure libEGL/libGL are in the process.  Normally a no-op: preload.lisp
  has already done it at load time.  This is the belt to that braces, and
  the place that produces a *useful* error when the driver is missing."
    (unless *egl-loaded*
      (let ((egl (%find-lib '("libEGL.so.1" "libEGL.so")))
            (gl (%find-lib '("libGL.so.1" "libGL.so"))))
        (unless (and egl gl)
          (error "Could not find libEGL/libGL in ~a.~@
                  On Guix, run under: guix shell nvda@580 -- sbcl ...~@
                  (verify the environment with `nvidia-smi` first)"
                 (gl-library-search-path)))
        (cffi:load-foreign-library egl)
        (cffi:load-foreign-library gl)
        ;; cl-opengl resolves its own entry points against the process image
        (pushnew (pathname (directory-namestring egl))
                 cffi:*foreign-library-directories* :test #'equal)
        (setf *egl-loaded* t))))

  ;;; --- EGL constants we need ------------------------------------------
  (defconstant +egl-none+ #x3038)
  (defconstant +egl-opengl-api+ #x30A2)
  (defconstant +egl-pbuffer-bit+ #x0001)
  (defconstant +egl-opengl-bit+ #x0008)
  (defconstant +egl-surface-type+ #x3033)
  (defconstant +egl-renderable-type+ #x3040)
  (defconstant +egl-red-size+ #x3024)
  (defconstant +egl-green-size+ #x3023)
  (defconstant +egl-blue-size+ #x3022)
  (defconstant +egl-alpha-size+ #x3021)
  (defconstant +egl-depth-size+ #x3025)
  (defconstant +egl-width+ #x3057)
  (defconstant +egl-height+ #x3056)
  (defconstant +egl-context-major-version+ #x3098)
  (defconstant +egl-context-minor-version+ #x30FB)
  (defconstant +egl-context-opengl-profile-mask+ #x30FD)
  (defconstant +egl-context-opengl-core-profile-bit+ #x00000001)

  (cffi:defcfun ("eglGetDisplay" %egl-get-display) :pointer (id :pointer))
  (cffi:defcfun ("eglInitialize" %egl-initialize) :int
    (dpy :pointer) (major :pointer) (minor :pointer))
  (cffi:defcfun ("eglChooseConfig" %egl-choose-config) :int
    (dpy :pointer) (attrib :pointer) (configs :pointer) (size :int) (n :pointer))
  (cffi:defcfun ("eglBindAPI" %egl-bind-api) :int (api :uint))
  (cffi:defcfun ("eglCreateContext" %egl-create-context) :pointer
    (dpy :pointer) (config :pointer) (share :pointer) (attrib :pointer))
  (cffi:defcfun ("eglMakeCurrent" %egl-make-current) :int
    (dpy :pointer) (draw :pointer) (read :pointer) (ctx :pointer))
  (cffi:defcfun ("eglCreatePbufferSurface" %egl-create-pbuffer-surface) :pointer
    (dpy :pointer) (config :pointer) (attrib :pointer))
  (cffi:defcfun ("eglDestroyContext" %egl-destroy-context) :int
    (dpy :pointer) (ctx :pointer))
  (cffi:defcfun ("eglDestroySurface" %egl-destroy-surface) :int
    (dpy :pointer) (surf :pointer))
  (cffi:defcfun ("eglTerminate" %egl-terminate) :int (dpy :pointer))
  (cffi:defcfun ("eglGetError" %egl-get-error) :int)

  (defmacro %with-int-array ((var &rest values) &body body)
    `(cffi:with-foreign-object (,var :int ,(length values))
       ,@(loop for v in values for i from 0
               collect `(setf (cffi:mem-aref ,var :int ,i) ,v))
       ,@body))

  (defun make-headless-context (&key (width 1280) (height 800))
    "Create and make current a headless GL 4.1 core context.

  WIDTH and HEIGHT describe the *intended* render size and are carried on
  the struct for convenience; they do not size the pbuffer.  The pbuffer is
  16×16 and exists only to satisfy drivers that dislike a surfaceless
  make-current — all real drawing goes to framebuffer objects."
    (load-gl-libraries)
    (let ((dpy (%egl-get-display (cffi:make-pointer 0))))
      (when (cffi:null-pointer-p dpy)
        (error "eglGetDisplay failed"))
      (cffi:with-foreign-objects ((major :int) (minor :int))
        (when (zerop (%egl-initialize dpy major minor))
          (error "eglInitialize failed: 0x~x" (%egl-get-error)))
        (unless (= 1 (%egl-bind-api +egl-opengl-api+))
          (error "eglBindAPI(OPENGL) failed: 0x~x" (%egl-get-error)))
        (%with-int-array (attrs
                          +egl-surface-type+ +egl-pbuffer-bit+
                          +egl-renderable-type+ +egl-opengl-bit+
                          +egl-red-size+ 8 +egl-green-size+ 8 +egl-blue-size+ 8
                          +egl-alpha-size+ 8 +egl-depth-size+ 24
                          +egl-none+)
          (cffi:with-foreign-objects ((cfg :pointer) (n :int))
            (when (or (zerop (%egl-choose-config dpy attrs cfg 1 n))
                      (zerop (cffi:mem-ref n :int)))
              (error "eglChooseConfig found no usable config"))
            (let ((config (cffi:mem-ref cfg :pointer)))
              (%with-int-array (ctxattrs
                                +egl-context-major-version+ 4
                                +egl-context-minor-version+ 1
                                +egl-context-opengl-profile-mask+
                                +egl-context-opengl-core-profile-bit+
                                +egl-none+)
                (let ((ctx (%egl-create-context dpy config (cffi:make-pointer 0)
                                                ctxattrs)))
                  (when (cffi:null-pointer-p ctx)
                    (error "eglCreateContext(4.1 core) failed: 0x~x"
                           (%egl-get-error)))
                  (%with-int-array (pbattrs +egl-width+ 16 +egl-height+ 16
                                            +egl-none+)
                    (let ((surf (%egl-create-pbuffer-surface dpy config pbattrs)))
                      (when (cffi:null-pointer-p surf)
                        (error "eglCreatePbufferSurface failed: 0x~x"
                               (%egl-get-error)))
                      (when (zerop (%egl-make-current dpy surf surf ctx))
                        (error "eglMakeCurrent failed: 0x~x" (%egl-get-error)))
                      (%make-gl-context :display dpy :surface surf :context ctx
                                        :width width :height height)))))))))))

  (defun destroy-gl-context (c)
    (declare (type gl-context c))
    (%egl-make-current (gl-context-display c) (cffi:null-pointer)
                       (cffi:null-pointer) (cffi:null-pointer))
    (%egl-destroy-surface (gl-context-display c) (gl-context-surface c))
    (%egl-destroy-context (gl-context-display c) (gl-context-context c))
    (%egl-terminate (gl-context-display c))
    (values)))

(defmacro with-gl-traps-masked (&body body)
  "Run BODY with floating-point traps masked.

SBCL unmasks :invalid, :divide-by-zero and :overflow, which is the right
default for numeric code — the simulation *wants* to hear about a NaN.
Foreign renderers do not share that opinion.  Mesa's llvmpipe raises
invalid and divide-by-zero routinely inside its JIT-compiled rasteriser,
and with SBCL's mask in force the process dies on SIGFPE mid-draw.

This was invisible on the NVIDIA path, which never trips them: the
software backend is what exposed it.  Masking is scoped to GL work only,
so the simulation keeps its traps."
  `(sb-int:with-float-traps-masked (:invalid :divide-by-zero :overflow
                                    :underflow :inexact)
     ,@body))

(defmacro with-headless-gl ((var &key (width 1280) (height 800)) &body body)
  "Run BODY with a current headless GL context bound to VAR.
VAR is declared ignorable, so callers that only want the context as a
side effect need not declare anything (BODY sits inside a PROGN, where a
caller's own DECLARE would be invalid).

Float traps are masked for the whole extent — see WITH-GL-TRAPS-MASKED."
  `(with-gl-traps-masked
     (let ((,var (make-headless-context :width ,width :height ,height)))
       (declare (ignorable ,var))
       (unwind-protect (progn ,@body)
         (destroy-gl-context ,var)))))

(defun gl-info ()
  "Version, renderer, vendor and GLSL version of the current context.

A NIL anywhere in here is the libGL trap (see preload.lisp), not a driver
without a name: it means GL resolved against a library that has no
current context."
  (list :version (gl:get-string :version)
        :renderer (gl:get-string :renderer)
        :vendor (gl:get-string :vendor)
        :glsl (gl:get-string :shading-language-version)))
