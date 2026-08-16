;;;; world/bodies.lisp — the body table and the one non-overlap rule (§3.11).
;;;;
;;;; One struct-of-arrays table covering ants, corpses, food sources and
;;;; nest entrances, because §3.11's rule is one rule:
;;;;
;;;;     No two blocking bodies may overlap.
;;;;
;;;; That single constraint buys ant-ant collision, ant-terrain collision,
;;;; crowding and queueing at food, congestion on a busy trail, and
;;;; corpses that genuinely get in the way — from one code path rather
;;;; than four subsystems that interact badly at the seams.
;;;;
;;;; An ant indexes into this table rather than duplicating its position,
;;;; so the collision sweep walks one contiguous array.  A corpse is a
;;;; body whose ant slot has been freed.

(in-package #:antsim)

(defconstant +body-ant+ 0)
(defconstant +body-corpse+ 1)
(defconstant +body-food+ 2)
(defconstant +body-nest+ 3)
(defconstant +body-resting+ 4
  "An ant that is *inside* the nest rather than standing in its doorway.

The nest in this model is a disc a couple of centimetres across, and a
mature colony has hundreds of ants resting in it at once — which cannot
be true of a disc that small, because the real thing is a chamber system
going down.  What the disc represents is the door.  Modelling the ants
behind it as blocking discs on the surface puts the whole resting
population in the doorway, where it obstructs its own foragers and draws
as a crowd many times the size of the nest.

So a resting ant keeps its body — it still has a position, and the
renderer still draws it — but stops colliding, exactly as the nest
entrance itself does and for the same reason (see BODY-KIND-BLOCKING-P):
sealing a colony inside its own front door is an artefact of a
two-dimensional simplification, not a fact about ants.")
(defconstant +body-free+ 255)

(declaim (inline body-kind-blocking-p body-kind-movable-p))

(defun body-kind-blocking-p (kind)
  "The nest entrance is the deliberate exception (§3.11): making it
blocking would seal the colony in.  It is a trigger, not a wall."
  (declare (type (unsigned-byte 8) kind))
  (or (= kind +body-ant+) (= kind +body-corpse+) (= kind +body-food+)))

(defun body-kind-movable-p (kind)
  "Corpses are pushable — they are inert, not anchored.  Food sources and
nest entrances are fixed points in the scenario.

A resting ant is movable but not blocking, and the pair of predicates
has to be read that way round: it takes no part in ant-ant contact,
because the nest it is in is a chamber system and not a patch of ground
(see +BODY-RESTING+), but it is still *somewhere*, so terrain still
applies to it.  Exempting it from both was a real bug and the wall
regression test caught it — an ant that collides with nothing walks
through obstacles."
  (declare (type (unsigned-byte 8) kind))
  (or (= kind +body-ant+) (= kind +body-corpse+) (= kind +body-resting+)))

(defstruct (bodies (:constructor %make-bodies))
  (n 0 :type fixnum)                    ; high-water mark, not live count
  (capacity 0 :type fixnum)
  (x nil :type (or null f32v))
  (y nil :type (or null f32v))
  (r nil :type (or null f32v))
  (kind nil :type (or null u8v))
  ;; Jacobi correction buffers (§3.11): every overlap writes here, and the
  ;; buffer is applied after the sweep.  Pushing bodies apart as pairs are
  ;; found would be Gauss-Seidel — order-dependent, and therefore a
  ;; determinism bug that only shows up when the thread count changes.
  (cx nil :type (or null f32v))
  (cy nil :type (or null f32v))
  (hash nil :type (or null shash))
  (free nil :type (or null fixv))       ; free-list stack
  (nfree 0 :type fixnum)
  ;; Largest radius in the table.  The broad-phase query radius has to be
  ;; (own radius + largest other radius), because a big body overlaps a
  ;; small one from further away than the small one's own reach.  Guessing
  ;; a fixed margin here is a silent correctness bug: a 3 cm food source
  ;; and a 2.5 mm ant overlap out to 3.25 cm, and a query that only looked
  ;; 2.25 cm never saw the contact at all.  Bodies then jammed in a ring
  ;; around the source that no amount of relaxation could clear.
  (max-r 0.0f0 :type f32))

(defun make-bodies (capacity &key (cell 0.05f0) (width 2.0f0) (height 2.0f0)
                                  (origin-x 0.0f0) (origin-y 0.0f0))
  (let ((b (%make-bodies
            :capacity capacity
            :x (mkf32 capacity) :y (mkf32 capacity) :r (mkf32 capacity)
            :kind (mku8 capacity +body-free+)
            :cx (mkf32 capacity) :cy (mkf32 capacity)
            :free (mkfix capacity)
            :hash (make-shash :cell cell :width width :height height
                              :origin-x origin-x :origin-y origin-y
                              :capacity capacity))))
    b))

(defun bodies-alloc (b x y r kind)
  "Claim a slot.  Reuses a freed one if there is one, so a colony that
churns through workers does not grow the table for ever.  Returns the
index, or NIL when the table is full — full is a legitimate state (§3.10
caps the population), not an error."
  (declare (type bodies b) (type f32 x y r) (type (unsigned-byte 8) kind))
  (let ((i (cond ((plusp (bodies-nfree b))
                  (decf (bodies-nfree b))
                  (aref (bodies-free b) (bodies-nfree b)))
                 ((< (bodies-n b) (bodies-capacity b))
                  (prog1 (bodies-n b) (incf (bodies-n b))))
                 (t nil))))
    (when i
      (setf (aref (bodies-x b) i) x
            (aref (bodies-y b) i) y
            (aref (bodies-r b) i) r
            (aref (bodies-kind b) i) kind)
      ;; Monotone: freeing a body never shrinks this back.  A stale-high
      ;; max only widens the broad-phase query, which costs a little time
      ;; and cannot miss a contact — the direction to be wrong in.
      (setf (bodies-max-r b) (max (bodies-max-r b) r))
      i)))

(defun bodies-free! (b i)
  "Release a slot.  The free list is a stack, so slot reuse order is a
pure function of the allocation history and nothing else."
  (declare (type bodies b) (type fixnum i))
  (setf (aref (bodies-kind b) i) +body-free+
        (aref (bodies-r b) i) 0.0f0)
  (setf (aref (bodies-free b) (bodies-nfree b)) i)
  (incf (bodies-nfree b))
  (values))

(defun bodies-become-corpse! (b i)
  "An ant that dies leaves its body where it fell (§3.11).  Nothing
removes it, because removal is a behaviour the colony does not have yet —
necrophoresis is M4.  Corpses accumulating and cluttering the approaches
to a busy nest is an honest statement of what the colony cannot do, not a
leak."
  (declare (type bodies b) (type fixnum i))
  (setf (aref (bodies-kind b) i) +body-corpse+)
  (values))

(defun bodies-rebuild-hash! (b)
  (declare (type bodies b))
  (shash-build (bodies-hash b) (bodies-x b) (bodies-y b) (bodies-n b))
  (values))

(defun bodies-resolve! (b polygons &key (iterations *relax-iterations*))
  "Enforce the non-overlap rule, Jacobi style.

Each body computes its *own* correction from every neighbour and writes
only to its own slot.  The obvious alternative — find a pair, push both
apart — halves the work and is wrong twice over: it is Gauss-Seidel, so
the result depends on the order pairs are visited, and it writes to a
body outside the range the current worker owns, so it cannot be threaded
by the fixed partition of §4.5 at all.  Computing each pair twice is the
price of both determinism and parallelism, and it is cheap.

The constraint is soft (§8): a fixed iteration count bounds residual
overlap rather than eliminating it.  Returns the number of body pairs
still overlapping by more than *relax-slop*, which is what the acceptance
row measures."
  (declare (type bodies b) (type list polygons) (type fixnum iterations)
           (optimize (speed 3) (safety 1)))
  (let ((xs (bodies-x b)) (ys (bodies-y b)) (rs (bodies-r b))
        (kinds (bodies-kind b))
        (cxs (bodies-cx b)) (cys (bodies-cy b))
        (n (bodies-n b))
        (hash (bodies-hash b))
        (slop *relax-slop*)
        (maxr (bodies-max-r b)))
    (declare (type f32v xs ys rs cxs cys) (type u8v kinds)
             (type fixnum n) (type f32 slop maxr))
    (dotimes (iter iterations)
      (bodies-rebuild-hash! b)
      (fill cxs 0.0f0)
      (fill cys 0.0f0)
      (dotimes (i n)
        (let ((ki (aref kinds i)))
          (when (body-kind-movable-p ki)
            (let ((xi (aref xs i)) (yi (aref ys i)) (ri (aref rs i))
                  (dx 0.0f0) (dy 0.0f0) (deepest 0.0f0))
              (declare (type f32 xi yi ri dx dy deepest))
              ;; disc against disc — skipped entirely for a body that
              ;; blocks nothing, which still falls through to terrain below
              (when (body-kind-blocking-p ki)
               (do-shash-neighbours (j hash xi yi (+ ri maxr))
                (let ((jj (the fixnum j)))
                  (unless (= jj i)
                    (let ((kj (aref kinds jj)))
                      (when (body-kind-blocking-p kj)
                        (let* ((ex (- xi (aref xs jj)))
                               (ey (- yi (aref ys jj)))
                               (sum (+ ri (aref rs jj)))
                               (d2 (+ (* ex ex) (* ey ey))))
                          (declare (type f32 ex ey sum d2))
                          (when (< d2 (* sum sum))
                            (let ((d (sqrt (max d2 1.0f-14))))
                              (declare (type f32 d))
                              ;; An immovable neighbour takes none of the
                              ;; correction, so this body takes all of it.
                              (let* ((share (if (body-kind-movable-p kj)
                                                0.5f0 1.0f0))
                                     (mag (* share (+ (- sum d) slop))))
                                (declare (type f32 share mag))
                                (when (> mag deepest)
                                  (setf deepest mag)
                                  (if (> d 1.0f-7)
                                      (setf dx (* (/ ex d) mag)
                                            dy (* (/ ey d) mag))
                                      ;; Exactly concentric, so the centre
                                      ;; difference gives no direction.
                                      ;; Pick one from a hash of the pair:
                                      ;; reproducible, and — the part that
                                      ;; matters — *isotropic*.
                                      ;;
                                      ;; This used to separate along the x
                                      ;; axis alone, which was invisible
                                      ;; until newborns arrived: they all
                                      ;; spawn on the nest centre, so every
                                      ;; pair of them was concentric, and a
                                      ;; newborn's index is higher than its
                                      ;; neighbours' — so all of them were
                                      ;; pushed the *same* way and shot out
                                      ;; of the nest in a line to the left.
                                      (let* ((ang (* 6.2831855f0
                                                     (rnd01 (min i jj)
                                                            (max i jj) 77)))
                                             (sgn (if (< i jj) 1.0f0 -1.0f0)))
                                        (setf dx (* sgn mag (cos ang))
                                              dy (* sgn mag (sin ang))))))))))))))))
              ;; NOTE the loop above assigns rather than accumulates: each
              ;; body resolves its single *deepest* overlap per iteration.
              ;; That is max projection, and it is chosen for one property
              ;; — it is monotone.  The worst overlap a body has strictly
              ;; decreases, so the relaxation cannot reach a fixed point
              ;; that still contains overlaps.
              ;;
              ;; A summed or averaged correction is the obvious
              ;; alternative and both were tried.  Neither comparison is
              ;; quoted here, because all of those measurements were taken
              ;; while the broad-phase query radius was wrong (see MAX-R
              ;; above) and were therefore measuring undetected contacts
              ;; rather than the scheme.  The lesson worth keeping is that
              ;; one: a relaxation that stalls is far more likely to be
              ;; missing constraints than to be failing to satisfy them,
              ;; and the missing-constraint bug is invisible from inside
              ;; the solver.
              ;;
              ;; Measured after the fix, on 120 ants piled inside a 3 cm
              ;; food disc — much worse than anything the sim produces:
              ;; 64 overlapping pairs left at 60 iterations, and 0 from
              ;; 120 onward.  *relax-iterations* is 3 because a tick only
              ;; ever has to clean up one tick of movement.
              ;; disc against terrain
              (dolist (p polygons)
                (multiple-value-bind (px py)
                    (disc-polygon-correction p (+ xi dx) (+ yi dy) ri)
                  (incf dx px)
                  (incf dy py)))
              (setf (aref cxs i) dx (aref cys i) dy)))))
      ;; apply the whole buffer at once — this is the Jacobi step
      (dotimes (i n)
        (incf (aref xs i) (aref cxs i))
        (incf (aref ys i) (aref cys i))))
    ;; report what is left
    (bodies-rebuild-hash! b)
    (let ((remaining 0))
      (declare (type fixnum remaining))
      (dotimes (i n)
        (when (body-kind-blocking-p (aref kinds i))
          (let ((xi (aref xs i)) (yi (aref ys i)) (ri (aref rs i)))
            (do-shash-neighbours (j hash xi yi (+ ri maxr))
              (let ((jj (the fixnum j)))
                (when (and (> jj i) (body-kind-blocking-p (aref kinds jj)))
                  (let* ((ex (- xi (aref xs jj)))
                         (ey (- yi (aref ys jj)))
                         (sum (+ ri (aref rs jj)))
                         (d2 (+ (* ex ex) (* ey ey))))
                    (when (< d2 (* (- sum slop) (- sum slop)))
                      (incf remaining)))))))))
      remaining)))
