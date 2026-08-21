;;;; render/renderer.lisp — the 2D scene renderer (§5.1).
;;;;
;;;; Surface-agnostic on purpose: this draws into whatever framebuffer is
;;;; bound.  The headless path binds an FBO, the live window binds 0, and
;;;; neither knows about the other.  That is what keeps the tested path
;;;; and the watched path the same path (§5.5).

(in-package #:antsim)

(defstruct (renderer (:constructor %make-renderer))
  (field-program 0 :type unsigned-byte)
  (poly-program 0 :type unsigned-byte)
  (body-program 0 :type unsigned-byte)
  (empty-vao 0 :type unsigned-byte)
  (field-tex 0 :type unsigned-byte)
  ;; The alarm overlay (§3.3, M5), on the same grid as the trail field.
  ;; Its texture is allocated with everything else, because a GL object is
  ;; cheap and creating one mid-frame on the first poke is the kind of
  ;; lazy initialisation that only ever fails on somebody else's driver.
  ;; The *pass* is what is conditional.
  (alarm-program 0 :type unsigned-byte)
  (alarm-tex 0 :type unsigned-byte)
  (field-w 0 :type fixnum)
  (field-h 0 :type fixnum)
  (field-scratch nil :type (or null f32v))
  ;; Body instances via Texture Buffer Object (TBO, GL 3.1 / 4.1):
  ;; one large array of vec4s indexed by instance ID in the shader.
  (body-buf 0 :type unsigned-byte)
  (body-tex 0 :type unsigned-byte)
  (body-ptr (cffi:null-pointer) :type cffi:foreign-pointer)
  (body-capacity 0 :type fixnum)
  (poly-vao 0 :type unsigned-byte)
  (poly-vbo 0 :type unsigned-byte)
  (poly-capacity 0 :type fixnum)
  ;; The articulated ant of §5.2.  One static mesh, one TBO instance buffer:
  ;; eight floats per ant per frame.
  (ant-program 0 :type unsigned-byte)
  (ant-mesh nil :type (or null ant-mesh))
  (ant-vao 0 :type unsigned-byte)
  (ant-vbo 0 :type unsigned-byte)
  (ant-ebo 0 :type unsigned-byte)
  (ant-buf 0 :type unsigned-byte)
  (ant-tex 0 :type unsigned-byte)
  (ant-ptr (cffi:null-pointer) :type cffi:foreign-pointer))

(defconstant +ant-instance-floats+ 8
  "Two vec4s: (x y heading phase) and (radius state load flick).  §5.2's
per-instance record.")

(defun make-renderer (&key (body-capacity 8192) (poly-capacity 4096)
                           field-width field-height)
  "Build the programs and buffers.  Requires a current GL context.
FIELD-WIDTH/HEIGHT size the pheromone texture and must match the world's
field grid."
  (let ((r (%make-renderer
            :field-program (link-program *field-vertex-glsl*
                                         *field-fragment-glsl*)
            ;; same fullscreen triangle, different colouring
            :alarm-program (link-program *field-vertex-glsl*
                                         *alarm-fragment-glsl*)
            :poly-program (link-program *poly-vertex-glsl*
                                        *poly-fragment-glsl*)
            :body-program (link-program *body-vertex-glsl*
                                        *body-fragment-glsl*)
            :ant-program (link-program *ant-vertex-glsl*
                                       *ant-fragment-glsl*)
            :ant-mesh (build-ant-mesh)
            :empty-vao (gl:gen-vertex-array)
            :field-w field-width :field-h field-height
            :field-scratch (mkf32 (* field-width field-height))
            :body-capacity body-capacity
            :body-ptr (cffi:foreign-alloc :float :count (* body-capacity 4))
            :ant-ptr (cffi:foreign-alloc :float :count (* body-capacity +ant-instance-floats+))
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
    ;; alarm texture — same size, same filtering, same reasons
    (let ((tex (gl:gen-texture)))
      (gl:bind-texture :texture-2d tex)
      (gl:tex-image-2d :texture-2d 0 :r32f field-width field-height 0
                       :red :float (cffi:null-pointer))
      (gl:tex-parameter :texture-2d :texture-min-filter :linear)
      (gl:tex-parameter :texture-2d :texture-mag-filter :linear)
      (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
      (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
      (setf (renderer-alarm-tex r) tex))
    ;; body instance buffer & TBO
    (let ((buf (gl:gen-buffer))
          (tex (gl:gen-texture))
          (bytes (* body-capacity 4 4)))     ; vec4 per body
      (gl:bind-buffer :texture-buffer buf)
      (%gl:buffer-data :texture-buffer bytes (cffi:null-pointer) :dynamic-draw)
      (gl:bind-texture :texture-buffer tex)
      (%gl:tex-buffer :texture-buffer :rgba32f buf)
      (setf (renderer-body-buf r) buf
            (renderer-body-tex r) tex))
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
    ;; the ant mesh — static, uploaded once, never touched again
    (let* ((m (renderer-ant-mesh r))
           (vao (gl:gen-vertex-array))
           (vbo (gl:gen-buffer))
           (ebo (gl:gen-buffer))
           (stride (* +ant-vertex-floats+ 4)))
      (gl:bind-vertex-array vao)
      (gl:bind-buffer :array-buffer vbo)
      (let ((v (ant-mesh-verts m)))
        (cffi:with-foreign-object (buf :float (length v))
          (dotimes (i (length v))
            (setf (cffi:mem-aref buf :float i) (aref v i)))
          (%gl:buffer-data :array-buffer (* (length v) 4) buf :static-draw)))
      (gl:bind-buffer :element-array-buffer ebo)
      (let ((ix (ant-mesh-index m)))
        (cffi:with-foreign-object (buf :unsigned-int (length ix))
          (dotimes (i (length ix))
            (setf (cffi:mem-aref buf :unsigned-int i) (aref ix i)))
          (%gl:buffer-data :element-array-buffer (* (length ix) 4) buf
                           :static-draw)))
      (loop for (loc size offset) in '((0 2 0) (1 2 8) (2 1 16) (3 1 20))
            do (gl:enable-vertex-attrib-array loc)
               (gl:vertex-attrib-pointer loc size :float nil stride
                                         (cffi:make-pointer offset)))
      (gl:bind-vertex-array 0)
      (setf (renderer-ant-vao r) vao
            (renderer-ant-vbo r) vbo
            (renderer-ant-ebo r) ebo))
    ;; ant instance buffer & TBO
    (let ((buf (gl:gen-buffer))
          (tex (gl:gen-texture))
          (bytes (* body-capacity +ant-instance-floats+ 4)))
      (gl:bind-buffer :texture-buffer buf)
      (%gl:buffer-data :texture-buffer bytes (cffi:null-pointer) :dynamic-draw)
      (gl:bind-texture :texture-buffer tex)
      (%gl:tex-buffer :texture-buffer :rgba32f buf)
      (setf (renderer-ant-buf r) buf
            (renderer-ant-tex r) tex))
    r))

(defun destroy-renderer (r)
  (declare (type renderer r))
  (gl:delete-program (renderer-field-program r))
  (gl:delete-program (renderer-alarm-program r))
  (gl:delete-program (renderer-poly-program r))
  (gl:delete-program (renderer-body-program r))
  (gl:delete-program (renderer-ant-program r))
  (gl:delete-vertex-arrays (list (renderer-empty-vao r) (renderer-poly-vao r)
                                 (renderer-ant-vao r)))
  (gl:delete-textures (list (renderer-field-tex r) (renderer-alarm-tex r)
                            (renderer-body-tex r) (renderer-ant-tex r)))
  (gl:delete-buffers (list (renderer-body-buf r) (renderer-poly-vbo r)
                           (renderer-ant-vbo r) (renderer-ant-ebo r)
                           (renderer-ant-buf r)))
  (unless (cffi:null-pointer-p (renderer-body-ptr r))
    (cffi:foreign-free (renderer-body-ptr r))
    (setf (renderer-body-ptr r) (cffi:null-pointer)))
  (unless (cffi:null-pointer-p (renderer-ant-ptr r))
    (cffi:foreign-free (renderer-ant-ptr r))
    (setf (renderer-ant-ptr r) (cffi:null-pointer)))
  (values))

;;; --------------------------------------------------------------------
;;; Uploads
;;; --------------------------------------------------------------------

(defun upload-field (r field &optional (tex (renderer-field-tex r)))
  "Push a field's concentrations to a texture.

TEX so the alarm overlay can reuse this unchanged: the two fields are the
same shape and the upload has never had anything to do with which
chemical it is carrying."
  (declare (type renderer r) (type field field))
  (let ((c (field-c field)))
    (gl:bind-texture :texture-2d tex)
    (gl:pixel-store :unpack-alignment 1)
    (cffi:with-foreign-object (buf :float (length c))
      (dotimes (i (length c))
        (setf (cffi:mem-aref buf :float i) (aref c i)))
      (%gl:tex-sub-image-2d :texture-2d 0 0 0
                            (field-w field) (field-h field)
                            :red :float buf)))
  (values))

(defun tribe-number (w colony-id)
  "What the shaders should colour this ant's head with: 0 for \"do not\",
otherwise the colony's number counting from one.

**A world with one colony sends 0 for every ant**, so the single-colony
picture is byte-for-byte the one M2 shipped and no reference frame in the
gallery moves.  The decision belongs here, in the only place that knows
how many colonies there are; the shader is told an answer, not a
question."
  (declare (type world w) (type fixnum colony-id))
  (if (< (length (world-colonies w)) 2)
      0
      (1+ colony-id)))

(defun ant-display-state (a i c)
  "What this ant is saying, as the single float both ant shaders read
(§5.1, §5.3).  Zero is reserved for a corpse.

Spent outranks every behavioural state, because it overrides them in
fact: an ant below the energy it needs to set out is not going to,
whatever it is nominally doing.  Without this the end of a colony is
invisible — the nest fills up with ants drawn in ordinary resting grey,
and a watcher sees them \"deciding\" to stay home rather than being out of
fuel.  It was mistaken for exactly that."
  (declare (type ants a) (type fixnum i))
  (let ((s (aref (ants-state a) i)))
    (cond ((and c (< (aref (ants-energy a) i) (colony-energy-threshold c)))
           0.4f0)
          ((= s +ant-returning+) 0.3f0)
          ((= s +ant-at-food+) 0.2f0)
          ;; Nothing more urgent to report, so this one carries its age
          ;; instead (§5.1).  0.5 is newly emerged, 0.9 fully mature; the
          ;; behavioural states above keep their own colours because those
          ;; are what the picture is for.
          (t (+ 0.5f0
                (* 0.4f0
                   (min 1.0f0
                        (/ (float (aref (ants-age a) i) 1.0f0)
                           (float (max 1 *age-shade-ticks*) 1.0f0)))))))))

(defun ant-display-flick (a i)
  "How recently this ant put its gaster down: 1 at the moment of a
deposit, gone a few millimetres later (§3.3, §5.2).

Read off the distance since the last packet rather than recorded as an
event, because that distance *is* the record — the deposit rule fires
when it crosses the packet spacing and resets it to zero, so a small
value can only mean a packet has just gone into the ground.  Nothing new
has to be stored, and the drawing cannot disagree with the mechanism
about when a deposit happened."
  (declare (type ants a) (type fixnum i))
  (if (and (= (aref (ants-state a) i) +ant-returning+)
           (> (aref (ants-crop a) i) 0.0f0)
           (>= (aref (ants-load-quality a) i) *trail-quality-threshold*))
      ;; Clamped before the EXP rather than after.  An ant that has just
      ;; filled its crop is carrying a distance accumulated over its whole
      ;; outbound leg, which is metres rather than millimetres, and the
      ;; answer is the same 0 either way — but only one of the two ways
      ;; gets there without depending on how the float traps are set.
      (exp (- (min 60.0f0
                   (/ (aref (ants-trailed a) i)
                      (* 0.18f0 *trail-packet-spacing*)))))
      0.0f0))

(defun upload-bodies (r w &key skip-ants)
  "Write every body into the instance buffer.  Returns the count.

An ant's behavioural state is packed into the fractional part of the kind
so the fragment shader can tint by it without a second buffer — laden
returners read warm, which is what makes a working trail legible as
*traffic* rather than as a stripe.

With SKIP-ANTS, ants and corpses are left out because the vector program
of §5.2 is drawing them instead.  Everything else on the screen — sources,
nests, arrival rings, stock gauges — comes through here at every zoom, so
there stays exactly one place that knows what a food source looks like."
  (declare (type renderer r) (type world w))
  (let* ((b (world-bodies w))
         (a (world-ants w))
         (ptr (renderer-body-ptr r))
         (n (min (bodies-n b) (renderer-body-capacity r)))
         (xs (bodies-x b)) (ys (bodies-y b)) (rs (bodies-r b))
         (kinds (bodies-kind b))
         (state-of (make-array (bodies-n b) :element-type 'single-float
                                            :initial-element 0.0f0))
         (count 0))
    ;; ant state, indexed by body
    (let ((colonies (coerce (world-colonies w) 'vector)))
      (dotimes (i (ants-n a))
        (when (ant-live-p a i)
          (let* ((bi (aref (ants-body a) i))
                 (ci (aref (ants-colony a) i))
                 (c (when (< ci (length colonies)) (aref colonies ci))))
            (when (< bi (length state-of))
              ;; state in the fraction, tribe in the hundreds -- see the
              ;; note in the disc fragment shader.  The kind is added
              ;; below, in the ones.
              (setf (aref state-of bi)
                    (+ (ant-display-state a i c)
                       (* 100.0f0 (float (tribe-number w ci) 1.0f0)))))))))
    (dotimes (i n)
      (let ((k (aref kinds i)))
        (unless (or (= k +body-free+)
                    (and skip-ants
                         (or (= k +body-ant+) (= k +body-resting+)
                             (= k +body-corpse+))))
          (let ((o (* count 4)))
            (setf (cffi:mem-aref ptr :float (+ o 0)) (aref xs i)
                  (cffi:mem-aref ptr :float (+ o 1)) (aref ys i)
                  (cffi:mem-aref ptr :float (+ o 2)) (aref rs i)
                  (cffi:mem-aref ptr :float (+ o 3))
                  ;; A resting ant is drawn as an ant.  The kind exists
                  ;; to keep it out of the collision pass (§3.11), not to
                  ;; give it a look of its own, and mapping it back here
                  ;; means the shader needs no case for it.
                  (+ (if (= k +body-resting+) 0.0f0 (float k 1.0f0))
                     (if (or (= k +body-ant+) (= k +body-resting+))
                         (aref state-of i)
                         0.0f0)))
            (incf count)))))
    ;; Drawing-only instances follow: the arrival ring and the two stock
    ;; gauges.  None of them is in the body table, because none of them
    ;; blocks anything.
    (dolist (c (world-colonies w))
      (when (< count (renderer-body-capacity r))
        (let ((o (* count 4)))
          (setf (cffi:mem-aref ptr :float (+ o 0)) (colony-nest-x c)
                (cffi:mem-aref ptr :float (+ o 1)) (colony-nest-y c)
                (cffi:mem-aref ptr :float (+ o 2)) *nest-arrival-radius*
                (cffi:mem-aref ptr :float (+ o 3)) 4.0f0)
          (incf count)))
      ;; How much food is *in* the nest, as a disc inside the entrance.
      ;; Area proportional to the amount — hence the square root — because
      ;; that is what the eye actually compares between two circles.
      (when (< count (renderer-body-capacity r))
        (let ((o (* count 4))
              (frac (clampf (/ (colony-stock c) (colony-stock-ref c))
                            0.0f0 1.0f0)))
          (setf (cffi:mem-aref ptr :float (+ o 0)) (colony-nest-x c)
                (cffi:mem-aref ptr :float (+ o 1)) (colony-nest-y c)
                (cffi:mem-aref ptr :float (+ o 2))
                (* 0.72f0 (colony-nest-r c) (sqrt frac))
                (cffi:mem-aref ptr :float (+ o 3)) 5.0f0)
          (incf count))))
    ;; Sources need no gauge instance: the body itself shrinks as it is
    ;; eaten (FOOD-CURRENT-RADIUS), so the disc on screen *is* the amount
    ;; left, and it is the same circle the ants are queueing against.
    (when (plusp count)
      (gl:bind-buffer :texture-buffer (renderer-body-buf r))
      (%gl:buffer-sub-data :texture-buffer 0 (* count 4 4) ptr)
      (gl:bind-buffer :texture-buffer 0))
    count))

(defun upload-ants (r w)
  "Write one §5.2 instance record per ant — and per corpse — into the
ant buffer.  Returns the count.

Eight floats each, and that is the entire per-frame cost of the
articulated ant: the gait, the antennal sweep, the swelling crop and the
gaster dip are all derived from these in the vertex shader, so animating
a colony rewrites no geometry and issues no GL call in the loop."
  (declare (type renderer r) (type world w))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (ptr (renderer-ant-ptr r))
         (cap (renderer-body-capacity r))
         (xs (bodies-x b)) (ys (bodies-y b)) (rs (bodies-r b))
         (kinds (bodies-kind b))
         (colonies (coerce (world-colonies w) 'vector))
         (count 0))
    (flet ((emit (x y heading phase radius state load flick)
             (let ((o (* count +ant-instance-floats+)))
               (setf (cffi:mem-aref ptr :float (+ o 0)) x
                     (cffi:mem-aref ptr :float (+ o 1)) y
                     (cffi:mem-aref ptr :float (+ o 2)) heading
                     (cffi:mem-aref ptr :float (+ o 3)) phase
                     (cffi:mem-aref ptr :float (+ o 4)) radius
                     (cffi:mem-aref ptr :float (+ o 5)) state
                     (cffi:mem-aref ptr :float (+ o 6)) load
                     (cffi:mem-aref ptr :float (+ o 7)) flick))
             (incf count)))
      (dotimes (i (ants-n a))
        (when (and (ant-live-p a i) (< count cap))
          (let* ((bi (aref (ants-body a) i))
                 (ci (aref (ants-colony a) i))
                 (c (when (< ci (length colonies)) (aref colonies ci))))
            (emit (aref xs bi) (aref ys bi)
                  (aref (ants-heading a) i)
                  (aref (ants-gait a) i)
                  (aref rs bi)
                  ;; tribe in the integer part (the detailed instance
                  ;; carries no kind, so there is room in the ones)
                  (+ (ant-display-state a i c)
                     (float (tribe-number w ci) 1.0f0))
                  (min 1.0f0 (aref (ants-crop a) i))
                  (ant-display-flick a i)))))
      ;; Corpses.  They are bodies and not ants — the ant slot was freed
      ;; when this one died (§3.11) — so they are picked up here from the
      ;; body table, and they are drawn by the same mesh because a dead
      ;; ant is ant-shaped.  State zero puts them in the corpse branch of
      ;; the shader: legs folded under, antennae down, no gait.
      ;;
      ;; The heading is invented, from the body index, because nothing
      ;; recorded which way this one was facing when it stopped.  A field
      ;; of corpses all pointing north would be the more obvious lie.
      (dotimes (i (min (bodies-n b) cap))
        (when (and (= (aref kinds i) +body-corpse+) (< count cap))
          (emit (aref xs i) (aref ys i)
                (* 6.2831855f0 (rnd01 i 0 77 (world-seed w)))
                0.5f0 (aref rs i) 0.0f0 0.0f0 0.0f0))))
    (when (plusp count)
      (gl:bind-buffer :texture-buffer (renderer-ant-buf r))
      (%gl:buffer-sub-data :texture-buffer 0 (* count +ant-instance-floats+ 4) ptr)
      (gl:bind-buffer :texture-buffer 0))
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

    ;; --- alarm (§3.3, M5) --------------------------------------------
    ;;
    ;; Skipped entirely for a colony that has never been disturbed, which
    ;; is every colony in every scenario: the field is made on the first
    ;; release and nothing in the model releases any (§5.5).  So this is a
    ;; NIL test per frame in the ordinary case, and the whole reason a
    ;; fourth chemical could be added without touching the render tests.
    ;;
    ;; Over the ground and under the ants.  Under, because an eruption
    ;; must not hide the thing erupting — the ants are what is worth
    ;; watching and the plume is why they are doing it.
    (let* ((c (nth colony (world-colonies w)))
           (al (and c (colony-alarm c))))
      (when al
        (upload-field r al (renderer-alarm-tex r))
        (let ((p (renderer-alarm-program r)))
          (gl:use-program p)
          (gl:active-texture :texture0)
          (gl:bind-texture :texture-2d (renderer-alarm-tex r))
          (gl:uniformi (gl:get-uniform-location p "u_alarm") 0)
          (gl:uniformf (gl:get-uniform-location p "u_bounds") x0 y0 x1 y1)
          (gl:uniformf (gl:get-uniform-location p "u_world")
                       (world-width w) (world-height w))
          (gl:uniformf (gl:get-uniform-location p "u_cap") *alarm-cap*)
          (gl:uniformf (gl:get-uniform-location p "u_threshold")
                       *alarm-threshold*)
          (gl:uniformf (gl:get-uniform-location p "u_panic") *alarm-panic*)
          (gl:bind-vertex-array (renderer-empty-vao r))
          (gl:draw-arrays :triangles 0 3))))

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
    ;;
    ;; Level of detail, §5.2, and it is decided once per frame rather than
    ;; per ant because the camera is orthographic: every ant in the world
    ;; is the same number of pixels across.
    ;;
    ;; Three tiers.  Below *ANT-DISC-PIXELS* an ant is the plain disc it
    ;; has always been — at three pixels the legs are noise, and an
    ;; analytic circle antialiases better than ninety triangles ever
    ;; will.  Above it the vector body; above *ANT-DETAIL-PIXELS* the legs
    ;; and antennae as well.  The middle tier is a *range* of the same
    ;; index buffer, not a second mesh, so the two cannot disagree.
    (let* ((px-per-m (/ (float (view-vw v) 1.0f0) (- x1 x0)))
           (r-px (* *ant-radius* px-per-m))
           (vector-ants (>= r-px *ant-disc-pixels*))
           (count (upload-bodies r w :skip-ants vector-ants))
           (p (renderer-body-program r)))
      (when (plusp count)
        (gl:use-program p)
        (gl:uniformf (gl:get-uniform-location p "u_bounds") x0 y0 x1 y1)
        (gl:active-texture :texture0)
        (gl:bind-texture :texture-buffer (renderer-body-tex r))
        (gl:uniformi (gl:get-uniform-location p "u_bodies") 0)
        (gl:bind-vertex-array (renderer-empty-vao r))
        (%gl:draw-arrays-instanced :triangle-strip 0 4 count))

      ;; --- the ants, as ants (§5.2) ----------------------------------
      (when vector-ants
        (let ((n (upload-ants r w))
              (m (renderer-ant-mesh r))
              (q (renderer-ant-program r)))
          (when (plusp n)
            (let* ((full (>= r-px *ant-detail-pixels*))
                   (first-index (if full 0 (ant-mesh-under-count m)))
                   (n-index (if full
                                (ant-mesh-nindex m)
                                (ant-mesh-body-count m))))
              (gl:use-program q)
              (gl:uniformf (gl:get-uniform-location q "u_bounds") x0 y0 x1 y1)
              (gl:uniformf (gl:get-uniform-location q "u_world")
                           (world-width w) (world-height w))
              ;; The same texture the field pass left bound on unit 0 —
              ;; the antennae read the trail the ants are walking on.
              (gl:active-texture :texture0)
              (gl:bind-texture :texture-2d (renderer-field-tex r))
              (gl:uniformi (gl:get-uniform-location q "u_field") 0)
              ;; Ant instance buffer on unit 1
              (gl:active-texture :texture1)
              (gl:bind-texture :texture-buffer (renderer-ant-tex r))
              (gl:uniformi (gl:get-uniform-location q "u_ants") 1)
              (gl:uniformf (gl:get-uniform-location q "u_px_per_m") px-per-m)
              (gl:uniformf (gl:get-uniform-location q "u_seconds")
                           (world-seconds w))
              (gl:uniformf (gl:get-uniform-location q "u_stride")
                           (/ *gait-stride* *ant-radius*))
              (gl:uniformf (gl:get-uniform-location q "u_k") *choice-k*)
              (gl:bind-vertex-array (renderer-ant-vao r))
              (%gl:draw-elements-instanced :triangles n-index :unsigned-int
                                           (cffi:make-pointer
                                            (* first-index 4))
                                           n))))))

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
