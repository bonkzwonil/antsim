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
