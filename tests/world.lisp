;;;; tests/world.lisp — polygons, the spatial hash, and the pheromone field.
;;;;
;;;; Same suite as tests/suite.lisp, separate file: the core suite guards
;;;; the RNG and the worker pool, this one guards the world the ants walk
;;;; in.  Still no GPU and still no dependencies.

(in-package #:antsim/test)

(in-suite antsim)

;;; ------------------------------------------------------------- geom
;;;
;;; A square from (0.2,0.2) to (0.4,0.4) is the fixture throughout: large
;;; against a 2.5 mm ant disc, and small enough that "well clear of it" is
;;; easy to write down.

(defun square (x0 y0 x1 y1)
  (ant:make-polygon (list x0 y0 x1 y0 x1 y1 x0 y1)))

(test polygon-bbox-and-containment
  (let ((p (square 0.2 0.2 0.4 0.4)))
    (is (= 4 (ant:polygon-n p)))
    (is (= 0.2f0 (ant:polygon-min-x p)))
    (is (= 0.4f0 (ant:polygon-max-y p)))
    (is-true (ant:point-in-polygon-p p 0.3f0 0.3f0))
    (is-false (ant:point-in-polygon-p p 0.1f0 0.3f0))
    (is-false (ant:point-in-polygon-p p 0.3f0 0.5f0))
    (is-false (ant:point-in-polygon-p p 0.45f0 0.45f0))))

(test polygon-containment-is-winding-independent
  "A scenario author must not be able to get an obstacle wrong by listing
its corners the other way round."
  (let ((ccw (ant:make-polygon '(0.2 0.2 0.4 0.2 0.4 0.4 0.2 0.4)))
        (cw  (ant:make-polygon '(0.2 0.2 0.2 0.4 0.4 0.4 0.4 0.2))))
    (dolist (probe '((0.30 0.30 t) (0.50 0.30 nil)
                     (0.30 0.10 nil) (0.25 0.38 t)))
      (destructuring-bind (px py want) probe
        (let ((x (float px 1.0f0)) (y (float py 1.0f0)))
          (is (eq (not (ant:point-in-polygon-p ccw x y)) (not want))
              "ccw ~a" probe)
          (is (eq (not (ant:point-in-polygon-p cw x y)) (not want))
              "cw ~a" probe))))))

(test polygon-closest-point-on-a-square
  (let ((p (square 0.2 0.2 0.4 0.4)))
    (multiple-value-bind (cx cy d2) (ant:polygon-closest-point p 0.1f0 0.3f0)
      (is (< (abs (- cx 0.2f0)) 1e-5))
      (is (< (abs (- cy 0.3f0)) 1e-5))
      (is (< (abs (- (sqrt d2) 0.1f0)) 1e-5)))
    ;; diagonally off a corner: the closest point is the corner itself
    (multiple-value-bind (cx cy d2) (ant:polygon-closest-point p 0.5f0 0.5f0)
      (is (< (abs (- cx 0.4f0)) 1e-5))
      (is (< (abs (- cy 0.4f0)) 1e-5))
      (is (< (abs (- (sqrt d2) (* 0.1f0 (sqrt 2.0f0)))) 1e-5)))))

(test disc-polygon-correction-resolves-the-overlap
  "What matters is not the vector but its effect: after applying the
correction the disc must be outside the polygon and clear of its
boundary by at least its radius.  Written as a property rather than as
expected numbers because the first version of this function pushed
interior discs the wrong way and still returned plausible values."
  (let ((p (square 0.2 0.2 0.4 0.4))
        (r 0.01f0))
    (dolist (start '((0.195 0.300)        ; just outside the left edge
                     (0.205 0.300)        ; just inside the left edge
                     (0.300 0.405)        ; just outside the top
                     (0.300 0.300)        ; deep inside
                     (0.396 0.396)))      ; inside, near a corner
      (destructuring-bind (sx sy) start
        (let ((x (float sx 1.0f0)) (y (float sy 1.0f0)))
          (multiple-value-bind (dx dy) (ant:disc-polygon-correction p x y r)
            (let ((nx (+ x dx)) (ny (+ y dy)))
              (is-false (ant:point-in-polygon-p p nx ny)
                        "~a: still inside after correction" start)
              (multiple-value-bind (cx cy d2)
                  (ant:polygon-closest-point p nx ny)
                (declare (ignore cx cy))
                (is (>= (sqrt d2) (- r 1e-4))
                    "~a: gap ~a is less than the radius ~a"
                    start (sqrt d2) r)))))))))

(test disc-polygon-correction-is-zero-when-clear
  (let ((p (square 0.2 0.2 0.4 0.4)))
    (multiple-value-bind (dx dy)
        (ant:disc-polygon-correction p 0.8f0 0.8f0 0.01f0)
      (is (= 0.0f0 dx))
      (is (= 0.0f0 dy)))
    ;; outside, and further away than the radius
    (multiple-value-bind (dx dy)
        (ant:disc-polygon-correction p 0.18f0 0.30f0 0.01f0)
      (is (= 0.0f0 dx))
      (is (= 0.0f0 dy)))))

(test shash-holds-every-item-exactly-once
  (let* ((n 500)
         (xs (ant:mkf32 n)) (ys (ant:mkf32 n))
         (s (ant:make-shash :cell 0.05f0 :width 1.0f0 :height 1.0f0
                            :capacity n)))
    (dotimes (i n)
      (setf (aref xs i) (ant:rnd01 i 0 0)
            (aref ys i) (ant:rnd01 i 0 1)))
    (ant:shash-build s xs ys n)
    (let ((seen (make-array n :initial-element 0))
          (nb (* (ant:shash-w s) (ant:shash-h s))))
      (dotimes (b nb)
        (loop for k from (aref (ant:shash-starts s) b)
                below (aref (ant:shash-starts s) (1+ b))
              do (incf (aref seen (aref (ant:shash-items s) k)))))
      (is (every (lambda (c) (= c 1)) seen)))))

(test shash-neighbours-never-under-report
  "Broad phase may over-report — it visits whole buckets — but a missed
pair is a missed collision, so the containment direction is the one that
has to hold."
  (let* ((n 400) (radius 0.06f0)
         (xs (ant:mkf32 n)) (ys (ant:mkf32 n))
         (s (ant:make-shash :cell 0.05f0 :width 1.0f0 :height 1.0f0
                            :capacity n)))
    (dotimes (i n)
      (setf (aref xs i) (ant:rnd01 i 7 0)
            (aref ys i) (ant:rnd01 i 7 1)))
    (ant:shash-build s xs ys n)
    (dotimes (probe 25)
      (let ((px (ant:rnd01 probe 99 0))
            (py (ant:rnd01 probe 99 1))
            (brute '())
            (found (make-hash-table)))
        (dotimes (i n)
          (let ((dx (- (aref xs i) px)) (dy (- (aref ys i) py)))
            (when (<= (+ (* dx dx) (* dy dy)) (* radius radius))
              (push i brute))))
        (ant:do-shash-neighbours (i s px py radius)
          (setf (gethash i found) t))
        (dolist (i brute)
          (is-true (gethash i found)
                   "probe ~d missed item ~d, which is inside the radius"
                   probe i))))))

(test shash-rebuild-is-a-pure-function-of-positions
  "Bucket order must depend on item index alone, never on how the items
got there — otherwise every loop over the hash inherits a hidden order
dependence and threaded runs stop being bit-exact (§4.4)."
  (let* ((n 300)
         (xs (ant:mkf32 n)) (ys (ant:mkf32 n))
         (a (ant:make-shash :cell 0.05f0 :width 1.0f0 :height 1.0f0
                            :capacity n))
         (b (ant:make-shash :cell 0.05f0 :width 1.0f0 :height 1.0f0
                            :capacity n)))
    (dotimes (i n)
      (setf (aref xs i) (ant:rnd01 i 3 0)
            (aref ys i) (ant:rnd01 i 3 1)))
    ;; A is built, disturbed with a completely different layout, rebuilt
    (ant:shash-build a xs ys n)
    (let ((sx (ant:mkf32 n 0.5f0)) (sy (ant:mkf32 n 0.5f0)))
      (ant:shash-build a sx sy n))
    (ant:shash-build a xs ys n)
    (ant:shash-build b xs ys n)
    (is (equalp (ant:shash-items a) (ant:shash-items b)))
    (is (equalp (ant:shash-starts a) (ant:shash-starts b)))))

;;; ------------------------------------------------------------- grid

(test field-geometry
  (let ((f (ant:make-field :width 1.0f0 :height 0.5f0 :cell 0.005f0)))
    (is (= 200 (ant:field-w f)))
    (is (= 100 (ant:field-h f)))
    (is (= 0 (ant:field-index f 0.0f0 0.0f0)))
    (is (= 199 (ant:field-index f 0.999f0 0.0f0)))
    ;; wild coordinates clamp rather than crashing or consing a bignum
    (is (= 0 (ant:field-index f -5.0f0 -5.0f0)))
    (is (= (1- (* 200 100)) (ant:field-index f 99.0f0 99.0f0)))))

(test field-deposits-go-to-the-buffer-not-the-field
  "Depositing in place would be faster and would silently destroy
determinism: two ants in one cell have to commute (§4.2)."
  (let ((f (ant:make-field :width 0.1f0 :height 0.1f0)))
    (ant:field-deposit! f 0.05f0 0.05f0 5.0f0)
    (is (= 0.0f0 (ant:field-at f 0.05f0 0.05f0)))
    (is (= 0.0d0 (ant:field-total f)))
    (ant:field-step! f 0.0f0)
    (is (= 5.0f0 (ant:field-at f 0.05f0 0.05f0)))))

(test field-deposits-commute
  (let ((a (ant:make-field :width 0.1f0 :height 0.1f0))
        (b (ant:make-field :width 0.1f0 :height 0.1f0)))
    (ant:field-deposit! a 0.05f0 0.05f0 1.0f0)
    (ant:field-deposit! a 0.05f0 0.05f0 2.0f0)
    (ant:field-deposit! b 0.05f0 0.05f0 2.0f0)
    (ant:field-deposit! b 0.05f0 0.05f0 1.0f0)
    (ant:field-step! a 0.0f0)
    (ant:field-step! b 0.0f0)
    (is (= (ant:field-at a 0.05f0 0.05f0) (ant:field-at b 0.05f0 0.05f0)))))

(test field-evaporates-at-the-configured-rate
  (let ((f (ant:make-field :width 0.1f0 :height 0.1f0 :tau 100.0f0)))
    (ant:field-deposit! f 0.05f0 0.05f0 50.0f0)
    (ant:field-step! f 0.0f0)
    (is (= 50.0f0 (ant:field-at f 0.05f0 0.05f0)))
    (dotimes (i 100) (ant:field-step! f 1.0f0))   ; one time constant
    (let ((want (* 50.0f0 (exp -1.0f0))))
      (is (< (abs (- (ant:field-at f 0.05f0 0.05f0) want)) 0.05f0)
          "after one tau: ~a, want ~a" (ant:field-at f 0.05f0 0.05f0) want))))

(test field-half-life-matches-the-documented-conversion
  "params.lisp claims tau = 1800 s is a half-life of tau ln 2 = 1248 s.
If that conversion were wrong every trail in the model would be 44% too
persistent, and nothing else in the system would notice."
  (let ((f (ant:make-field :width 0.05f0 :height 0.05f0 :tau 1800.0f0)))
    (ant:field-deposit! f 0.02f0 0.02f0 80.0f0)
    (ant:field-step! f 0.0f0)
    (dotimes (i 1248) (ant:field-step! f 1.0f0))
    (is (< (abs (- (ant:field-at f 0.02f0 0.02f0) 40.0f0)) 0.05f0)
        "half-life: ~a, want 40" (ant:field-at f 0.02f0 0.02f0))))

(test field-saturates
  (let ((f (ant:make-field :width 0.1f0 :height 0.1f0 :cap 100.0f0)))
    (dotimes (i 10)
      (ant:field-deposit! f 0.05f0 0.05f0 40.0f0)
      (ant:field-step! f 0.0f0))
    (is (= 100.0f0 (ant:field-at f 0.05f0 0.05f0)))))

(test field-blocked-cells-cannot-hold-pheromone
  (let ((f (ant:make-field :width 0.2f0 :height 0.2f0))
        (p (square 0.05 0.05 0.15 0.15)))
    (ant:field-rasterize-polygon! f p)
    (is-true (ant:field-blocked-p f 0.10f0 0.10f0))
    (is-false (ant:field-blocked-p f 0.02f0 0.02f0))
    (ant:field-deposit! f 0.10f0 0.10f0 50.0f0)
    (ant:field-deposit! f 0.02f0 0.02f0 50.0f0)
    (ant:field-step! f 0.0f0)
    (is (= 0.0f0 (ant:field-at f 0.10f0 0.10f0)))
    (is (= 50.0f0 (ant:field-at f 0.02f0 0.02f0)))))

;;; --------------------------------------------------------- diffusion
;;;
;;; §3.3's third line, which only the alarm field uses.  The trail and the
;;; repellent do not diffuse and must not start: the first test here is
;;; that this pass exists without touching them.

(defun %spike-field (&key (diffusion 0.2f0) (steps 1) (cell 0.02f0))
  "A 0.4 x 0.4 m field with one unit of something in the middle cell."
  (let ((f (ant:make-field :width 0.4f0 :height 0.4f0 :cell cell
                           :tau 1.0f9 :cap 1.0f9
                           :diffusion diffusion :diffusion-steps steps)))
    (setf (aref (ant:field-c f) (ant:field-index f 0.2f0 0.2f0)) 1.0f0)
    f))

(test a-field-that-does-not-diffuse-is-not-touched-by-the-pass
  "The trail and the repellent ask for no diffusion, so FIELD-DIFFUSE! has
to be exactly nothing for them — not 'a very small amount'.  Asserted on
identity rather than on closeness, because the claim being made elsewhere
is that adding diffusion left every existing measurement alone, and
'close' is not that claim."
  (let ((f (ant:make-field :width 0.2f0 :height 0.2f0)))
    (is (= 0.0f0 (ant:field-diffusion f)))
    (ant:field-deposit! f 0.10f0 0.10f0 50.0f0)
    (ant:field-step! f 0.0f0)
    (let ((before (map '(vector single-float) #'identity (ant:field-c f))))
      (ant:field-diffuse! f)
      (is (every #'= before (ant:field-c f))
          "a non-diffusing field moved under FIELD-DIFFUSE!"))))

(test diffusion-spreads-without-losing-anything
  "Conservation is the property, not the shape.  An explicit Laplacian
that is even slightly asymmetric leaks or gains a little every sub-step,
and on a field that is stepped once a second for an hour a slow leak is
indistinguishable from evaporation — which this field is supposed to be
measuring separately."
  (let* ((f (%spike-field :diffusion 0.25f0 :steps 8))
         (before (ant:field-total f)))
    (ant:field-diffuse! f)
    (is (< (abs (- (ant:field-total f) before)) 1.0f-4)
        "diffusion changed the total from ~,6f to ~,6f"
        before (ant:field-total f))
    (is (< (ant:field-at f 0.2f0 0.2f0) 1.0f0)
        "the spike did not spread at all")
    (is (plusp (ant:field-at f 0.24f0 0.2f0))
        "nothing reached a cell two away")))

(test diffusion-is-symmetric-in-all-four-directions
  "A five-point stencil written by hand gets one of its four indices wrong
sooner or later, and the failure is a plume that drifts — which reads as
a wind nobody put in the model.  Equality, not closeness: the four
neighbours are the same arithmetic on the same numbers."
  (let ((f (%spike-field :diffusion 0.2f0 :steps 3)))
    (ant:field-diffuse! f)
    (let ((l (ant:field-at f 0.16f0 0.20f0))
          (r (ant:field-at f 0.24f0 0.20f0))
          (d (ant:field-at f 0.20f0 0.16f0))
          (u (ant:field-at f 0.20f0 0.24f0)))
      (is (plusp l) "nothing spread at all")
      (is (= l r) "left ~,8f and right ~,8f disagree" l r)
      (is (= l d) "left ~,8f and down ~,8f disagree" l d)
      (is (= l u) "left ~,8f and up ~,8f disagree" l u))))

(test diffusion-does-not-drain-into-a-wall
  "The tempting shortcut is to treat a blocked neighbour as a
zero-concentration one.  That is not a boundary, it is a *sink*: alarm
laid against a wall would drain into the rock, fastest exactly where the
ants are most crowded against it, and the field would look plausible
while quietly losing its mass to the terrain.  No flux instead — a cell
exchanges only with the neighbours it has."
  (let ((f (ant:make-field :width 0.4f0 :height 0.4f0 :cell 0.02f0
                           :tau 1.0f9 :cap 1.0f9
                           :diffusion 0.25f0 :diffusion-steps 12)))
    (ant:field-rasterize-polygon! f (square 0.24 0.0 0.40 0.40))
    (setf (aref (ant:field-c f) (ant:field-index f 0.20f0 0.20f0)) 1.0f0)
    (let ((before (ant:field-total f)))
      (ant:field-diffuse! f)
      (is (< (abs (- (ant:field-total f) before)) 1.0f-4)
          "the wall absorbed ~,6f of the field"
          (- before (ant:field-total f)))
      (is (= 0.0f0 (ant:field-at f 0.30f0 0.20f0))
          "there is chemistry inside the wall"))
    ;; and it piles up against the wall rather than passing through it
    (is (> (ant:field-at f 0.22f0 0.20f0) (ant:field-at f 0.18f0 0.20f0))
        "the cell against the wall is no fuller than its mirror image, so ~
         the reflected flux went somewhere else")))

(test an-unstable-diffusion-is-refused-rather-than-clamped
  "Above 0.25 the explicit scheme oscillates and then diverges.  Clamping
would leave a caller with a wrong idea of what this number is and a field
that looked almost right; the bound is a fact about the scheme and is
worth saying out loud."
  (signals error
    (ant:make-field :width 0.1f0 :height 0.1f0
                    :diffusion 0.4f0 :diffusion-steps 1))
  ;; asking for diffusion but no steps is not an error, it is no diffusion
  (let ((f (ant:make-field :width 0.1f0 :height 0.1f0
                           :diffusion 0.2f0 :diffusion-steps 0)))
    (is (= 0.0f0 (ant:field-diffusion f)))))

;;; ------------------------------------------------------ trail packets

(test packet-carries-its-whole-amount
  "A packet spreads, and spreading must not lose anything.

The deposit is normalised over the cells that actually receive it, so the
total is the same wherever the packet lands — in open ground, against the
arena edge, or beside a wall.  Without that, a trail would thin exactly
where geometry funnels the traffic that makes it, which is the worst
possible place for a silent leak."
  (let ((open (ant:make-field :width 0.2f0 :height 0.2f0))
        (edge (ant:make-field :width 0.2f0 :height 0.2f0))
        (wall (ant:make-field :width 0.2f0 :height 0.2f0)))
    (ant:field-rasterize-polygon! wall (square 0.10 0.0 0.20 0.20))
    (ant:field-deposit-packet! open 0.10f0 0.10f0 60.0f0)
    (ant:field-deposit-packet! edge 0.001f0 0.001f0 60.0f0)   ; a corner
    (ant:field-deposit-packet! wall 0.09f0 0.10f0 60.0f0)     ; beside a wall
    (ant:field-step! open 0.0f0)
    (ant:field-step! edge 0.0f0)
    (ant:field-step! wall 0.0f0)
    (dolist (spec (list (list "open ground" open)
                        (list "the arena corner" edge)
                        (list "a wall" wall)))
      (destructuring-bind (what f) spec
        (is (< (abs (- (ant:field-total f) 60.0d0)) 0.05d0)
            "a packet against ~a carries ~,2f of its 60 units"
            what (ant:field-total f))))))

(test packet-falls-off-with-radius
  "The intensity of a packet decays with distance from its centre — that
gradient is what the alpha channel draws and what the antennae read.  A
flat disc would render as a hard-edged blob and would give the sensors
nothing to climb."
  (let ((f (ant:make-field :width 0.2f0 :height 0.2f0)))
    (ant:field-deposit-packet! f 0.1f0 0.1f0 100.0f0
                               :radius 0.02f0 :falloff 0.006f0)
    (ant:field-step! f 0.0f0)
    (let ((c0 (ant:field-at f 0.100f0 0.100f0))
          (c1 (ant:field-at f 0.108f0 0.100f0))
          (c2 (ant:field-at f 0.116f0 0.100f0))
          (out (ant:field-at f 0.140f0 0.100f0)))
      (is (> c0 c1) "centre ~,3f is not above 8 mm out ~,3f" c0 c1)
      (is (> c1 c2) "8 mm ~,3f is not above 16 mm ~,3f" c1 c2)
      (is (= 0.0f0 out) "the packet reaches past its radius: ~,3f" out))))

(test packet-is-wider-than-one-cell
  "The reason packets exist at all.  A single-cell mark is narrower than
the span the antennae sample, so an ant could straddle its own trail with
a sensor either side of it and read zero on both."
  (let ((f (ant:make-field :width 0.2f0 :height 0.2f0)))
    (ant:field-deposit-packet! f 0.1f0 0.1f0 100.0f0)
    (ant:field-step! f 0.0f0)
    (let ((wet 0))
      (dotimes (j (ant:field-h f))
        (dotimes (i (ant:field-w f))
          (when (> (aref (ant:field-c f) (+ i (* j (ant:field-w f)))) 0.0f0)
            (incf wet))))
      (is (> wet 8) "a packet wetted only ~d cells" wet))))

(test packets-commute-like-single-cell-deposits
  "Same determinism requirement as FIELD-DEPOSIT!: the ant loop must stay
order-independent (§4.2)."
  (let ((a (ant:make-field :width 0.2f0 :height 0.2f0))
        (b (ant:make-field :width 0.2f0 :height 0.2f0)))
    (ant:field-deposit-packet! a 0.10f0 0.10f0 7.0f0)
    (ant:field-deposit-packet! a 0.11f0 0.10f0 3.0f0)
    (ant:field-deposit-packet! b 0.11f0 0.10f0 3.0f0)
    (ant:field-deposit-packet! b 0.10f0 0.10f0 7.0f0)
    (ant:field-step! a 0.0f0)
    (ant:field-step! b 0.0f0)
    (dotimes (i (length (ant:field-c a)))
      (is (= (aref (ant:field-c a) i) (aref (ant:field-c b) i))))))

(test one-ant-cannot-commit-the-colony
  "*trail-deposit* documents its own regime: a single pass lays a few
units, and a trail needs several passes before it outweighs *choice-k*.

This is the invariant that a first attempt at time compression broke.
Steady state is deposit-rate x tau, so scaling deposition by whatever
divides tau looks like it preserves everything — but it also makes one
ant's fresh mark that much louder, and at 30x it put a single pass at 43
units against a k of 20.  One ant could commit the colony by walking past
once.  The two properties cannot both survive a compressed tau, and this
test says which one wins."
  (let ((f (ant:make-field :width 0.2f0 :height 0.2f0)))
    ;; exactly one packet: what one ant leaves in one touch
    (ant:field-deposit-packet!
     f 0.10f0 0.10f0
     (* (ant:trail-deposit-rate)
        (/ ant:*trail-packet-spacing*
           (* ant:*walk-speed-laden* ant:*motion-dt*))))
    (ant:field-step! f 0.0f0)
    (is (< (ant:field-max f) (* 0.5f0 ant:*choice-k*))
        "a single pass peaks at ~,1f against k = ~,1f — one ant is ~
         committing the colony on its own"
        (ant:field-max f) ant:*choice-k*)
    (is (> (ant:field-max f) 0.2f0)
        "a single pass left ~,2f, which is not 'a few units' either"
        (ant:field-max f))))

(test a-real-trail-mostly-does-not-clip
  "Saturation must be the exception, not the rule.

*trail-cap* is a saturation ceiling — a real trail is not unboundedly
strong — but it destroys information wherever it binds.  Deposits are
laid with an exponential falloff, and a clipped cell throws that shape
away *after* the fact: both antennae read the ceiling, their difference
is exactly zero, and the choice function has nothing to discriminate on
precisely where the trail is strongest.

The cap was 100 while a working route peaks near 300 and the nest
entrance reaches about 890, so nearly every cell that mattered was
pinned.  This test is what stops that returning, and it is measured on a
real run rather than on synthetic traffic — the concentration a route
reaches depends on how ants spread along and across it, which is exactly
what a hand-made deposit pattern gets wrong."
  (let* ((w (ant:make-world :width 0.6f0 :height 0.6f0 :capacity 4000))
         (c (ant:add-colony w :nest-x 0.30f0 :nest-y 0.08f0
                              :capacity 2000 :stock 500.0f0)))
    (ant:add-food w 0.34f0 0.43f0 0.03f0 4000.0f0 :quality 1.0f0)
    (ant:world-seed-population! w c 150)
    (ant:world-run! w (* 1200 10))                  ; ten simulated minutes
    (let ((f (ant:colony-field c))
          (wet 0) (above-k 0) (clipped 0))
      (dotimes (i (length (ant:field-c f)))
        (let ((v (aref (ant:field-c f) i)))
          (when (> v 0.5f0) (incf wet))
          (when (> v ant:*choice-k*) (incf above-k))
          (when (>= v (* 0.99f0 ant:*trail-cap*)) (incf clipped))))
      (is (> above-k 50)
          "only ~d cells got above k — no trail formed, so nothing about ~
           clipping is being tested" above-k)
      (is (< clipped (max 1 (floor above-k 10)))
          "~d of ~d above-threshold cells are pinned at the cap; the ~
           ceiling is flattening the trail" clipped above-k))))

(test decay-scale-actually-speeds-forgetting
  "And the compression has to do what it is for: a trail must visibly
fade on a timescale a watcher can see."
  (let ((remaining
          (loop for scale in '(1.0f0 30.0f0)
                collect (let ((ant:*trail-decay-scale* scale))
                          (let ((f (ant:make-field :width 0.1f0
                                                   :height 0.1f0)))
                            (ant:field-deposit! f 0.05f0 0.05f0 100.0f0)
                            (ant:field-step! f 0.0f0)
                            ;; two minutes of simulated time
                            (dotimes (i 120) (ant:field-step! f 1.0f0))
                            (ant:field-at f 0.05f0 0.05f0))))))
    (destructuring-bind (slow fast) remaining
      (is (> slow 90.0f0)
          "at life speed a trail should barely move in two minutes, ~
           got ~,1f" slow)
      (is (< fast 20.0f0)
          "at 30x a trail should be mostly gone in two minutes, got ~,1f"
          fast))))

(test field-cannot-be-authored
  "§3.3: every field starts at zero and every unit in it was deposited by
an ant that walked there.  There is deliberately no function that paints
a trail, and this is the test that says so — a trail that appears in a
run is a claim the model is making."
  (let ((f (ant:make-field :width 0.5f0 :height 0.5f0)))
    (is (= 0.0d0 (ant:field-total f)))
    (dotimes (i 100) (ant:field-step! f 1.0f0))
    (is (= 0.0d0 (ant:field-total f)))
    (is (= 0.0f0 (ant:field-max f)))))

;;; ------------------------------------------------------------- food
;;;
;;; A source is an accumulator, and it is the only one in the model whose
;;; magnitude and whose increment are six orders of magnitude apart.  That
;;; is what these guard.

(test a-large-source-registers-a-single-small-take
  "A forager takes ~0.02 units per tick.  Held in single precision a
500 000-unit pile cannot see that: the ulp up there is 0.031, so 0.02 is
under half an ulp and the subtraction rounds straight back to where it
started.  The pile is then eaten from for ever and never goes down.

This is not hypothetical.  It is what the Beckers apparatus found first —
850 recorded feeding visits to a source that had lost nothing at all —
and a poor source is worse still, because its take is quality-scaled and
smaller yet.  Asserted on the struct rather than through a colony run, so
a regression names the cause instead of a food total being slightly off."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0))
         (f (ant:add-food w 0.5f0 0.5f0 0.03f0 500000.0f0)))
    (let ((before (ant:food-amount f)))
      (decf (ant:food-amount f) 0.02d0)
      (is (< (ant:food-amount f) before)
          "a 0.02 take vanished into a ~,0f-unit pile — the amount is ~
           back in single precision" before)
      (is (< (abs (- (- before (ant:food-amount f)) 0.02d0)) 1.0d-9)
          "the take was quantised: ~,6f went missing rather than 0.02"
          (- before (ant:food-amount f))))
    ;; and a thousand of them add up to what a thousand of them should
    (let ((before (ant:food-amount f)))
      (dotimes (i 1000) (decf (ant:food-amount f) 0.02d0))
      (is (< (abs (- (- before (ant:food-amount f)) 20.0d0)) 1.0d-6)
          "1000 takes of 0.02 came to ~,6f rather than 20"
          (- before (ant:food-amount f))))))

(test a-sources-radius-tracks-what-is-left-of-it
  "The drawn and blocking radius is derived from the amount, so it has to
survive the same arithmetic.  A quarter of the food left is half the
radius, because the amount is an *area*."
  (let* ((w (ant:make-world :width 1.0f0 :height 1.0f0))
         (f (ant:add-food w 0.5f0 0.5f0 0.04f0 100000.0f0)))
    (is (< (abs (- (ant:food-current-radius f) 0.04f0)) 1.0f-4)
        "a full source is not at its authored radius: ~,5f"
        (ant:food-current-radius f))
    (setf (ant:food-amount f) 25000.0d0)
    (is (< (abs (- (ant:food-current-radius f) 0.02f0)) 1.0f-4)
        "a quarter of the food should be half the radius, got ~,5f"
        (ant:food-current-radius f))
    (setf (ant:food-amount f) 0.0d0)
    (is-true (ant:food-empty-p f))
    (is (= 0.0f0 (ant:food-current-radius f)))))

;;; ------------------------------------------- terrain placed by hand
;;;
;;; ADD-BLOCK is the live window's one way of changing terrain in a world
;;; that is already running (§5.5).  The window needs a GL context and is
;;; not testable here; the world mutation is where the consequences are,
;;; and all of it is in the core.

(defun %block-world (&key (nest-x 0.5f0) (nest-y 0.5f0))
  (let ((w (ant:make-world :width 1.0f0 :height 1.0f0 :capacity 64)))
    (ant:add-colony w :name "one" :nest-x nest-x :nest-y nest-y :nest-r 0.02f0)
    w))

(test a-block-becomes-terrain-in-every-field
  "A block has to reach both of a colony's fields, not just the trail.

The repellent shares the grid abstraction and nothing else, so it is the
one an addition forgets — and a no-entry mark that survives inside a rock
is a mark ants would read through solid terrain.  ADD-OBSTACLE rasterizes
into both; this pins that it stays that way, and that a blocked cell
really does refuse to hold chemistry."
  (let* ((w (%block-world))
         (c (first (ant:world-colonies w)))
         (f (ant:colony-field c))
         (rf (ant:colony-repel c)))
    (multiple-value-bind (poly why) (ant:add-block w 0.2f0 0.8f0 0.01f0)
      (is-true poly "a block in open arena was refused: ~a" why)
      (is (null why))
      (is (member poly (ant:world-obstacles w))))
    (is-true (ant:field-blocked-p f 0.2f0 0.8f0)
             "the trail field does not know about the block")
    (is-true (ant:field-blocked-p rf 0.2f0 0.8f0)
             "the repellent field does not know about the block")
    (is-false (ant:field-blocked-p f 0.6f0 0.3f0)
              "a cell nowhere near the block came out blocked")
    ;; and the trail that was already there does not survive under it
    (ant:field-deposit! f 0.2f0 0.8f0 50.0f0)
    (ant:field-step! f)
    (is (= 0.0f0 (ant:field-at f 0.2f0 0.8f0))
        "pheromone is sitting inside a rock: ~,4f"
        (ant:field-at f 0.2f0 0.8f0))))

(test a-block-will-not-seal-a-nest
  "Refused, and refused on the *disc* rather than on the centre.

A block that merely clips the entrance is the dangerous one: it looks
placed-next-to rather than placed-on, and it walls in a colony just as
completely.  So the check is closest-point against the nest radius, and
the interesting assertion is the near miss — 0.525 puts the block's lower
edge at 0.515, inside a nest that reaches 0.52."
  (let ((w (%block-world)))
    (multiple-value-bind (poly why) (ant:add-block w 0.5f0 0.5f0 0.01f0)
      (is (null poly) "a block straight onto the nest was allowed")
      (is (eq :nest why)))
    (multiple-value-bind (poly why) (ant:add-block w 0.5f0 0.525f0 0.01f0)
      (is (null poly) "a block clipping the nest entrance was allowed")
      (is (eq :nest why)))
    ;; a refusal must not have left anything behind
    (is (null (ant:world-obstacles w))
        "a refused block was added to the world anyway")
    ;; clear of the disc, so it is terrain like any other
    (multiple-value-bind (poly why) (ant:add-block w 0.5f0 0.545f0 0.01f0)
      (is-true poly "a block clear of the nest was refused: ~a" why))))

(test a-block-outside-the-arena-is-a-miss-not-an-error
  "The view can be zoomed out past the world's edge, so a click outside is
an ordinary thing to do and must not signal.  A block whose *centre* is
inside may hang over the edge: the boundary already stops everything, so
there is nothing there to get wrong."
  (let ((w (%block-world)))
    (is (eq :nest (nth-value 1 (ant:add-block w 0.5f0 0.5f0 0.01f0))))
    (dolist (p '((-0.01 0.5) (1.01 0.5) (0.5 -0.01) (0.5 1.01)))
      (multiple-value-bind (poly why)
          (ant:add-block w (float (first p) 1.0f0) (float (second p) 1.0f0)
                         0.01f0)
        (is (null poly) "a block at ~a was placed outside the arena" p)
        (is (eq :outside why))))
    (is (null (ant:world-obstacles w)))
    ;; on the edge, hanging half out, is fine
    (is-true (ant:add-block w 0.0f0 0.5f0 0.01f0))))

(test a-block-dropped-on-an-ant-pushes-it-out
  "The docstring's claim, asserted rather than believed.

ADD-BLOCK does not consult the ants standing where it lands; it relies on
the ordinary terrain constraint recovering a disc found *inside* a
polygon on the next tick.  If that ever stopped being true, a block
dropped on a crowd would trap it silently — every ant still alive, still
stepping, and none of them able to leave.  Three iterations is one tick's
worth, which is the budget the real loop gives it."
  (let* ((w (%block-world))
         (b (ant:world-bodies w))
         (i (ant:bodies-alloc b 0.2f0 0.8f0 ant:*ant-radius* ant:+body-ant+)))
    (multiple-value-bind (poly why) (ant:add-block w 0.2f0 0.8f0 0.01f0)
      (is-true poly "the fixture block was refused: ~a" why)
      (is-true (ant:point-in-polygon-p poly 0.2f0 0.8f0)
               "the fixture ant is not inside the block to begin with")
      (ant:bodies-resolve! b (ant:world-obstacles w))
      (let ((x (aref (ant:bodies-x b) i))
            (y (aref (ant:bodies-y b) i)))
        (is-false (ant:point-in-polygon-p poly x y)
                  "an ant is still inside the block after a tick, at ~
                   (~,4f ~,4f)" x y)
        ;; and out by its own radius, not merely across the boundary
        (multiple-value-bind (dx dy)
            (ant:disc-polygon-correction poly x y ant:*ant-radius*)
          (is (and (= 0.0f0 dx) (= 0.0f0 dy))
              "the ant is out but still overlapping: correction (~,5f ~,5f)"
              dx dy))))))

(test the-alarm-field-is-the-same-grid-as-the-trail
  "Not a detail: the renderer sizes one texture from the trail field and
uploads both fields through it, so two grids that disagreed would not be
a wrong picture — they would be a write past the end of a texture.  The
cell is taken from the trail field rather than from the parameter they
both happen to default to, and this is what says so."
  (let* ((w (ant:make-world :width 0.5f0 :height 0.3f0 :capacity 32))
         (c (ant:add-colony w :name "one" :nest-x 0.25f0 :nest-y 0.15f0))
         (trail (ant:colony-field c))
         (alarm (ant:ensure-alarm-field w c)))
    (is (= (ant:field-w trail) (ant:field-w alarm))
        "widths differ: trail ~d, alarm ~d"
        (ant:field-w trail) (ant:field-w alarm))
    (is (= (ant:field-h trail) (ant:field-h alarm))
        "heights differ: trail ~d, alarm ~d"
        (ant:field-h trail) (ant:field-h alarm))
    (is (= (ant:field-cell trail) (ant:field-cell alarm)))
    ;; and it is the same field on the second call, not a fresh one
    (is (eq alarm (ant:ensure-alarm-field w c))
        "ENSURE-ALARM-FIELD built a second field over the first")))
