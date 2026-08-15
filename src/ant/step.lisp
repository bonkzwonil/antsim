;;;; ant/step.lisp — the per-tick integrator (§3.2-§3.5).
;;;;
;;;; One rule for movement and a four-state machine on top of it.  The
;;;; ordering inside a tick is the part that has to be right: every ant
;;;; reads the *previous* pheromone tick's field and writes to a deposit
;;;; buffer, so no ant can see another ant's deposit from the same tick
;;;; and the loop is order-independent (§4.2, §4.4).

(in-package #:antsim)

;;; Stream numbers for the counter-based RNG (§4.4).  A single ant needs
;;; several independent draws per tick, and reusing one value across them
;;; would correlate behaviours that must not be correlated — a turn angle
;;; and a decision to leave the nest are not the same coin.
(defconstant +stream-choice+ 1)
(defconstant +stream-turn+ 2)
(defconstant +stream-leave+ 3)
(defconstant +stream-pi+ 4)

(declaim (inline wrap-angle angle-toward choice-weight))

(defun choice-weight (base n)
  "(k + C)^n, the Deneubourg weight.

Written with an explicit THE because EXPT of two floats has a return type
of (OR FLOAT COMPLEX) — a negative base with a fractional exponent is
complex — so SBCL boxes the result and calls generic arithmetic.  This
runs three times per ant per motion tick.  The base here is k + C with
k > 0 and C >= 0, so it is always a positive real and the assertion
holds."
  (declare (type f32 base n) (optimize (speed 3) (safety 0)))
  (the f32 (expt base n)))

(defun wrap-angle (a)
  "Wrap to (-pi, pi]."
  (declare (type f32 a) (optimize (speed 3) (safety 0)))
  (let ((x a))
    (declare (type f32 x))
    (loop while (> x 3.1415927f0) do (decf x 6.2831855f0))
    (loop while (<= x -3.1415927f0) do (incf x 6.2831855f0))
    x))

(defun angle-toward (from to weight)
  "Rotate FROM toward TO by WEIGHT of the shortest way round.

A weight rather than a switch: §3.5 wants a tired ant to *curve*
homeward, not to flip into a homing mode, because the gradual version is
what produces the looping return paths that real foragers walk."
  (declare (type f32 from to weight) (optimize (speed 3) (safety 0)))
  (wrap-angle (+ from (* weight (wrap-angle (- to from))))))

;;; --------------------------------------------------------------------
;;; Birth and death (§3.10)
;;; --------------------------------------------------------------------
;;;
;;; Here rather than in ant/state.lisp because both need colonies and the
;;; body table, and the ant table has to be defined before the world that
;;; owns one.

(defun spawn-ant (w c)
  "Add one worker to colony C, at its nest.  Returns the ant index, or
NIL if either table is full.

A newborn starts IN-NEST with full energy and a zero home vector — it is
standing on the nest, so the way home is nothing.  That is the correct
initial condition rather than merely a convenient one."
  (declare (type world w) (type colony c))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (i (ants-alloc a)))
    (when i
      (let ((bi (bodies-alloc b (colony-nest-x c) (colony-nest-y c)
                              *ant-radius* +body-ant+)))
        (cond
          ((null bi) (ants-free! a i) nil)
          (t
           (setf (aref (ants-id a) i) (colony-next-id c)
                 (aref (ants-body a) i) bi
                 (aref (ants-colony a) i) (colony-id c)
                 (aref (ants-state a) i) +ant-in-nest+
                 (aref (ants-heading a) i)
                 (* 6.2831855f0 (rnd01 (colony-next-id c) 0 91 (world-seed w)))
                 (aref (ants-crop a) i) 0.0f0
                 (aref (ants-load-quality a) i) 0.0f0
                 (aref (ants-energy a) i) 1.0f0
                 (aref (ants-age a) i) 0
                 (aref (ants-hvx a) i) 0.0f0
                 (aref (ants-hvy a) i) 0.0f0
                 ;; must match the body, or the first path-integration
                 ;; pass reads a displacement from the origin
                 (aref (ants-px a) i) (colony-nest-x c)
                 (aref (ants-py a) i) (colony-nest-y c))
           (incf (colony-next-id c))
           (incf (colony-population c))
           (incf (colony-born c))
           (incf (ants-live a))
           i))))))

(defun kill-ant (w c i)
  "The ant dies where it stands and its body becomes a corpse (§3.11).
The body slot is deliberately *not* freed: nothing removes a corpse,
because removal is a behaviour the colony does not have yet."
  (declare (type world w) (type colony c) (type fixnum i))
  (let ((a (world-ants w)))
    (bodies-become-corpse! (world-bodies w) (aref (ants-body a) i))
    (ants-free! a i)
    (decf (colony-population c))
    (incf (colony-died c)))
  (values))

;;; --------------------------------------------------------------------
;;; Sensing and the choice function (§3.3)
;;; --------------------------------------------------------------------

(defun sense-at (w colony-id x y)
  "Effective trail concentration at a point, as this colony perceives it:

    C_effective = C_own + ε · Σ C_foreign        (§3.12)

M1 runs one colony, so the sum is empty and this is just C_own — but the
indirection costs nothing now and cannot be added later without touching
every line that reads a pheromone."
  (declare (type world w) (type fixnum colony-id) (type f32 x y)
           (optimize (speed 3) (safety 1)))
  (let ((own 0.0f0) (foreign 0.0f0))
    (declare (type f32 own foreign))
    (dolist (c (world-colonies w))
      (let ((v (field-at (colony-field c) x y)))
        (if (= (colony-id c) colony-id)
            (setf own v)
            (incf foreign v))))
    (+ own (* *choice-eavesdrop* foreign))))

(defun choose-turn (w colony-id id tick x y heading)
  "Sample three headings through the antennae and pick one, with the
Deneubourg weighting

    P(i) = (k + C_i)^n / Σ (k + C_j)^n

Returns a *direction* — -1, 0 or +1 — not an angle.  The caller turns by
*turn-rate*, which is how fast the ant can turn, while *sensor-spread*
here is only where its antennae are.  Those are different quantities and
using the spread as the turn makes an ant snap through 30 degrees every
50 ms (see *turn-rate*).

This is the heart of the model and it is also, deliberately, the whole
of the movement rule.  With no pheromone anywhere every weight is k^n,
the three options are equally likely, and what comes out is the
correlated random walk of §3.2 — so there is no trail-following mode to
switch into and no switching logic to get wrong (§3.5)."
  (declare (type world w) (type fixnum colony-id)
           (type (unsigned-byte 32) id tick) (type f32 x y heading)
           (optimize (speed 3) (safety 1)))
  (let* ((spread *sensor-spread*)
         (off *sensor-offset*)
         (n *choice-n*)
         (k *choice-k*)
         (hl (- heading spread))
         (hr (+ heading spread))
         (cl (sense-at w colony-id (+ x (* off (cos hl))) (+ y (* off (sin hl)))))
         (cc (sense-at w colony-id (+ x (* off (cos heading)))
                       (+ y (* off (sin heading)))))
         (cr (sense-at w colony-id (+ x (* off (cos hr))) (+ y (* off (sin hr)))))
         (wl (choice-weight (+ k cl) n))
         (wc (choice-weight (+ k cc) n))
         (wr (choice-weight (+ k cr) n))
         (total (+ wl wc wr))
         (u (* (rnd01 id tick +stream-choice+ (world-seed w)) total)))
    (declare (type f32 spread off n k hl hr cl cc cr wl wc wr total u))
    (cond ((< u wl) -1.0f0)
          ((< u (+ wl wc)) 0.0f0)
          (t 1.0f0))))

;;; --------------------------------------------------------------------
;;; The tick
;;; --------------------------------------------------------------------

(defun ant-motion-step! (w)
  "Move every live ant one motion tick, and run its state machine."
  (declare (type world w))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (tick (world-tick w))
         (seed (world-seed w))
         (bxs (bodies-x b)) (bys (bodies-y b))
         (colonies (coerce (world-colonies w) 'vector))
         (dt *motion-dt*)
         (wid (world-width w)) (hei (world-height w)))
    (declare (type f32 dt wid hei))
    (dotimes (i (ants-n a))
      (when (ant-live-p a i)
        (let* ((c (aref colonies (aref (ants-colony a) i)))
               (id (aref (ants-id a) i))
               (bi (aref (ants-body a) i))
               (state (aref (ants-state a) i))
               (x (aref bxs bi)) (y (aref bys bi))
               (energy (aref (ants-energy a) i)))
          (declare (type f32 x y energy))

          ;; where the tick started, for path integration
          (setf (aref (ants-px a) i) x
                (aref (ants-py a) i) y)

          ;; --- age and metabolism ------------------------------------
          (incf (aref (ants-age a) i))
          (decf energy (if (= state +ant-in-nest+)
                           *energy-drain-resting*
                           *energy-drain-walking*))

          ;; --- death (§3.5) ------------------------------------------
          (if (or (<= energy 0.0f0)
                  (>= (aref (ants-age a) i) *max-age-ticks*))
              (progn (setf (aref (ants-energy a) i) 0.0f0)
                     (kill-ant w c i))
              (progn
          (setf (aref (ants-energy a) i) energy)

          (cond
            ;; --- IN-NEST -------------------------------------------
            ((= state +ant-in-nest+)
             ;; A resting ant keeps walking in until it is actually at the
             ;; nest, slowly.
             ;;
             ;; Without this, "in nest" meant "stopped the instant it
             ;; crossed the arrival radius", so the resting population sat
             ;; in a shell 6 cm out while the nest disc itself stayed
             ;; empty — and an ant that then set out was OUTBOUND while
             ;; still inside the ring, which is exactly how it looked in
             ;; the window.  Arrival is a threshold for *unloading*; it
             ;; was never meant to be where the ant stops.
             ;;
             ;; The non-overlap rule does the rest: they cannot all reach
             ;; the centre, so they pack into a cluster around the
             ;; entrance, which is what a nest should look like.
             (let* ((ndx (- (colony-nest-x c) x))
                    (ndy (- (colony-nest-y c) y))
                    (nd (sqrt (+ (* ndx ndx) (* ndy ndy)))))
               (declare (type f32 ndx ndy nd))
               (when (> nd (colony-nest-r c))
                 (let ((step (min (* 0.5f0 *walk-speed* dt)
                                  (- nd (colony-nest-r c)))))
                   (declare (type f32 step))
                   (setf (aref bxs bi) (+ x (* (/ ndx nd) step))
                         (aref bys bi) (+ y (* (/ ndy nd) step))))))
             ;; The nest is a resource, not a waypoint (§3.5): a resting
             ;; ant is fed from the colony's stock.
             (let ((want (min (- 1.0f0 energy) *nest-feed-rate*)))
               (when (and (> want 0.0f0) (> (colony-stock c) want))
                 (decf (colony-stock c) want)
                 (incf (aref (ants-energy a) i) want)))
             (when (and (> (aref (ants-energy a) i) *energy-return-threshold*)
                        (< (rnd01 id tick +stream-leave+ seed)
                           *leave-probability*))
               (setf (aref (ants-state a) i) +ant-outbound+
                     ;; Set the home vector to the *actual* way back, not
                     ;; to zero.
                     ;;
                     ;; Zeroing assumes the ant is standing on the nest,
                     ;; and it is not: a resting ant is still a blocking
                     ;; body, the crowd at a busy nest shoves it, and path
                     ;; integration faithfully records that it has drifted.
                     ;; Zeroing on departure threw that away, so the ant
                     ;; adopted wherever it had been pushed to as home.
                     ;; It would then forage, come back to that false
                     ;; origin, find its home vector reading zero — and
                     ;; sit there with a full crop it could not unload,
                     ;; jiggling, nowhere near the nest.  Reported from
                     ;; the window, where it is obvious and where no
                     ;; aggregate statistic showed it.
                     (aref (ants-hvx a) i) (- (colony-nest-x c) x)
                     (aref (ants-hvy a) i) (- (colony-nest-y c) y))))

            ;; --- AT-FOOD -------------------------------------------
            ((= state +ant-at-food+)
             (let ((f (world-food-at w x y)))
               (cond
                 ((null f)                    ; source gone or drifted off
                  (setf (aref (ants-state a) i) +ant-returning+))
                 (t
                  (let* ((rate (* *crop-fill-rate* (food-quality f)))
                         (take (min rate
                                    (- 1.0f0 (aref (ants-crop a) i))
                                    (food-amount f))))
                    (incf (aref (ants-crop a) i) take)
                    (decf (food-amount f) take)
                    (setf (aref (ants-load-quality a) i) (food-quality f))
                    (when (or (>= (aref (ants-crop a) i) 0.999f0)
                              (food-empty-p f))
                      (setf (aref (ants-state a) i) +ant-returning+)))))))

            ;; --- OUTBOUND and RETURNING ----------------------------
            (t
             (let* ((returning (= state +ant-returning+))
                    (heading (aref (ants-heading a) i))
                    (hvx (aref (ants-hvx a) i)) (hvy (aref (ants-hvy a) i))
                    ;; The choice function runs in *both* directions.  A
                    ;; returning ant is not blind to the trail — it is
                    ;; pulled home as well, and the two combine.
                    (turn (* *turn-rate*
                             (choose-turn w (colony-id c) id tick x y heading)))
                    (noise (* *turn-sigma*
                              (rnd-normal id tick +stream-turn+ seed))))
               (declare (type f32 heading hvx hvy turn noise))
               (setf heading (wrap-angle (+ heading turn noise)))
               ;; homing urge: total for a returning ant, and growing as
               ;; energy falls for an outbound one (§3.5)
               (let* ((hv-len (sqrt (+ (* hvx hvx) (* hvy hvy))))
                      (urge (if returning
                                1.0f0
                                (* *homing-weight-low-energy*
                                   (max 0.0f0
                                        (/ (- *energy-return-threshold*
                                              (aref (ants-energy a) i))
                                           *energy-return-threshold*))))))
                 (declare (type f32 hv-len urge))
                 (when (and (> hv-len 1.0f-4) (> urge 0.0f0))
                   (setf heading
                         (angle-toward heading (atan hvy hvx)
                                       (min 1.0f0 (/ urge (+ 1.0f0 urge)))))))
               (setf (aref (ants-heading a) i) heading)

               ;; advance
               (let* ((speed (if (> (aref (ants-crop a) i) 0.0f0)
                                 *walk-speed-laden* *walk-speed*))
                      (dx (* speed dt (cos heading)))
                      (dy (* speed dt (sin heading)))
                      (nx (clampf (+ x dx) 0.0f0 wid))
                      (ny (clampf (+ y dy) 0.0f0 hei)))
                 (declare (type f32 speed dx dy nx ny))
                 ;; Reflect off the arena edge rather than merely clamping.
                 ;; Clamping alone leaves an ant pressed against the wall
                 ;; with a heading that still points into it, so it walks
                 ;; on the spot until something else turns it.  The first
                 ;; rendered frame showed the result at a glance: every
                 ;; one of the four borders was lined with stuck ants,
                 ;; which no summary statistic had made visible.
                 (when (/= nx (+ x dx))
                   (setf heading (wrap-angle (- 3.1415927f0 heading))))
                 (when (/= ny (+ y dy))
                   (setf heading (wrap-angle (- heading))))
                 (setf (aref (ants-heading a) i) heading)
                 ;; Path integration happens in PATH-INTEGRATION-STEP!,
                 ;; after collision resolution — see the note there.
                 (setf (aref bxs bi) nx (aref bys bi) ny))

               (let ((x2 (aref bxs bi)) (y2 (aref bys bi)))
                 (declare (type f32 x2 y2))
                 (cond
                   (returning
                    ;; Deposit on the return trip, modulated by the
                    ;; quality of what is being carried — and not at all
                    ;; below the threshold (§3.3).  That switch is its own
                    ;; acceptance row: poor food is exploited but never
                    ;; recruited to.
                    (when (and (> (aref (ants-crop a) i) 0.0f0)
                               (>= (aref (ants-load-quality a) i)
                                   *trail-quality-threshold*))
                      (field-deposit! (colony-field c) x2 y2
                                      (* *trail-deposit*
                                         (aref (ants-load-quality a) i))))
                    ;; home?
                    (let ((ddx (- x2 (colony-nest-x c)))
                          (ddy (- y2 (colony-nest-y c))))
                      (when (<= (+ (* ddx ddx) (* ddy ddy))
                                (* *nest-arrival-radius* *nest-arrival-radius*))
                        (let ((load (aref (ants-crop a) i)))
                          (incf (colony-stock c) (* load (- 1.0f0 *crop-to-energy*)))
                          (setf (aref (ants-energy a) i)
                                (min 1.0f0 (+ (aref (ants-energy a) i)
                                              (* load *crop-to-energy*)))))
                        (setf (aref (ants-crop a) i) 0.0f0
                              (aref (ants-load-quality a) i) 0.0f0
                              ;; Re-fix on the nest rather than zeroing:
                              ;; arrival only means "within the arrival
                              ;; radius", which is 6 cm, so zero would
                              ;; bake that whole error into the next trip.
                              (aref (ants-hvx a) i) (- (colony-nest-x c) x2)
                              (aref (ants-hvy a) i) (- (colony-nest-y c) y2)
                              (aref (ants-state a) i) +ant-in-nest+))))
                   (t
                    ;; outbound: found food, or run low enough to turn back
                    ;; Give up at the threshold itself, not at half of it.
                    ;; The half was an unexplained extra factor, and it
                    ;; contradicted the parameter's own meaning: it left a
                    ;; forager turning for home on the last 22% of its
                    ;; reserve, which a winding return path through a
                    ;; crowd does not reliably cover.
                    (cond ((world-food-at w x2 y2)
                           (setf (aref (ants-state a) i) +ant-at-food+))
                          ((< (aref (ants-energy a) i)
                              *energy-return-threshold*)
                           (setf (aref (ants-state a) i)
                                 +ant-returning+))))
                   ))               ; cond H, let G
               ))                   ; let* C, cond-A's t clause
             )                      ; cond A
           )                        ; progn (alive branch)
         )                          ; if (dead / alive)
       )                            ; let* per-ant
     )                              ; when live
   )                                ; dotimes
    (values)))

(defun path-integration-step! (w)
  "Close the home vector over each ant's *actual* net displacement this
tick — after collision resolution, not before (§3.4).

This runs as a separate pass for a reason that was expensive to learn.
Integrating the ant's intended step instead, and treating the collision
correction as an unmodelled disturbance, sounds more faithful — being
jostled really does corrupt an insect's path integrator.  Quantitatively
it is a disaster.  The non-overlap solver nudges every ant in a crowd on
every tick, and those nudges accumulate without bound in the home vector
while the ant's own walk does not.

Measured on a 150-ant colony: ants died believing home lay a mean of
2.03 radians — 116 degrees — from where it actually was, having walked
confidently away from it until their energy ran out.  Every death in the
run was a returning ant, and none of them were lost for want of energy to
get home.

Closing over the net displacement also handles the arena boundary for
free: an ant pressed against the edge does not move, so it accumulates
nothing, where the intended step would have wound its estimate up while
it walked on the spot.

PI error is still modelled — *pi-noise* perturbs each increment — but it
is now a small, deliberate error rather than an unbounded accounting
leak."
  (declare (type world w))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (bxs (bodies-x b)) (bys (bodies-y b))
         (tick (world-tick w))
         (seed (world-seed w)))
    (dotimes (i (ants-n a))
      (when (ant-live-p a i)
        (let* ((bi (aref (ants-body a) i))
               (mx (- (aref bxs bi) (aref (ants-px a) i)))
               (my (- (aref bys bi) (aref (ants-py a) i)))
               (ex (* *pi-noise* (rnd-normal (aref (ants-id a) i) tick
                                             +stream-pi+ seed))))
          (declare (type f32 mx my ex))
          (decf (aref (ants-hvx a) i) (* mx (+ 1.0f0 ex)))
          (decf (aref (ants-hvy a) i) (* my (+ 1.0f0 ex)))))))
  (values))

(defun colony-step! (w c)
  "One colony tick: upkeep, births, deaths by starvation of the stock.

§3.10: the population is a state variable, and extinction is a legitimate
outcome rather than a bug.  Both directions come out of the same few
lines — a colony that cannot reach food pays upkeep it cannot afford,
stops producing brood, and decays."
  (declare (type world w) (type colony c))
  ;; upkeep
  (decf (colony-stock c) (* (colony-population c) *nest-upkeep*))
  (when (< (colony-stock c) 0.0f0) (setf (colony-stock c) 0.0f0))
  ;; brood.  Fractional, so a birth rate below one worker per tick still
  ;; accumulates instead of rounding to zero for ever.
  (let ((invest (* 0.1f0 (colony-stock c))))
    (decf (colony-stock c) invest)
    (incf (colony-brood c) (* *brood-per-stock* invest)))
  (loop while (and (>= (colony-brood c) 1.0f0)
                   (< (colony-population c) (colony-capacity c)))
        do (decf (colony-brood c) 1.0f0)
           (unless (spawn-ant w c) (return)))
  (values))

(defun world-step! (w)
  "One motion tick, plus whichever slower clocks fall due (§4.3)."
  (declare (type world w))
  (ant-motion-step! w)
  (bodies-resolve! (world-bodies w) (world-obstacles w))
  (path-integration-step! w)
  (incf (world-tick w))
  (when (zerop (mod (world-tick w) (world-pheromone-every w)))
    (dolist (c (world-colonies w))
      (field-step! (colony-field c) *pheromone-dt*)))
  (when (zerop (mod (world-tick w) (world-colony-every w)))
    (dolist (f (world-foods w))
      (when (plusp (food-renew f))
        (setf (food-amount f)
              (min (food-initial f) (+ (food-amount f) (food-renew f))))))
    (dolist (c (world-colonies w))
      (colony-step! w c)))
  (values))

(defun world-run! (w ticks)
  (declare (type world w) (type fixnum ticks))
  (dotimes (i ticks) (world-step! w))
  w)

(defun world-seed-population! (w c n)
  "Place the colony's starting workers (§3.10).  A starting count, not
*the* count: births and deaths run from tick one."
  (declare (type world w) (type colony c) (type fixnum n))
  (dotimes (i n) (unless (spawn-ant w c) (return)))
  (colony-population c))
