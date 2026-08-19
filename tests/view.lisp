;;;; tests/view.lisp — the camera and the 2D scene renderer (§5.1, §5.5).
;;;;
;;;; The camera tests need no GL at all — it is arithmetic — but they live
;;;; in the render suite because VIEW ships with antsim/render.

(in-package #:antsim/render-test)

(in-suite render)

;;; ------------------------------------------------------------ camera

(test view-screen-world-round-trip
  (let ((v (ant:make-view :cx 0.4f0 :cy 0.3f0 :span 0.8f0 :vw 800 :vh 600)))
    (dolist (p '((0.0 0.0) (400.0 300.0) (799.0 599.0) (123.0 456.0)))
      (destructuring-bind (px py) p
        (let ((px (float px 1.0f0)) (py (float py 1.0f0)))
          (multiple-value-bind (wx wy) (ant:view-screen->world v px py)
            (multiple-value-bind (bx by) (ant:view-world->screen v wx wy)
              (is (< (abs (- bx px)) 1e-3) "x ~a -> ~a" px bx)
              (is (< (abs (- by py)) 1e-3) "y ~a -> ~a" py by))))))))

(test view-centre-maps-to-viewport-centre
  (let ((v (ant:make-view :cx 0.4f0 :cy 0.3f0 :span 0.8f0 :vw 800 :vh 600)))
    (multiple-value-bind (sx sy) (ant:view-world->screen v 0.4f0 0.3f0)
      (is (< (abs (- sx 400.0f0)) 1e-3))
      (is (< (abs (- sy 300.0f0)) 1e-3)))))

(test view-y-axis-points-up
  "World y is up and screen y is down.  Getting this backwards flips the
whole scene, which is obvious in a picture and invisible in a number."
  (let ((v (ant:make-view :cx 0.5f0 :cy 0.5f0 :span 1.0f0 :vw 800 :vh 600)))
    (multiple-value-bind (sx1 sy1) (ant:view-world->screen v 0.5f0 0.6f0)
      (declare (ignore sx1))
      (multiple-value-bind (sx2 sy2) (ant:view-world->screen v 0.5f0 0.4f0)
        (declare (ignore sx2))
        (is (< sy1 sy2) "higher world y should be nearer the top")))))

(test view-zoom-is-anchored-at-the-cursor
  "§5.5 calls this out because scaling about the screen centre feels
wrong the instant anyone uses it: the world point under the pointer must
stay under the pointer."
  (let ((v (ant:make-view :cx 0.5f0 :cy 0.5f0 :span 1.0f0 :vw 800 :vh 600)))
    (dolist (p '((100.0 120.0) (650.0 480.0) (400.0 300.0)))
      (destructuring-bind (px py) p
        (let* ((px (float px 1.0f0)) (py (float py 1.0f0)))
          (multiple-value-bind (wx wy) (ant:view-screen->world v px py)
            (ant:view-zoom-at! v px py 1.35f0)
            (multiple-value-bind (ax ay) (ant:view-screen->world v px py)
              (is (< (abs (- ax wx)) 1e-4)
                  "the world point under the cursor moved in x: ~a -> ~a" wx ax)
              (is (< (abs (- ay wy)) 1e-4)
                  "the world point under the cursor moved in y: ~a -> ~a" wy ay))))))))

(test view-zoom-changes-the-span
  (let ((v (ant:make-view :span 1.0f0)))
    (ant:view-zoom-at! v 400.0f0 300.0f0 2.0f0)
    (is (< (abs (- (ant:view-span v) 0.5f0)) 1e-5))
    (ant:view-zoom-at! v 400.0f0 300.0f0 0.5f0)
    (is (< (abs (- (ant:view-span v) 1.0f0)) 1e-5))))

(test view-pan-moves-the-world-with-the-drag
  (let* ((v (ant:make-view :cx 0.5f0 :cy 0.5f0 :span 1.0f0 :vw 800 :vh 600)))
    (multiple-value-bind (wx wy) (ant:view-screen->world v 400.0f0 300.0f0)
      (ant:view-pan-pixels! v 80.0f0 0.0f0)
      (multiple-value-bind (ax ay) (ant:view-screen->world v 480.0f0 300.0f0)
        ;; dragging right by 80 px should bring the same world point under
        ;; a pointer that also moved right by 80 px
        (is (< (abs (- ax wx)) 1e-4))
        (is (< (abs (- ay wy)) 1e-4))))))

(test view-fit-frames-the-whole-world
  (let* ((w (ant:make-world :width 0.8f0 :height 0.4f0 :capacity 8))
         (v (ant:view-fit w :vw 800 :vh 600)))
    (multiple-value-bind (x0 y0 x1 y1) (ant:view-bounds v)
      (is (<= x0 0.0f0)) (is (>= x1 0.8f0))
      (is (<= y0 0.0f0)) (is (>= y1 0.4f0)))))

;;; ------------------------------------------------------ the renderer

(test scene-renders-a-world
  "A world with a nest, food, an obstacle and a colony must produce a
frame with real structure in it — not a flat fill, and not a black frame."
  (with-gl-or-skip
    (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 400))
           (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.08f0
                                :stock 300.0f0)))
      (ant:add-food w 0.20f0 0.26f0 0.025f0 3000.0f0 :quality 1.0f0)
      (ant:add-obstacle w '(0.05 0.14 0.14 0.14 0.14 0.17 0.05 0.17))
      (ant:world-seed-population! w c 60)
      (ant:world-run! w 4000)
      (is (> (ant:field-total (ant:colony-field c)) 0.0d0)
          "no trail was laid, so the frame would not test the field layer")
      ;; RENDER-WORLD-PNG is the whole headless path in one call: it makes
      ;; its own context, renderer and target.  SCENE-FRAME-HAS-STRUCTURE
      ;; below is what checks the pixels.
      (let ((path (test-png-path "scene.png")))
        (ant:render-world-png w path :width 320 :height 320)
        (multiple-value-bind (pw ph depth ctype) (decode-png-header path)
          (is (= pw 320))
          (is (= ph 320))
          (is (= depth 8))
          (is (= ctype 2)))))))

(test scene-frame-has-structure
  "Read the frame back and require it to contain a range of values: a
renderer that silently drew nothing still produces a valid PNG."
  (with-gl-or-skip
    (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0 :capacity 400))
           (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.08f0
                                :stock 300.0f0)))
      (ant:add-food w 0.20f0 0.26f0 0.025f0 3000.0f0 :quality 1.0f0)
      (ant:world-seed-population! w c 60)
      (ant:world-run! w 4000)
      (ant:with-headless-gl (ctx :width 320 :height 320)
        (let ((o (ant:make-offscreen 320 320))
              (r (ant:make-renderer
                  :field-width (ant:field-w (ant:colony-field c))
                  :field-height (ant:field-h (ant:colony-field c))
                  :body-capacity 512)))
          (unwind-protect
               (progn
                 (ant:bind-offscreen o)
                 (gl:clear-color 0.02 0.022 0.025 1.0)
                 (gl:clear :color-buffer-bit)
                 (ant:draw-world r w (ant:view-fit w :vw 320 :vh 320))
                 (gl:finish)
                 (ant:capture-offscreen o (test-png-path "scene-frame.png"))
                 (let* ((px (ant:read-offscreen o))
                        (distinct (make-hash-table :test #'eql))
                        (bright 0))
                   (dotimes (i (floor (length px) 3))
                     (setf (gethash (aref px (* i 3)) distinct) t)
                     (when (> (aref px (* i 3)) 120) (incf bright)))
                   (is (> (hash-table-count distinct) 16)
                       "only ~d distinct red values — the scene is flat"
                       (hash-table-count distinct))
                   (is (> bright 20)
                       "nothing bright: the trail and bodies did not draw")))
            (ant:destroy-renderer r)
            (ant:destroy-offscreen o)))))))

;;; ------------------------------------------------- level of detail (§5.2)

(defun %ant-reach (radius-px &key (size 360))
  "Draw one ant, alone, at RADIUS-PX on screen, and answer how far its
drawing reaches from its own centre — in ant radii.

A silhouette measurement rather than a pixel comparison, because that is
what the level of detail actually decides: a disc reaches to 1, a body
reaches past its gaster, and only a full ant has legs sticking out."
  (let* ((span (/ (* ant:*ant-radius* size) radius-px))
         (world (* 8.0 span))
         (mid (* 0.5 world))
         (w (ant:make-world :width world :height world :capacity 8 :seed 3))
         ;; The nest is put in a far corner rather than moved afterwards:
         ;; it is a body in the table like any other, and only ADD-COLONY
         ;; puts it somewhere.  Out of frame it cannot be measured.
         (c (ant:add-colony w :nest-x (* 0.06 world) :nest-y (* 0.06 world)
                              :nest-r (* 0.01 world) :capacity 8 :stock 5.0f0))
         (a (ant:world-ants w))
         (b (ant:world-bodies w)))
    (ant:spawn-ant w c)
    (let ((bi (aref (ant:ants-body a) 0)))
      ;; dead centre, facing along +x, mid-stride, and *not* resting, so
      ;; the body kind is the one the drawing path expects
      (setf (aref (ant:bodies-x b) bi) mid
            (aref (ant:bodies-y b) bi) mid
            (aref (ant:bodies-kind b) bi) ant:+body-ant+
            (aref (ant:ants-heading a) 0) 0.0f0
            (aref (ant:ants-gait a) 0) 0.15f0
            (aref (ant:ants-state a) 0) ant:+ant-outbound+))
    (ant:with-headless-gl (ctx :width size :height size)
      (let ((o (ant:make-offscreen size size))
            (r (ant:make-renderer
                :field-width (ant:field-w (ant:colony-field c))
                :field-height (ant:field-h (ant:colony-field c))
                :body-capacity 64)))
        (unwind-protect
             (progn
               (ant:bind-offscreen o)
               (gl:clear-color 0.0 0.0 0.0 1.0)
               (gl:clear :color-buffer-bit)
               (ant:draw-world r w (ant:make-view :cx mid :cy mid :span span
                                                  :vw size :vh size))
               (gl:finish)
               (ant:capture-offscreen
                o (test-png-path (format nil "lod-~d.png" (round radius-px))))
               (let ((px (ant:read-offscreen o))
                     (far 0.0f0)
                     (half (/ size 2.0f0)))
                 (dotimes (i (* size size))
                   ;; the ground is a very dark grid; the ant is not
                   (when (> (+ (aref px (* i 3)) (aref px (+ 1 (* i 3)))
                               (aref px (+ 2 (* i 3))))
                            170)
                     (let* ((x (- (mod i size) half))
                            (y (- (floor i size) half))
                            (d (/ (sqrt (+ (* x x) (* y y))) radius-px)))
                       (setf far (max far (float d 1.0f0))))))
                 far))
          (ant:destroy-renderer r)
          (ant:destroy-offscreen o))))))

(test level-of-detail-picks-the-right-ant
  "§5.2's three tiers, measured rather than asserted.  Zoomed out an ant
is the disc of §3.11 and reaches exactly its own radius; closer in it is
a body, which is longer than it is round; closer still it grows legs and
antennae, which reach well past everything else.

This is also the regression test for the published figures: every
whole-arena picture in the README is at about three pixels per ant, and
the first row is the assertion that those pictures are still drawn by the
shader that drew them before this milestone."
  (with-gl-or-skip
    ;; The three geometries, each forced, and all measured at the same
    ;; generous zoom.  Measuring them at their own zoom levels instead
    ;; sounds more faithful and answers nothing: the disc tier is a few
    ;; pixels across by definition, and at four pixels a silhouette
    ;; rounds to the same number whatever shape it is.
    (let ((disc (let ((ant:*ant-disc-pixels* 1.0f6)) (%ant-reach 14.0)))
          (body (let ((ant:*ant-detail-pixels* 1.0f6)) (%ant-reach 14.0)))
          (full (%ant-reach 14.0)))
      (format t "~&;; LOD reach, in ant radii: disc ~,2f | body ~,2f | full ~,2f~%"
              disc body full)
      ;; A disc reaches its own radius and no further, by construction.
      (is (< disc 1.15) "the disc tier reaches ~,2f radii — that is not a disc"
          disc)
      ;; The body is longer than it is round: the gaster hangs off the back.
      (is (> body (* 1.08 disc))
          "the body tier reaches ~,2f radii against the disc's ~,2f — no body"
          body disc)
      ;; And the legs and antennae reach well past all of it.
      (is (> full (* 1.25 body))
          "the full ant reaches ~,2f radii against the body's ~,2f — no limbs"
          full body)
      (is (> full 1.4) "the full ant reaches only ~,2f radii" full))
    ;; And now the thresholds themselves, which is the half that protects
    ;; the published figures: every whole-arena picture in the README is
    ;; at about three pixels per ant, and at three pixels an ant must
    ;; still be the disc that drew those pictures.
    (let ((small (%ant-reach 2.5))
          (large (%ant-reach 14.0)))
      (is (< small 1.3) "at 2.5 px the ant reaches ~,2f radii — it grew legs"
          small)
      (is (> large 1.4) "at 14 px the ant reaches ~,2f radii — it did not"
          large))))

(test the-alarm-field-is-drawn-and-only-when-there-is-one
  "§3.3's fourth chemical has to be visible, or poking a nest is a thing
that happens to a data structure.

Two worlds on one seed, stepped identically, and only one of them poked —
which controls for the ants exactly, since a frame taken two seconds
later has its ants in different places whatever the chemistry did.  What
is left in the difference is the overlay.

The measure is red minus blue summed over the frame, because that is what
the pass is: the ground and the trail are blue by design (§5.3) and the
alarm ramp is the one warm thing on screen."
  (with-gl-or-skip
    (flet ((build ()
             (let* ((w (ant:make-world :width 0.4f0 :height 0.4f0
                                       :capacity 400 :seed 5))
                    (c (ant:add-colony w :nest-x 0.20f0 :nest-y 0.20f0
                                         :stock 300.0f0)))
               (ant:world-seed-population! w c 60)
               (ant:world-run! w 600)
               (values w c))))
      (multiple-value-bind (calm-w calm-c) (build)
        (multiple-value-bind (hot-w hot-c) (build)
          (is (null (ant:colony-alarm calm-c))
              "a colony grew an alarm field with nothing to release any")
          (ant:poke-nest! hot-w hot-c)
          (ant:world-run! calm-w 60)
          (ant:world-run! hot-w 60)
          (is-true (ant:colony-alarm hot-c) "the poke made no field")
          (ant:with-headless-gl (ctx :width 256 :height 256)
            (let ((o (ant:make-offscreen 256 256))
                  (r (ant:make-renderer
                      :field-width (ant:field-w (ant:colony-field hot-c))
                      :field-height (ant:field-h (ant:colony-field hot-c))
                      :body-capacity 512)))
              (unwind-protect
                   (flet ((warmth (w)
                            (ant:bind-offscreen o)
                            (gl:clear-color 0.02 0.022 0.025 1.0)
                            (gl:clear :color-buffer-bit)
                            (ant:draw-world r w (ant:view-fit w :vw 256 :vh 256))
                            (gl:finish)
                            (let ((px (ant:read-offscreen o)) (sum 0))
                              (dotimes (i (floor (length px) 3) sum)
                                (incf sum (- (aref px (* i 3))
                                             (aref px (+ 2 (* i 3)))))))))
                     (let ((calm (warmth calm-w))
                           (hot (warmth hot-w)))
                       (is (> hot calm)
                           "the poked frame is no warmer than the calm one: ~
                            ~d against ~d — the alarm pass did not draw"
                           hot calm)
                       ;; and by a margin a couple of seconds of ant
                       ;; movement could not account for
                       (is (> (- hot calm) 2000)
                           "the poked frame is warmer by only ~d over ~
                            65536 pixels, which is within what the ants ~
                            moving could do on their own"
                           (- hot calm))))
                (ant:destroy-renderer r)
                (ant:destroy-offscreen o)))))))))
