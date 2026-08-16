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

;;; Multisampling is on by default, and it is the vector ant of §5.2 that
;;; makes it necessary rather than a preference.  An ant's leg is drawn a
;;; pixel and a quarter wide; unsampled, a pixel-wide diagonal is a
;;; staircase, and six staircases per ant crawling over a still frame is
;;; not a gait, it is a shimmer.  The disc shader antialiased itself
;;; analytically and never needed this; a triangle mesh cannot.
;;;
;;; It fixes the obstacle edges at the same time, which had the same
;;; jagged diagonal for the same reason and had simply been lived with.
(defparameter *msaa-samples* 4
  "Samples per pixel on the offscreen target, or 0 for none.  Every
render — the tests, the gallery, the window — goes through the same
target, so this is one switch for the whole project.")

(defstruct (offscreen (:constructor %make-offscreen))
  ;; FBO is what you draw into and RESOLVE-FBO is what you read from.
  ;; With no multisampling they are the same object and nothing has to
  ;; know the difference — which is the point of routing every read
  ;; through READ-OFFSCREEN.
  (fbo 0 :type unsigned-byte)
  (resolve-fbo 0 :type unsigned-byte)
  (color-tex 0 :type unsigned-byte)
  (depth-rb 0 :type unsigned-byte)
  (color-rb 0 :type unsigned-byte)      ; multisample colour, 0 if none
  (samples 0 :type fixnum)
  (empty-vao 0 :type unsigned-byte)
  (width 0 :type fixnum)
  (height 0 :type fixnum))

(defun %check-framebuffer (what)
  (let ((status (gl:check-framebuffer-status :framebuffer)))
    ;; A status of 0 rather than an incomplete-* keyword is the libGL
    ;; trap again: no current context, so the call answered nothing.
    (unless (member status '(:framebuffer-complete :framebuffer-complete-oes))
      (error "~a framebuffer incomplete: ~a~@[~%~a~]" what status
             (when (eql status 0)
               "A status of 0 means no current context — see src/render/preload.lisp.")))))

(defun make-offscreen (width height &key (samples *msaa-samples*))
  "An RGBA8 colour texture plus a 24-bit depth renderbuffer, checked
complete.  With SAMPLES > 0 the drawing target is a separate multisample
pair and the texture becomes the resolve target.  Requires a current GL
context."
  (declare (type fixnum width height))
  (let ((tex (gl:gen-texture))
        (resolve (gl:gen-framebuffer)))
    (gl:bind-texture :texture-2d tex)
    (gl:tex-image-2d :texture-2d 0 :rgba8 width height 0 :rgba :unsigned-byte
                     (cffi:null-pointer))
    (gl:tex-parameter :texture-2d :texture-min-filter :linear)
    (gl:tex-parameter :texture-2d :texture-mag-filter :linear)
    (gl:bind-framebuffer :framebuffer resolve)
    (gl:framebuffer-texture-2d :framebuffer :color-attachment0 :texture-2d tex 0)
    (if (plusp samples)
        (let ((crb (gl:gen-renderbuffer))
              (drb (gl:gen-renderbuffer))
              (fbo (gl:gen-framebuffer)))
          (%check-framebuffer "Resolve")
          (gl:bind-renderbuffer :renderbuffer crb)
          (%gl:renderbuffer-storage-multisample :renderbuffer samples :rgba8
                                                width height)
          (gl:bind-renderbuffer :renderbuffer drb)
          (%gl:renderbuffer-storage-multisample :renderbuffer samples
                                                :depth-component24 width height)
          (gl:bind-framebuffer :framebuffer fbo)
          (gl:framebuffer-renderbuffer :framebuffer :color-attachment0
                                       :renderbuffer crb)
          (gl:framebuffer-renderbuffer :framebuffer :depth-attachment
                                       :renderbuffer drb)
          (%check-framebuffer "Multisample")
          (%make-offscreen :fbo fbo :resolve-fbo resolve :color-tex tex
                           :color-rb crb :depth-rb drb :samples samples
                           :empty-vao (gl:gen-vertex-array)
                           :width width :height height))
        (let ((rb (gl:gen-renderbuffer)))
          (gl:bind-renderbuffer :renderbuffer rb)
          (gl:renderbuffer-storage :renderbuffer :depth-component24 width height)
          (gl:bind-framebuffer :framebuffer resolve)
          (gl:framebuffer-renderbuffer :framebuffer :depth-attachment
                                       :renderbuffer rb)
          (%check-framebuffer "Offscreen")
          (%make-offscreen :fbo resolve :resolve-fbo resolve :color-tex tex
                           :depth-rb rb :samples 0
                           ;; Core profile requires a bound VAO even for a
                           ;; draw that reads no vertex attributes at all.
                           :empty-vao (gl:gen-vertex-array)
                           :width width :height height)))))

(defun destroy-offscreen (o)
  (declare (type offscreen o))
  (gl:delete-framebuffers (remove-duplicates
                           (list (offscreen-fbo o) (offscreen-resolve-fbo o))))
  (gl:delete-renderbuffers (remove 0 (list (offscreen-depth-rb o)
                                           (offscreen-color-rb o))))
  (gl:delete-textures (list (offscreen-color-tex o)))
  (gl:delete-vertex-arrays (list (offscreen-empty-vao o)))
  (values))

(defmacro with-offscreen ((var width height &rest options) &body body)
  `(let ((,var (make-offscreen ,width ,height ,@options)))
     (unwind-protect (progn ,@body)
       (destroy-offscreen ,var))))

(defun bind-offscreen (o)
  "Bind O for drawing and set the viewport to match it."
  (declare (type offscreen o))
  (gl:bind-framebuffer :framebuffer (offscreen-fbo o))
  (gl:viewport 0 0 (offscreen-width o) (offscreen-height o))
  (values))

(defun resolve-offscreen (o)
  "Fold the multisample target down into the readable one.  A no-op when
there is no multisampling, so every reader can call it unconditionally."
  (declare (type offscreen o))
  (when (plusp (offscreen-samples o))
    (let ((w (offscreen-width o)) (h (offscreen-height o)))
      (gl:bind-framebuffer :read-framebuffer (offscreen-fbo o))
      (gl:bind-framebuffer :draw-framebuffer (offscreen-resolve-fbo o))
      ;; NEAREST, not LINEAR: a multisample resolve blit must be
      ;; nearest-filtered when the two rectangles are the same size, and
      ;; GL treats anything else as an error rather than a hint.
      (%gl:blit-framebuffer 0 0 w h 0 0 w h '(:color-buffer-bit) :nearest)))
  (values))

(defun read-offscreen (o &key (channels 3))
  "Read O back as a fresh (unsigned-byte 8) vector, bottom-up as GL
delivers it.  WRITE-PNG's :flip turns that the right way up."
  (declare (type offscreen o))
  (let* ((w (offscreen-width o)) (h (offscreen-height o))
         (n (* w h channels))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (resolve-offscreen o)
    (gl:bind-framebuffer :framebuffer (offscreen-resolve-fbo o))
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
