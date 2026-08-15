;;;; world/scene.lisp — colonies, nests, food sources, and the world.
;;;;
;;;; The things a scenario names (§6).  Note what is *not* here: there is
;;;; no way to place an ant and no way to place pheromone.  A scenario
;;;; describes a place, and the colony is a population that grows from a
;;;; starting count (§3.10) rather than a list of individuals.

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Food (§3.7)
;;; --------------------------------------------------------------------

(defstruct (food (:constructor %make-food))
  (body 0 :type fixnum)                 ; index into the body table
  (x 0.0f0 :type f32) (y 0.0f0 :type f32) (r 0.01f0 :type f32)
  ;; Amount depletes; at zero the source is gone and the trail to it dies
  ;; by evaporation alone, with no special case anywhere (§3.7).
  (amount 0.0f0 :type f32)
  (initial 0.0f0 :type f32)
  ;; Quality sets crop fill rate *and* trail deposition rate, which is why
  ;; a rich source out-recruits a poor one at equal distance, and why a
  ;; source below *trail-quality-threshold* is eaten but never recruited
  ;; to.  Two acceptance rows depend on this one number.
  (quality 1.0f0 :type f32)
  (renew 0.0f0 :type f32))              ; units per colony tick

(defun food-empty-p (f)
  (declare (type food f))
  (<= (food-amount f) 0.0f0))

(defun food-current-radius (f)
  "The source's *present* radius, shrinking with what is left of it.

By the square root, so the disc's **area** tracks the amount — a pile
half eaten is half the area, not half the width.

This is the collision radius, not just the drawn one, and that is the
point: a smaller pile has a shorter edge, so fewer ants can reach it at
once and the queue behind it grows as it empties.  Feeding rate falling
as a source runs down is a real constraint on foraging, and it comes out
of the geometry for free rather than needing a rule of its own."
  (declare (type food f))
  (if (plusp (food-initial f))
      (* (food-r f)
         (sqrt (clampf (/ (food-amount f) (food-initial f)) 0.0f0 1.0f0)))
      0.0f0))

;;; --------------------------------------------------------------------
;;; Colony (§3.10, §3.12)
;;; --------------------------------------------------------------------

(defstruct (colony (:constructor %make-colony))
  (id 0 :type fixnum)
  (name "" :type string)
  (nest-x 0.0f0 :type f32) (nest-y 0.0f0 :type f32) (nest-r 0.02f0 :type f32)
  (nest-body 0 :type fixnum)
  ;; One trail field per colony, never a global one (§3.12).  M1 runs a
  ;; single colony so ε never fires, but the indirection is free now and
  ;; unaddable later without touching every line that reads a pheromone.
  (field nil :type (or null field))
  (stock 0.0f0 :type f32)               ; nest food store
  ;; What the renderer's stock gauge treats as "full".  Display only:
  ;; stock has no natural ceiling, so the starting value is the only
  ;; honest reference point there is.
  (stock-ref 1.0f0 :type f32)
  (capacity 2000 :type fixnum)          ; upper bound on live workers
  (population 0 :type fixnum)
  (born 0 :type fixnum)
  (died 0 :type fixnum)
  (next-id 0 :type (unsigned-byte 32))  ; stable per-ant RNG keys
  ;; Brood accumulates fractionally between colony ticks; without this a
  ;; birth rate below one worker per tick would round to zero for ever and
  ;; a small colony could never grow.
  (brood 0.0f0 :type f32))

(defun colony-alive-p (c)
  (declare (type colony c))
  (plusp (colony-population c)))

;;; --------------------------------------------------------------------
;;; World
;;; --------------------------------------------------------------------

(defstruct (world (:constructor %make-world))
  (width 1.0f0 :type f32)
  (height 1.0f0 :type f32)
  (bodies nil :type (or null bodies))
  (ants nil :type (or null ants))
  (colonies '() :type list)
  (foods '() :type list)
  (obstacles '() :type list)
  (seed +default-seed+ :type (unsigned-byte 32))
  ;; Multi-rate clocks (§4.3).  The motion tick is the master count and
  ;; the others are derived from it, so there is exactly one notion of
  ;; "when" in the system and nothing can drift out of step.
  (tick 0 :type (unsigned-byte 32))
  (pheromone-every 20 :type fixnum)     ; 20 Hz motion -> 1 Hz pheromone
  (colony-every 1200 :type fixnum))     ; -> 1/min

(defun world-seconds (w)
  (declare (type world w))
  (* (world-tick w) *motion-dt*))

(defun make-world (&key (width 1.0f0) (height 1.0f0) (capacity 4000)
                        (seed +default-seed+))
  (let ((w (%make-world
            :width width :height height :seed seed
            :bodies (make-bodies capacity :cell 0.05f0
                                          :width width :height height)
            ;; The body table also holds corpses, food and nest entrances,
            ;; so it is sized the same as the ant table and then some —
            ;; corpses accumulate and are never reclaimed (§3.11).
            :ants (make-ants capacity)
            :pheromone-every (max 1 (round *pheromone-dt* *motion-dt*))
            :colony-every (max 1 (round *colony-dt* *motion-dt*)))))
    w))

(defun add-obstacle (w coords)
  "Add a polygon obstacle.  It is rasterized into every existing colony's
field, so obstacles must be added before colonies or the mask is wrong —
which MAKE-COLONY handles by rasterizing what is already there."
  (declare (type world w))
  (let ((p (make-polygon coords)))
    (push p (world-obstacles w))
    (dolist (c (world-colonies w))
      (field-rasterize-polygon! (colony-field c) p))
    p))

(defun add-food (w x y r amount &key (quality 1.0f0) (renew 0.0f0))
  (declare (type world w))
  (let* ((x (float x 1.0f0)) (y (float y 1.0f0)) (r (float r 1.0f0))
         (body (bodies-alloc (world-bodies w) x y r +body-food+))
         (f (%make-food :body body :x x :y y :r r
                        :amount (float amount 1.0f0)
                        :initial (float amount 1.0f0)
                        :quality (float quality 1.0f0)
                        :renew (float renew 1.0f0))))
    (push f (world-foods w))
    f))

(defun add-colony (w &key (name "colony") nest-x nest-y (nest-r 0.02f0)
                          (capacity 2000) (stock 100.0f0))
  (declare (type world w))
  (let* ((x (float nest-x 1.0f0)) (y (float nest-y 1.0f0))
         (r (float nest-r 1.0f0))
         (f (make-field :width (world-width w) :height (world-height w)))
         (c (%make-colony :id (length (world-colonies w))
                          :name name
                          :nest-x x :nest-y y :nest-r r
                          ;; non-blocking: a wall here would seal the
                          ;; colony in (§3.11)
                          :nest-body (bodies-alloc (world-bodies w) x y r
                                                   +body-nest+)
                          :field f
                          :capacity capacity
                          :stock (float stock 1.0f0)
                          :stock-ref (max 1.0f0 (float stock 1.0f0)))))
    ;; obstacles already in the world have to be in this field's mask
    (dolist (p (world-obstacles w))
      (field-rasterize-polygon! f p))
    (setf (world-colonies w) (append (world-colonies w) (list c)))
    c))

(defun world-food-at (w x y)
  "The food source whose disc contains (X, Y), or NIL.  Linear over the
source list, which is correct while a scenario has a handful of them; a
scene with hundreds would want the spatial hash."
  (declare (type world w) (type f32 x y))
  (dolist (f (world-foods w))
    (unless (food-empty-p f)
      (let ((dx (- x (food-x f))) (dy (- y (food-y f))))
        ;; the *current* radius, so an ant has to reach the shrinking pile
        ;; rather than the space it used to occupy
        (when (<= (+ (* dx dx) (* dy dy))
                  (let ((rr (+ (food-current-radius f) *ant-radius* 0.001f0)))
                    (* rr rr)))
          (return f))))))
