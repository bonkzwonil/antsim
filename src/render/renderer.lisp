;;;; render/renderer.lisp — the 2D scene renderer (§5.1).
;;;;
;;;; Surface-agnostic on purpose: this draws into whatever framebuffer is
;;;; bound.  The headless path binds an FBO, the live window binds 0, and
;;;; neither knows about the other.  That is what keeps the tested path
;;;; and the watched path the same path (§5.5).

(in-package #:antsim)

(defconstant +map-persistent-bit+ #x0040)
(defconstant +map-coherent-bit+ #x0080)
(defconstant +map-write-bit+ #x0002)

(defstruct (renderer (:constructor %make-renderer))
  (field-program 0 :type unsigned-byte)
  (poly-program 0 :type unsigned-byte)
  (body-program 0 :type unsigned-byte)
  (empty-vao 0 :type unsigned-byte)
  (field-tex 0 :type unsigned-byte)
  (field-w 0 :type fixnum)
  (field-h 0 :type fixnum)
  (field-scratch nil :type (or null f32v))
  ;; Persistent-mapped SSBO: the CPU writes body instances straight into
  ;; a pointer with no GL call per frame.  Proven at 3000 instances in
  ;; waldameisen, and the reason the ant count is not a rendering
  ;; constraint.
  (body-ssbo 0 :type unsigned-byte)
  (body-map (cffi:null-pointer) :type cffi:foreign-pointer)
  (body-capacity 0 :type fixnum)
  (poly-vao 0 :type unsigned-byte)
  (poly-vbo 0 :type unsigned-byte)
  (poly-capacity 0 :type fixnum))

(defun make-renderer (&key (body-capacity 8192) (poly-capacity 4096)
                           field-width field-height)
  "Build the programs and buffers.  Requires a current GL context.
FIELD-WIDTH/HEIGHT size the pheromone texture and must match the world's
field grid."
  (let ((r (%make-renderer
            :field-program (link-program *field-vertex-glsl*
                                         *field-fragment-glsl*)
            :poly-program (link-program *poly-vertex-glsl*
                                        *poly-fragment-glsl*)
            :body-program (link-program *body-vertex-glsl*
                                        *body-fragment-glsl*)
            :empty-vao (gl:gen-vertex-array)
            :field-w field-width :field-h field-height
            :field-scratch (mkf32 (* field-width field-height))
            :body-capacity body-capacity
            :poly-capacity poly-capacity)))
    ;; pheromone texture
    (let ((tex (gl:gen-texture)))
      (gl:bind-texture :texture-2d tex)
      (gl:tex-image-2d :texture-2d 0 :r32f field-width field-height 0
                       :red :float (cffi:null-pointer))
      ;; LINEAR so a zoomed-in trail is a gradient rather than a mosaic;
      ;; the *sampling* the ants do is still nearest (see FIELD-AT), and
      ;; those are deliberately different questions
      (gl:tex-parameter :texture-2d :texture-min-filter :linear)
      (gl:tex-parameter :texture-2d :texture-mag-filter :linear)
      (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
      (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
      (setf (renderer-field-tex r) tex))
    ;; body instance buffer
    (let ((buf (gl:gen-buffer))
          (bytes (* body-capacity 4 4)))     ; vec4 per body
      (gl:bind-buffer :shader-storage-buffer buf)
      (%gl:buffer-storage :shader-storage-buffer bytes (cffi:null-pointer)
                          (logior +map-write-bit+ +map-persistent-bit+
                                  +map-coherent-bit+))
      (let ((ptr (%gl:map-buffer-range :shader-storage-buffer 0 bytes
                                       (logior +map-write-bit+
                                               +map-persistent-bit+
                                               +map-coherent-bit+))))
        (when (cffi:null-pointer-p ptr)
          (error "Failed to persistently map the body buffer"))
        (setf (renderer-body-ssbo r) buf
              (renderer-body-map r) ptr)))
    ;; obstacle geometry
    (let ((vao (gl:gen-vertex-array))
          (vbo (gl:gen-buffer)))
      (gl:bind-vertex-array vao)
      (gl:bind-buffer :array-buffer vbo)
      (%gl:buffer-data :array-buffer (* poly-capacity 2 4)
                       (cffi:null-pointer) :dynamic-draw)
      (gl:enable-vertex-attrib-array 0)
      (gl:vertex-attrib-pointer 0 2 :float nil 0 (cffi:null-pointer))
      (gl:bind-vertex-array 0)
      (setf (renderer-poly-vao r) vao (renderer-poly-vbo r) vbo))
    r))

(defun destroy-renderer (r)
  (declare (type renderer r))
  (gl:delete-program (renderer-field-program r))
  (gl:delete-program (renderer-poly-program r))
  (gl:delete-program (renderer-body-program r))
  (gl:delete-vertex-arrays (list (renderer-empty-vao r) (renderer-poly-vao r)))
  (gl:delete-textures (list (renderer-field-tex r)))
  (gl:delete-buffers (list (renderer-body-ssbo r) (renderer-poly-vbo r)))
  (values))

;;; --------------------------------------------------------------------
;;; Uploads
;;; --------------------------------------------------------------------

(defun upload-field (r field)
  "Push a colony's trail field to the texture."
  (declare (type renderer r) (type field field))
  (let ((c (field-c field)))
    (gl:bind-texture :texture-2d (renderer-field-tex r))
    (gl:pixel-store :unpack-alignment 1)
    (cffi:with-foreign-object (buf :float (length c))
      (dotimes (i (length c))
        (setf (cffi:mem-aref buf :float i) (aref c i)))
      (%gl:tex-sub-image-2d :texture-2d 0 0 0
                            (field-w field) (field-h field)
                            :red :float buf)))
  (values))

(defun upload-bodies (r w)
  "Write every body into the mapped instance buffer.  Returns the count.

An ant's behavioural state is packed into the fractional part of the kind
so the fragment shader can tint by it without a second buffer — laden
returners read warm, which is what makes a working trail legible as
*traffic* rather than as a stripe."
  (declare (type renderer r) (type world w))
  (let* ((b (world-bodies w))
         (a (world-ants w))
         (ptr (renderer-body-map r))
         (n (min (bodies-n b) (renderer-body-capacity r)))
         (xs (bodies-x b)) (ys (bodies-y b)) (rs (bodies-r b))
         (kinds (bodies-kind b))
         (state-of (make-array (bodies-n b) :element-type 'single-float
                                            :initial-element 0.0f0))
         (count 0))
    ;; ant state, indexed by body
    (dotimes (i (ants-n a))
      (when (ant-live-p a i)
        (let ((bi (aref (ants-body a) i))
              (s (aref (ants-state a) i)))
          (when (< bi (length state-of))
            (setf (aref state-of bi)
                  (cond ((= s +ant-returning+) 0.3f0)
                        ((= s +ant-at-food+) 0.2f0)
                        ((= s +ant-outbound+) 0.1f0)
                        (t 0.0f0)))))))
    (dotimes (i n)
      (let ((k (aref kinds i)))
        (unless (= k +body-free+)
          (let ((o (* count 4)))
            (setf (cffi:mem-aref ptr :float (+ o 0)) (aref xs i)
                  (cffi:mem-aref ptr :float (+ o 1)) (aref ys i)
                  (cffi:mem-aref ptr :float (+ o 2)) (aref rs i)
                  (cffi:mem-aref ptr :float (+ o 3))
                  (+ (float k 1.0f0)
                     (if (= k +body-ant+) (aref state-of i) 0.0f0)))
            (incf count)))))
    ;; One extra instance per colony for the arrival-radius ring.  Drawing
    ;; only — it is not in the body table, because it blocks nothing.
    (dolist (c (world-colonies w))
      (when (< count (renderer-body-capacity r))
        (let ((o (* count 4)))
          (setf (cffi:mem-aref ptr :float (+ o 0)) (colony-nest-x c)
                (cffi:mem-aref ptr :float (+ o 1)) (colony-nest-y c)
                (cffi:mem-aref ptr :float (+ o 2)) *nest-arrival-radius*
                (cffi:mem-aref ptr :float (+ o 3)) 4.0f0)
          (incf count))))
    count))

;;; --------------------------------------------------------------------
;;; The frame
;;; --------------------------------------------------------------------

(defun draw-world (r w v &key (colony 0))
  "Draw one frame of W through view V into the currently bound
framebuffer.  Layers back to front, per §5.1."
  (declare (type renderer r) (type world w) (type view v))
  (multiple-value-bind (x0 y0 x1 y1) (view-bounds v)
    (gl:disable :depth-test)
    (gl:enable :blend)
    (gl:blend-func :src-alpha :one-minus-src-alpha)

    ;; --- ground + pheromone ------------------------------------------
    (let ((c (nth colony (world-colonies w))))
      (when c (upload-field r (colony-field c))))
    (let ((p (renderer-field-program r)))
      (gl:use-program p)
      (gl:active-texture :texture0)
      (gl:bind-texture :texture-2d (renderer-field-tex r))
      (gl:uniformi (gl:get-uniform-location p "u_field") 0)
      (gl:uniformf (gl:get-uniform-location p "u_bounds") x0 y0 x1 y1)
      (gl:uniformf (gl:get-uniform-location p "u_world")
                   (world-width w) (world-height w))
      (gl:uniformf (gl:get-uniform-location p "u_k") *choice-k*)
      (gl:uniformf (gl:get-uniform-location p "u_cap") *trail-cap*)
      (gl:uniformi (gl:get-uniform-location p "u_blocked_shade") 1)
      (gl:bind-vertex-array (renderer-empty-vao r))
      (gl:draw-arrays :triangles 0 3))

    ;; --- obstacles ---------------------------------------------------
    (when (world-obstacles w)
      (let ((p (renderer-poly-program r)))
        (gl:use-program p)
        (gl:uniformf (gl:get-uniform-location p "u_bounds") x0 y0 x1 y1)
        (gl:uniformf (gl:get-uniform-location p "u_color") 0.20 0.21 0.24)
        (gl:bind-vertex-array (renderer-poly-vao r))
        (gl:bind-buffer :array-buffer (renderer-poly-vbo r))
        (dolist (poly (world-obstacles w))
          (let* ((verts (polygon-verts poly))
                 (n (polygon-n poly)))
            (cffi:with-foreign-object (buf :float (* n 2))
              (dotimes (i (* n 2))
                (setf (cffi:mem-aref buf :float i) (aref verts i)))
              (%gl:buffer-sub-data :array-buffer 0 (* n 2 4) buf))
            ;; A triangle fan, which is exact for a convex polygon and
            ;; wrong for a concave one.  Obstacles are authored (§3.7) and
            ;; convex in every scenario so far; a concave one needs real
            ;; triangulation, and *collision* is unaffected either way
            ;; because that uses the edge list, not this.
            (gl:draw-arrays :triangle-fan 0 n)))))

    ;; --- bodies ------------------------------------------------------
    (let ((count (upload-bodies r w))
          (p (renderer-body-program r)))
      (when (plusp count)
        (gl:use-program p)
        (gl:uniformf (gl:get-uniform-location p "u_bounds") x0 y0 x1 y1)
        (%gl:bind-buffer-base :shader-storage-buffer 0 (renderer-body-ssbo r))
        (gl:bind-vertex-array (renderer-empty-vao r))
        (%gl:draw-arrays-instanced :triangle-strip 0 4 count)))

    (gl:bind-vertex-array 0)
    (gl:use-program 0)
    (gl:disable :blend))
  (values))

(defun render-world-png (w path &key (width 960) (height 600) view (colony 0))
  "Draw W and write it to PATH.  Creates its own headless context, so
this is the whole of the headless path in one call."
  (declare (type world w))
  (with-headless-gl (c :width width :height height)
    (let* ((v (or view (view-fit w :vw width :vh height)))
           (f (colony-field (nth colony (world-colonies w))))
           (r (make-renderer :field-width (field-w f) :field-height (field-h f)
                             :body-capacity (max 64 (bodies-capacity
                                                     (world-bodies w))))))
      (unwind-protect
           (with-offscreen (o width height)
             (bind-offscreen o)
             (gl:clear-color 0.02 0.022 0.025 1.0)
             (gl:clear :color-buffer-bit :depth-buffer-bit)
             (draw-world r w v :colony colony)
             (gl:finish)
             (capture-offscreen o path))
        (destroy-renderer r)))))
