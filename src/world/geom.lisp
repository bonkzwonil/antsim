;;;; world/geom.lisp — polygons and the spatial hash.
;;;;
;;;; Two unrelated things live here because both are pure geometry with no
;;;; knowledge of ants: the static obstacle representation (§3.7) and the
;;;; broad-phase structure that keeps collision linear rather than
;;;; quadratic (§4.2).

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Polygons
;;; --------------------------------------------------------------------
;;;
;;; Vertices are stored flat — x0 y0 x1 y1 ... — in one specialized array
;;; rather than as a vector of conses or a 2-D array.  Flat is what the
;;; edge loop wants, and it is the same decision as §4.2's struct-of-
;;; arrays for the same reason.
;;;
;;; Winding is not significant: containment uses a crossing test, which is
;;; orientation-independent, and the push-out direction is derived from
;;; the closest point rather than from an edge normal.  That means a
;;; scenario author cannot get an obstacle wrong by listing its corners
;;; the other way round.

(defstruct (polygon (:constructor %make-polygon))
  (verts (mkf32 0) :type f32v)          ; x0 y0 x1 y1 ...
  (n 0 :type fixnum)                    ; vertex count
  (min-x 0.0f0 :type f32) (min-y 0.0f0 :type f32)
  (max-x 0.0f0 :type f32) (max-y 0.0f0 :type f32)
  ;; Vertex mean, used only as a fallback outward direction when a disc
  ;; sits exactly on an edge and the closest point gives no direction at
  ;; all.  Not the true centroid, and it does not need to be: it only has
  ;; to point outward reliably enough to make progress.
  (cen-x 0.0f0 :type f32) (cen-y 0.0f0 :type f32))

(defun make-polygon (coords)
  "COORDS is a flat sequence x0 y0 x1 y1 ... of at least three points."
  (let* ((n (floor (length coords) 2))
         (v (mkf32 (* n 2))))
    (assert (>= n 3) (coords) "A polygon needs at least 3 vertices, got ~d." n)
    (map-into v (lambda (c) (float c 1.0f0)) coords)
    (let ((min-x (aref v 0)) (max-x (aref v 0))
          (min-y (aref v 1)) (max-y (aref v 1))
          (sx 0.0f0) (sy 0.0f0))
      (dotimes (i n)
        (let ((x (aref v (* 2 i))) (y (aref v (1+ (* 2 i)))))
          (setf min-x (min min-x x) max-x (max max-x x)
                min-y (min min-y y) max-y (max max-y y))
          (incf sx x) (incf sy y)))
      (%make-polygon :verts v :n n
                     :min-x min-x :min-y min-y :max-x max-x :max-y max-y
                     :cen-x (/ sx n) :cen-y (/ sy n)))))

(defun point-in-polygon-p (poly x y)
  "Crossing-number test.  Points exactly on an edge are not guaranteed
either way, which does not matter: the collision rule pushes a disc out
whenever it is *near* an edge, so the boundary case is never load-bearing."
  (declare (type polygon poly) (type f32 x y)
           (optimize (speed 3) (safety 1)))
  (let ((v (polygon-verts poly))
        (n (polygon-n poly))
        (inside nil))
    (declare (type f32v v) (type fixnum n))
    (when (or (< x (polygon-min-x poly)) (> x (polygon-max-x poly))
              (< y (polygon-min-y poly)) (> y (polygon-max-y poly)))
      (return-from point-in-polygon-p nil))
    (let ((j (1- n)))
      (declare (type fixnum j))
      (dotimes (i n inside)
        (declare (type fixnum i))
        (let ((xi (aref v (* 2 i))) (yi (aref v (1+ (* 2 i))))
              (xj (aref v (* 2 j))) (yj (aref v (1+ (* 2 j)))))
          (when (and (not (eq (> yi y) (> yj y)))
                     (< x (+ xi (/ (* (- xj xi) (- y yi)) (- yj yi)))))
            (setf inside (not inside)))
          (setf j i))))))

(defun polygon-closest-point (poly x y)
  "Closest point on the polygon *boundary* to (X, Y).
Values: cx, cy, squared distance."
  (declare (type polygon poly) (type f32 x y)
           (optimize (speed 3) (safety 1)))
  (let ((v (polygon-verts poly))
        (n (polygon-n poly))
        (best most-positive-single-float)
        (bx 0.0f0) (by 0.0f0))
    (declare (type f32v v) (type fixnum n) (type f32 best bx by))
    (let ((j (1- n)))
      (declare (type fixnum j))
      (dotimes (i n)
        (declare (type fixnum i))
        (let* ((ax (aref v (* 2 j))) (ay (aref v (1+ (* 2 j))))
               (bx2 (aref v (* 2 i))) (by2 (aref v (1+ (* 2 i))))
               (ex (- bx2 ax)) (ey (- by2 ay))
               (len2 (+ (* ex ex) (* ey ey)))
               ;; projection parameter, clamped to the segment
               (tt (if (<= len2 0.0f0)
                       0.0f0
                       (clampf (/ (+ (* (- x ax) ex) (* (- y ay) ey)) len2)
                               0.0f0 1.0f0)))
               (px (+ ax (* tt ex))) (py (+ ay (* tt ey)))
               (dx (- x px)) (dy (- y py))
               (d2 (+ (* dx dx) (* dy dy))))
          (declare (type f32 ax ay bx2 by2 ex ey len2 tt px py dx dy d2))
          (when (< d2 best)
            (setf best d2 bx px by py))
          (setf j i))))
    (values bx by best)))

(declaim (ftype (function (polygon f32 f32 f32) (values f32 f32))
                disc-polygon-correction))
(defun disc-polygon-correction (poly x y r)
  "How far a disc at (X, Y) with radius R must move to leave POLY.
Values: dx, dy — zero when there is no overlap.

Outside the polygon the push is away from the closest boundary point;
inside it is *toward* that point and then out by R, which is what
recovers an ant that has somehow ended up within an obstacle.  Both cases
use the same closest point, which is why this is one function and not
two."
  (declare (type polygon poly) (type f32 x y r)
           (optimize (speed 3) (safety 1)))
  ;; bbox reject, widened by the radius
  (when (or (< x (- (polygon-min-x poly) r)) (> x (+ (polygon-max-x poly) r))
            (< y (- (polygon-min-y poly) r)) (> y (+ (polygon-max-y poly) r)))
    (return-from disc-polygon-correction (values 0.0f0 0.0f0)))
  (multiple-value-bind (cx cy d2) (polygon-closest-point poly x y)
    (declare (type f32 cx cy d2))
    (let ((inside (point-in-polygon-p poly x y))
          (d (sqrt (max d2 0.0f0))))
      (declare (type f32 d))
      ;; Both pushes clear the boundary by an extra *relax-slop*.  Landing
      ;; a disc *exactly* on an edge is the failure this avoids: the
      ;; crossing test is then ambiguous, the closest point gives no
      ;; direction, and the disc oscillates on the boundary for ever
      ;; instead of leaving it.  Observed, not hypothetical.
      (let ((slop *relax-slop*))
        (cond
          ((< d 1.0f-7)
           ;; Degenerate: sitting on an edge or on a vertex, so the
           ;; closest point yields no direction.  Fall back to "away from
           ;; the middle of the polygon", which always makes progress and
           ;; is a pure function of the geometry, so it stays reproducible.
           (if inside
               (let* ((ex (- x (polygon-cen-x poly)))
                      (ey (- y (polygon-cen-y poly)))
                      (el (sqrt (+ (* ex ex) (* ey ey)))))
                 (if (< el 1.0f-7)
                     (values 0.0f0 (+ r slop))
                     (let ((s (/ (+ r slop) el)))
                       (values (* ex s) (* ey s)))))
               (values 0.0f0 0.0f0)))
          (inside
           ;; (cx,cy) is on the boundary and (x,y) is within it, so the way
           ;; out is *toward* the closest point and then clear of it by R.
           (let ((s (/ (+ d r slop) d)))
             (values (* (- cx x) s) (* (- cy y) s))))
          ((< d r)
           ;; outside but touching: push away from the boundary point
           (let ((s (/ (+ (- r d) slop) d)))
             (values (* (- x cx) s) (* (- y cy) s))))
          (t (values 0.0f0 0.0f0)))))))

;;; --------------------------------------------------------------------
;;; Spatial hash (§4.2)
;;; --------------------------------------------------------------------
;;;
;;; Counting sort into preallocated arrays, rebuilt from scratch each
;;; tick.  Rebuilding is cheaper than maintaining, allocates nothing, and
;;; — the reason that actually decides it — produces a bucket order that
;;; depends only on item index, never on insertion history.  An
;;; incrementally maintained hash would put items in an order that
;;; depends on how they moved, and every downstream loop would inherit
;;; that as a hidden order dependence (§4.4).

(defstruct (shash (:constructor %make-shash))
  (cell 0.05f0 :type f32)
  (inv-cell 20.0f0 :type f32)
  (w 1 :type grid-dim) (h 1 :type grid-dim)
  (origin-x 0.0f0 :type f32) (origin-y 0.0f0 :type f32)
  (starts nil :type (or null fixv))     ; length w*h+1
  (counts nil :type (or null fixv))     ; length w*h, scratch
  (items nil :type (or null u32v)))     ; length capacity

(defun make-shash (&key (cell 0.05f0) (origin-x 0.0f0) (origin-y 0.0f0)
                        width height capacity)
  "A hash covering WIDTH x HEIGHT metres from (ORIGIN-X, ORIGIN-Y),
holding up to CAPACITY items."
  (let* ((w (max 1 (ceiling width cell)))
         (h (max 1 (ceiling height cell))))
    (check-type w grid-dim)
    (check-type h grid-dim)
    (%make-shash :cell cell :inv-cell (/ 1.0f0 cell)
                 :w w :h h :origin-x origin-x :origin-y origin-y
                 :starts (mkfix (1+ (* w h)))
                 :counts (mkfix (* w h))
                 :items (mku32 capacity))))

(declaim (inline shash-bucket))
(defun shash-bucket (s x y)
  "Bucket index for a world position, clamped to the grid.
Clamped in float space before the FLOOR — see the note in world/grid.lisp."
  (declare (type shash s) (type f32 x y) (optimize (speed 3) (safety 0)))
  (let ((cx (the grid-index
                 (floor (clampf (* (- x (shash-origin-x s)) (shash-inv-cell s))
                                0.0f0 (float (1- (shash-w s)) 1.0f0)))))
        (cy (the grid-index
                 (floor (clampf (* (- y (shash-origin-y s)) (shash-inv-cell s))
                                0.0f0 (float (1- (shash-h s)) 1.0f0))))))
    (+ cx (* cy (shash-w s)))))

(defun shash-build (s xs ys n)
  "Rebuild S over the first N entries of the parallel arrays XS and YS."
  (declare (type shash s) (type f32v xs ys) (type fixnum n)
           (optimize (speed 3) (safety 1)))
  (let* ((counts (shash-counts s))
         (starts (shash-starts s))
         (items (shash-items s))
         (nb (* (shash-w s) (shash-h s))))
    (declare (type fixv counts starts) (type u32v items) (type fixnum nb))
    (assert (<= n (length items)) (n)
            "Spatial hash capacity ~d exceeded by ~d items."
            (length items) n)
    (fill counts 0)
    (dotimes (i n)
      (incf (aref counts (shash-bucket s (aref xs i) (aref ys i)))))
    ;; prefix sum -> bucket starts
    (let ((acc 0))
      (declare (type fixnum acc))
      (dotimes (b nb)
        (setf (aref starts b) acc)
        (incf acc (aref counts b)))
      (setf (aref starts nb) acc))
    ;; scatter, using counts as a per-bucket write cursor
    (replace counts starts :end1 nb)
    (dotimes (i n)
      (let ((b (shash-bucket s (aref xs i) (aref ys i))))
        (setf (aref items (aref counts b)) i)
        (incf (aref counts b))))
    s))

(defmacro do-shash-neighbours ((var s x y radius) &body body)
  "Run BODY with VAR bound to each item index within RADIUS metres of
(X, Y) — approximately: every item in the overlapped buckets is visited,
so callers still test the real distance.  Broad phase only."
  (let ((ss (gensym "S")) (xx (gensym "X")) (yy (gensym "Y"))
        (rr (gensym "R")) (lo-x (gensym)) (hi-x (gensym))
        (lo-y (gensym)) (hi-y (gensym)) (bx (gensym)) (by (gensym))
        (b (gensym)) (k (gensym)))
    ;; Bounds are clamped in float space before the FLOOR, for the reason
    ;; given in world/grid.lisp: flooring an unclamped coordinate conses a
    ;; bignum and defeats fixnum arithmetic through the whole loop body.
    `(let* ((,ss ,s) (,xx ,x) (,yy ,y) (,rr ,radius)
            (,lo-x (the grid-index
                        (floor (clampf (* (- ,xx ,rr (shash-origin-x ,ss))
                                          (shash-inv-cell ,ss))
                                       0.0f0
                                       (float (1- (shash-w ,ss)) 1.0f0)))))
            (,hi-x (the grid-index
                        (floor (clampf (* (+ (- ,xx (shash-origin-x ,ss)) ,rr)
                                          (shash-inv-cell ,ss))
                                       0.0f0
                                       (float (1- (shash-w ,ss)) 1.0f0)))))
            (,lo-y (the grid-index
                        (floor (clampf (* (- ,yy ,rr (shash-origin-y ,ss))
                                          (shash-inv-cell ,ss))
                                       0.0f0
                                       (float (1- (shash-h ,ss)) 1.0f0)))))
            (,hi-y (the grid-index
                        (floor (clampf (* (+ (- ,yy (shash-origin-y ,ss)) ,rr)
                                          (shash-inv-cell ,ss))
                                       0.0f0
                                       (float (1- (shash-h ,ss)) 1.0f0))))))
       (declare (type grid-index ,lo-x ,hi-x ,lo-y ,hi-y))
       (loop for ,by of-type fixnum from ,lo-y to ,hi-y do
         (loop for ,bx of-type fixnum from ,lo-x to ,hi-x do
           (let ((,b (+ ,bx (* ,by (shash-w ,ss)))))
             (declare (type fixnum ,b))
             (loop for ,k of-type fixnum
                     from (aref (shash-starts ,ss) ,b)
                       below (aref (shash-starts ,ss) (1+ ,b))
                   do (let ((,var (aref (shash-items ,ss) ,k)))
                        ,@body))))))))
