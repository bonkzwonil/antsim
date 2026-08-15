;;;; world/grid.lisp — the pheromone field (§3.3).
;;;;
;;;; One scalar field per chemical per colony, on a regular grid, indexed
;;;; y*w + x.  M1 builds exactly one chemical — the trail pheromone —
;;;; because none of §3.8 needs the other three, and each of them is a
;;;; second instance of this same structure rather than new machinery.
;;;;
;;;; The invariant that matters: **a field is never authored.**  Every
;;;; field starts at zero and every unit in it was deposited by an ant
;;;; that walked there (§3.3).  There is deliberately no function here
;;;; that paints a trail, and the scenario format has nowhere to express
;;;; one.  A trail that appears is a claim the model is making.

(in-package #:antsim)

(defstruct (field (:constructor %make-field))
  (w 1 :type grid-dim)
  (h 1 :type grid-dim)
  (cell 0.005f0 :type f32)
  (inv-cell 200.0f0 :type f32)
  (origin-x 0.0f0 :type f32)
  (origin-y 0.0f0 :type f32)
  (c nil :type (or null f32v))          ; concentration
  (deposit nil :type (or null f32v))    ; buffer, folded in on the pheromone clock
  (blocked nil :type (or null u8v))     ; 1 where an obstacle covers the cell
  (tau 1800.0f0 :type f32)
  (cap 100.0f0 :type f32))

(defun make-field (&key width height (cell *cell-size*)
                        (origin-x 0.0f0) (origin-y 0.0f0)
                        (tau (trail-tau)) (cap *trail-cap*))
  "A field covering WIDTH x HEIGHT metres, at CELL resolution."
  (let* ((w (max 1 (round width cell)))
         (h (max 1 (round height cell))))
    (check-type w grid-dim)
    (check-type h grid-dim)
    (%make-field :w w :h h :cell cell :inv-cell (/ 1.0f0 cell)
                 :origin-x origin-x :origin-y origin-y
                 :c (mkf32 (* w h)) :deposit (mkf32 (* w h))
                 :blocked (mku8 (* w h))
                 :tau tau :cap cap)))

(declaim (inline field-cell-x field-cell-y field-index field-at))

;;; Clamping happens in *float* space, before the FLOOR, so the result is
;;; provably in range.  Flooring first and clamping after is the obvious
;;; order and the wrong one: a wild coordinate — an ant that a bug has
;;; flung to 1e20 — produces a bignum intermediate, which conses in the
;;; hot loop and defeats every fixnum optimisation downstream.

(defun field-cell-x (f x)
  (declare (type field f) (type f32 x) (optimize (speed 3) (safety 0)))
  (the grid-index
       (floor (clampf (* (- x (field-origin-x f)) (field-inv-cell f))
                      0.0f0
                      (float (1- (field-w f)) 1.0f0)))))

(defun field-cell-y (f y)
  (declare (type field f) (type f32 y) (optimize (speed 3) (safety 0)))
  (the grid-index
       (floor (clampf (* (- y (field-origin-y f)) (field-inv-cell f))
                      0.0f0
                      (float (1- (field-h f)) 1.0f0)))))

(defun field-index (f x y)
  "Cell index for a world position, clamped to the grid."
  (declare (type field f) (type f32 x y) (optimize (speed 3) (safety 0)))
  (+ (field-cell-x f x) (* (field-cell-y f y) (field-w f))))

(defun field-at (f x y)
  "Concentration at a world position.

Nearest cell, not bilinear.  A cell is one body length (§3.1), the three
antennal samples are about a cell apart, and interpolating would smooth
exactly the differences the choice function exists to amplify.  Sampling
the cell the antenna is actually over is both cheaper and more faithful
to what an ant can detect."
  (declare (type field f) (type f32 x y) (optimize (speed 3) (safety 0)))
  (aref (the f32v (field-c f)) (field-index f x y)))

(defun field-blocked-p (f x y)
  (declare (type field f) (type f32 x y) (optimize (speed 3) (safety 0)))
  (= 1 (aref (the u8v (field-blocked f)) (field-index f x y))))

(defun field-deposit! (f x y amount)
  "Add AMOUNT to the deposit *buffer* at a world position.

Never to the concentration itself.  Two ants depositing in the same cell
must commute, because that is what makes the ant loop order-independent
and therefore what makes threaded runs bit-exact (§4.2, §4.4).  Applying
this in place would be faster and would silently destroy determinism."
  (declare (type field f) (type f32 x y amount)
           (optimize (speed 3) (safety 0)))
  (incf (aref (the f32v (field-deposit f)) (field-index f x y)) amount)
  (values))

(defconstant +packet-span+ 15
  "Widest packet the stack buffer allows, in cells.  At the default 5 mm
cell that is a 7.5 cm radius, far beyond anything an ant lays.")

(defun field-deposit-packet! (f x y amount
                              &key (radius *trail-packet-radius*)
                                   (falloff *trail-packet-falloff*))
  "Splat AMOUNT around a world position as one pheromone packet (§3.3).

The weight of a cell falls as exp(-d/falloff) with distance from the
packet's centre and is cut off at RADIUS.  That is what a droplet
actually looks like: a concentrated spot with a soft edge, not a painted
square.

Two properties are worth stating because both are load-bearing:

  * The weights are **normalised over the cells that actually take the
    deposit**, so a packet carries the same total wherever it lands.
    Without that, a packet at the arena edge or beside a wall would
    quietly lose the fraction of itself that fell outside, and trails
    would thin exactly where geometry funnels the traffic that makes
    them.
  * Blocked cells are excluded before normalising, not zeroed afterwards.
    FIELD-STEP! forces them to zero either way, so including them would
    be a silent leak of the same kind, along every wall.

Like FIELD-DEPOSIT!, this writes only to the deposit buffer, so any two
packets commute and the ant loop stays order-independent (§4.2)."
  (declare (type field f) (type f32 x y amount radius falloff)
           (optimize (speed 3) (safety 0)))
  (let* ((cell (field-cell f))
         (ox (field-origin-x f))
         (oy (field-origin-y f))
         (blk (the u8v (field-blocked f)))
         (dep (the f32v (field-deposit f)))
         (fw (field-w f))
         (i0 (field-cell-x f (- x radius))) (i1 (field-cell-x f (+ x radius)))
         (j0 (field-cell-y f (- y radius))) (j1 (field-cell-y f (+ y radius)))
         (span (1+ (- i1 i0)))
         (inv-falloff (/ 1.0f0 (max 1.0f-6 falloff)))
         (r2 (* radius radius))
         (total 0.0f0)
         (wbuf (make-array (* +packet-span+ +packet-span+)
                           :element-type 'single-float
                           :initial-element 0.0f0)))
    (declare (dynamic-extent wbuf) (type f32 total)
             (type (simple-array single-float (*)) wbuf))
    (when (or (> span +packet-span+) (> (1+ (- j1 j0)) +packet-span+))
      ;; A radius this large is a misconfiguration rather than a case to
      ;; handle: fall back to the single cell instead of overrunning.
      (field-deposit! f x y amount)
      (return-from field-deposit-packet! (values)))
    (loop for j of-type fixnum from j0 to j1 do
      (let ((dy (- (+ oy (* (+ (float j 1.0f0) 0.5f0) cell)) y)))
        (declare (type f32 dy))
        (loop for i of-type fixnum from i0 to i1 do
          (let* ((dx (- (+ ox (* (+ (float i 1.0f0) 0.5f0) cell)) x))
                 (d2 (+ (* dx dx) (* dy dy))))
            (declare (type f32 dx d2))
            (when (and (<= d2 r2) (/= 1 (aref blk (+ i (* j fw)))))
              (let ((wgt (exp (* (- (sqrt d2)) inv-falloff))))
                (declare (type f32 wgt))
                (setf (aref wbuf (+ (- i i0) (* (- j j0) +packet-span+))) wgt)
                (incf total wgt)))))))
    (when (> total 0.0f0)
      (let ((k (/ amount total)))
        (declare (type f32 k))
        (loop for j of-type fixnum from j0 to j1 do
          (loop for i of-type fixnum from i0 to i1 do
            (let ((wgt (aref wbuf (+ (- i i0) (* (- j j0) +packet-span+)))))
              (declare (type f32 wgt))
              (when (> wgt 0.0f0)
                (incf (aref dep (+ i (* j fw))) (* k wgt))))))))
    (values)))

(defun field-step! (f &optional (dt *pheromone-dt*))
  "One tick of the pheromone clock (§3.3):

      C <- C * exp(-dt/tau)     evaporation — the colony's only way to forget
      C <- C + deposits         accumulated since the last pheromone tick
      C <- min(C, cap)          saturation

Diffusion is absent by design, not omission: real trail pheromone barely
diffuses on the timescale that matters, and §3.9 cuts it from M1.  A
blocked cell is forced to zero so an obstacle cannot carry a trail."
  (declare (type field f) (type f32 dt) (optimize (speed 3) (safety 1)))
  (let ((c (field-c f))
        (dep (field-deposit f))
        (blk (field-blocked f))
        (decay (exp (- (/ dt (field-tau f)))))
        (cap (field-cap f)))
    (declare (type f32v c dep) (type u8v blk) (type f32 decay cap))
    (dotimes (i (length c))
      (setf (aref c i)
            (if (= 1 (aref blk i))
                0.0f0
                (min cap (+ (* (aref c i) decay) (aref dep i)))))
      (setf (aref dep i) 0.0f0)))
  (values))

(defun field-total (f)
  "Total pheromone in the field — the cheapest possible summary, and the
quantity the trail-death acceptance row watches."
  (declare (type field f))
  (let ((s 0.0d0))
    (loop for v across (the f32v (field-c f)) do (incf s v))
    s))

(defun field-max (f)
  (declare (type field f))
  (let ((m 0.0f0))
    (declare (type f32 m))
    (loop for v across (the f32v (field-c f)) do (setf m (max m v)))
    m))

(defun field-rasterize-polygon! (f poly)
  "Mark every cell whose centre lies inside POLY as blocked.

Cell centres rather than any coverage rule: the mask is used for
pheromone blocking and broad-phase rejection, never for collision — that
is the polygon's own job (§3.7) — so a half-covered cell has no right
answer and the cheap rule is the correct one."
  (declare (type field f) (type polygon poly))
  (let ((blk (field-blocked f))
        (cell (field-cell f)))
    (declare (type u8v blk) (type f32 cell))
    (loop for cy of-type fixnum
            from (max 0 (field-cell-y f (polygon-min-y poly)))
              to (min (1- (field-h f)) (field-cell-y f (polygon-max-y poly)))
          do (loop for cx of-type fixnum
                     from (max 0 (field-cell-x f (polygon-min-x poly)))
                       to (min (1- (field-w f))
                               (field-cell-x f (polygon-max-x poly)))
                   do (let ((wx (+ (field-origin-x f) (* (+ cx 0.5f0) cell)))
                            (wy (+ (field-origin-y f) (* (+ cy 0.5f0) cell))))
                        (when (point-in-polygon-p poly wx wy)
                          (setf (aref blk (+ cx (* cy (field-w f)))) 1))))))
  (values))
