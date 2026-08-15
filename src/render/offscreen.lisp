;;;; render/offscreen.lisp — the render target, and shader plumbing.
;;;;
;;;; Everything the project draws goes into a framebuffer object, whether
;;;; the run is headless or has a window (README §5.1).  Keeping the
;;;; target separate from any particular scene means the M2 renderer, the
;;;; test suite and the gallery all photograph the same way.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Shaders
;;; --------------------------------------------------------------------

(defun compile-shader (type source)
  "Compile SOURCE, or signal an error carrying the driver's log *and* the
source.  A GLSL error without the source next to it is close to useless
when the shader was assembled from parts."
  (let ((s (gl:create-shader type)))
    (gl:shader-source s source)
    (gl:compile-shader s)
    (unless (gl:get-shader s :compile-status)
      (error "~a failed to compile:~%~a~%--- source ---~%~a"
             type (gl:get-shader-info-log s) source))
    s))

(defun link-program (vertex-source fragment-source)
  (let ((vs (compile-shader :vertex-shader vertex-source))
        (fs (compile-shader :fragment-shader fragment-source))
        (p (gl:create-program)))
    (gl:attach-shader p vs)
    (gl:attach-shader p fs)
    (gl:link-program p)
    (unless (gl:get-program p :link-status)
      (error "Program failed to link:~%~a" (gl:get-program-info-log p)))
    ;; Deleting after linking is correct: the program holds a reference,
    ;; and the shader objects are freed once it drops.
    (gl:delete-shader vs)
    (gl:delete-shader fs)
    p))

;;; --------------------------------------------------------------------
;;; The target
;;; --------------------------------------------------------------------

(defstruct (offscreen (:constructor %make-offscreen))
  (fbo 0 :type unsigned-byte)
  (color-tex 0 :type unsigned-byte)
  (depth-rb 0 :type unsigned-byte)
  (empty-vao 0 :type unsigned-byte)
  (width 0 :type fixnum)
  (height 0 :type fixnum))

(defun make-offscreen (width height)
  "An RGBA8 colour texture plus a 24-bit depth renderbuffer, checked
complete.  Requires a current GL context."
  (declare (type fixnum width height))
  (let ((tex (gl:gen-texture))
        (rb (gl:gen-renderbuffer))
        (fbo (gl:gen-framebuffer)))
    (gl:bind-texture :texture-2d tex)
    (gl:tex-image-2d :texture-2d 0 :rgba8 width height 0 :rgba :unsigned-byte
                     (cffi:null-pointer))
    (gl:tex-parameter :texture-2d :texture-min-filter :linear)
    (gl:tex-parameter :texture-2d :texture-mag-filter :linear)
    (gl:bind-renderbuffer :renderbuffer rb)
    (gl:renderbuffer-storage :renderbuffer :depth-component24 width height)
    (gl:bind-framebuffer :framebuffer fbo)
    (gl:framebuffer-texture-2d :framebuffer :color-attachment0 :texture-2d tex 0)
    (gl:framebuffer-renderbuffer :framebuffer :depth-attachment :renderbuffer rb)
    (let ((status (gl:check-framebuffer-status :framebuffer)))
      ;; A status of 0 rather than an incomplete-* keyword is the libGL
      ;; trap again: no current context, so the call answered nothing.
      (unless (member status '(:framebuffer-complete :framebuffer-complete-oes))
        (error "Framebuffer incomplete: ~a~@[~%~a~]" status
               (when (eql status 0)
                 "A status of 0 means no current context — see src/render/preload.lisp."))))
    (%make-offscreen :fbo fbo :color-tex tex :depth-rb rb
                     ;; Core profile requires a bound VAO even for a draw
                     ;; that reads no vertex attributes at all.
                     :empty-vao (gl:gen-vertex-array)
                     :width width :height height)))

(defun destroy-offscreen (o)
  (declare (type offscreen o))
  (gl:delete-framebuffers (list (offscreen-fbo o)))
  (gl:delete-renderbuffers (list (offscreen-depth-rb o)))
  (gl:delete-textures (list (offscreen-color-tex o)))
  (gl:delete-vertex-arrays (list (offscreen-empty-vao o)))
  (values))

(defmacro with-offscreen ((var width height) &body body)
  `(let ((,var (make-offscreen ,width ,height)))
     (unwind-protect (progn ,@body)
       (destroy-offscreen ,var))))

(defun bind-offscreen (o)
  "Bind O and set the viewport to match it."
  (declare (type offscreen o))
  (gl:bind-framebuffer :framebuffer (offscreen-fbo o))
  (gl:viewport 0 0 (offscreen-width o) (offscreen-height o))
  (values))

(defun read-offscreen (o &key (channels 3))
  "Read O back as a fresh (unsigned-byte 8) vector, bottom-up as GL
delivers it.  WRITE-PNG's :flip turns that the right way up."
  (declare (type offscreen o))
  (let* ((w (offscreen-width o)) (h (offscreen-height o))
         (n (* w h channels))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (gl:bind-framebuffer :framebuffer (offscreen-fbo o))
    ;; *Pack* alignment governs reads.  The default of 4 silently pads
    ;; every row to a multiple of four bytes, which is invisible at
    ;; typical widths and corrupts the image at, say, 7 px wide.
    (gl:pixel-store :pack-alignment 1)
    (cffi:with-foreign-object (buf :unsigned-char n)
      (%gl:read-pixels 0 0 w h (ecase channels (3 :rgb) (4 :rgba))
                       :unsigned-byte buf)
      (dotimes (i n) (setf (aref out i) (cffi:mem-aref buf :unsigned-char i))))
    out))

(defun capture-offscreen (o path &key (channels 3))
  "Read O back and write it to PATH as a PNG.  Returns PATH."
  (declare (type offscreen o))
  (write-png path (read-offscreen o :channels channels)
             (offscreen-width o) (offscreen-height o)
             :channels channels :flip t))
