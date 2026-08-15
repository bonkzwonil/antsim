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
(defconstant +stream-exit+ 5
  "Scatter on the bearing an ant sets off from the nest.

Its own stream, and it has to be.  The first version drew this from
+STREAM-LEAVE+, which is the stream the *decision* to leave was just
taken from — and a departure only happens when that draw came out below
*leave-probability*, about 0.005.  RND-NORMAL is Box-Muller, so it feeds
that same u1 into sqrt(-2 ln u1): conditioning on u1 < 0.005 forces the
magnitude above 3.2 sigma every single time.  Every ant left on a wild
angle, deterministically.

Reusing a stream after conditioning on it is the one way a counter-based
RNG can still surprise you, because the draws look independent and are
not.  One stream, one question.")

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
      ;; Scattered across the nest disc rather than all on its centre.
      ;; Spawning every worker at one point leaves the collision solver
      ;; with a pile of exactly concentric discs — a degenerate case it
      ;; can only resolve by tie-break, and one that a colony hits on
      ;; every single birth.  SQRT of the radial draw keeps the scatter
      ;; uniform over the disc rather than bunched at the middle.
      (let* ((id (colony-next-id c))
             (seed (world-seed w))
             (ang (* 6.2831855f0 (rnd01 id 0 92 seed)))
             (rad (* (colony-nest-r c) (sqrt (rnd01 id 0 93 seed))))
             (sx (+ (colony-nest-x c) (* rad (cos ang))))
             (sy (+ (colony-nest-y c) (* rad (sin ang))))
             (bi (bodies-alloc b sx sy *ant-radius* +body-ant+)))
        (cond
          ((null bi) (ants-free! a i) nil)
          (t
           (setf (aref (ants-id a) i) id
                 (aref (ants-body a) i) bi
                 (aref (ants-colony a) i) (colony-id c)
                 (aref (ants-state a) i) +ant-in-nest+
                 (aref (ants-heading a) i)
                 (* 6.2831855f0 (rnd01 id 0 91 seed))
                 (aref (ants-crop a) i) 0.0f0
                 (aref (ants-load-quality a) i) 0.0f0
                 (aref (ants-energy a) i) 1.0f0
                 (aref (ants-age a) i) 0
                 ;; must match the body, or the first path-integration
                 ;; pass reads a displacement from the origin
                 (aref (ants-px a) i) sx
                 (aref (ants-py a) i) sy
                 (aref (ants-trailed a) i) 0.0f0
                 ;; A newborn has no route to be faithful to, so its exit
                 ;; bearing is simply random — which is what makes the
                 ;; naive ants the colony's explorers (§3.4).
                 (aref (ants-exit a) i)
                 (* 6.2831855f0 (rnd01 id 0 93 seed))
                 ;; and the home vector is the way back from where it
                 ;; actually is, which is not quite the nest centre
                 (aref (ants-hvx a) i) (- (colony-nest-x c) sx)
                 (aref (ants-hvy a) i) (- (colony-nest-y c) sy))
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

(declaim (inline blocked-factor))
(defun blocked-factor (f x y avoid)
  "1.0 where an antenna is over open ground, (1 - AVOID) where it is over
terrain.  At AVOID = 1 a walled direction is never chosen; at 0 this is
exactly the behaviour before ants could feel walls at all, which is what
makes the change measurable rather than merely asserted."
  (declare (type field f) (type f32 x y avoid)
           (optimize (speed 3) (safety 0)))
  (if (field-blocked-p f x y) (- 1.0f0 avoid) 1.0f0))

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
         ;; Feel for terrain with the same three antennal points (§3.2).
         ;;
         ;; An ant that cannot tell a wall is there until it has walked
         ;; into it does two wrong things at once.  It keeps choosing the
         ;; heading that put it there, so it presses against the surface
         ;; tick after tick; and because the collision pass only removes
         ;; the component *into* the wall, what survives is the component
         ;; *along* it — so it slides, deposits while sliding (deposition
         ;; counts attempted motion), and lays a trail down the wall that
         ;; then recruits others onto the same surface.  A route bent
         ;; along an obstacle edge, with corpses on it, is what that looks
         ;; like from the window.
         ;;
         ;; So a direction whose sample point is inside terrain is simply
         ;; not chosen.  The mask is already there — the field carries it
         ;; for §3.3, since a blocked cell cannot hold pheromone — and the
         ;; sample points are already computed, so this costs three array
         ;; reads and no new sense.  It is also the right mechanism:
         ;; antennal contact is how a real ant learns a wall is in front
         ;; of it, and thigmotaxis is a documented behaviour rather than a
         ;; convenience.
         (fld (colony-field (nth colony-id (world-colonies w))))
         (avoid *obstacle-avoidance*)
         (bl (blocked-factor fld (+ x (* off (cos hl))) (+ y (* off (sin hl)))
                             avoid))
         (bc (blocked-factor fld (+ x (* off (cos heading)))
                             (+ y (* off (sin heading))) avoid))
         (br (blocked-factor fld (+ x (* off (cos hr))) (+ y (* off (sin hr)))
                             avoid))
         (wl (* bl (choice-weight (+ k cl) n)))
         (wc (* bc (choice-weight (+ k cc) n)))
         (wr (* br (choice-weight (+ k cr) n)))
         ;; All three walled in — a corner.  Fall back to the unweighted
         ;; choice rather than dividing by zero; the collision pass will
         ;; get the ant out, and refusing to choose at all would freeze it.
         (total (if (> (+ wl wc wr) 1.0f-12)
                    (+ wl wc wr)
                    (progn (setf wl 1.0f0 wc 1.0f0 wr 1.0f0) 3.0f0)))
         (u (* (rnd01 id tick +stream-choice+ (world-seed w)) total)))
    (declare (type f32 spread off n k hl hr cl cc cr wl wc wr total u))
    ;; Second value: how strongly this ant can smell a trail at all,
    ;; as C/(k+C) of the best sensor — 0 in clean ground, approaching 1
    ;; on a saturated road.  The caller uses it to decide how *hard* to
    ;; turn, which is a separate question from which way (see
    ;; *trail-turn-gain*).
    (let ((best (max cl (max cc cr))))
      (declare (type f32 best))
      (values
       ;; 1. the stochastic choice, which is the model proper
       (cond ((< u wl) -1.0f0)
             ((< u (+ wl wc)) 0.0f0)
             (t 1.0f0))
       ;; 2. how strongly a trail is present at all, 0..1
       (/ best (+ k best))
       ;; 3. the signed left/right imbalance, -1..1 — tropotaxis.  An ant
       ;; centred on a trail gets ~0 from this and holds its line; one
       ;; drifting off the edge gets a large correction *proportional to
       ;; how far off it is*.  That is what a fixed-size turn cannot do,
       ;; and why turning harder alone made things worse past a point:
       ;; bang-bang steering oscillates across the very trail it is
       ;; trying to hold.
       (/ (- wr wl) total)))))

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
             ;; Whether to set out, and the bar for doing so, both move
             ;; with how hungry the colony is (COLONY-FORAGE-URGENCY).  A
             ;; nest with a full larder trickles foragers out; one with an
             ;; empty larder turns itself out of doors, and accepts ants
             ;; with far less in reserve, because the alternative is to
             ;; lie down and starve with the door shut.
             (when (and (> (aref (ants-energy a) i) (colony-energy-threshold c))
                        (< (rnd01 id tick +stream-leave+ seed)
                           (colony-leave-probability c)))
               (setf (aref (ants-state a) i) +ant-outbound+
                     ;; Set off along the bearing this ant came home on,
                     ;; scattered (§3.4).
                     ;;
                     ;; Departure used not to set a heading at all, and
                     ;; the omission was not neutral — it was close to
                     ;; the worst possible choice.  A returning ant
                     ;; steers *at* the nest, so the heading it carried
                     ;; into the nest pointed inward; keeping it meant
                     ;; the ant walked out through the entrance and
                     ;; straight on, away from everything it knew.
                     ;; Measured over 613 departures on an established
                     ;; trail: 65% left within 30 degrees of exactly
                     ;; opposite the source, and not one of them left
                     ;; towards it.  Reported from the window as ants
                     ;; "wandering off with no plan", which was generous.
                     (aref (ants-heading a) i)
                     (wrap-angle
                      (+ (aref (ants-exit a) i)
                         (* *nest-exit-scatter*
                            (rnd-normal id tick +stream-exit+ seed))))
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
                      ;; Remember where this source lies *from the nest*,
                      ;; so the ant can set off towards it again next
                      ;; time (§3.4).  The home vector points from the
                      ;; ant to the nest, so its reverse is exactly the
                      ;; nest-to-food bearing the ant's own path
                      ;; integrator believes in — no new sense and no new
                      ;; state, just a reading of something it already
                      ;; maintains.
                      ;;
                      ;; Taken here rather than at the nest door, and the
                      ;; difference is not small.  The first attempt used
                      ;; the bearing at which the ant crossed the arrival
                      ;; radius, which sounds equivalent and is not: the
                      ;; entrance is packed with resting ants, so an
                      ;; arriving forager slides around the cluster and
                      ;; comes in tangentially.  Measured, that put
                      ;; departures at a peak of about 1.5 rad off the
                      ;; source — perpendicular to it — because the crowd,
                      ;; not the route, was setting the angle.
                      (when (> (aref (ants-crop a) i) 0.0f0)
                        (setf (aref (ants-exit a) i)
                              (atan (- (aref (ants-hvy a) i))
                                    (- (aref (ants-hvx a) i)))))
                      (setf (aref (ants-state a) i) +ant-returning+)))))))

            ;; --- OUTBOUND and RETURNING ----------------------------
            (t
             (let* ((returning (= state +ant-returning+))
                    (heading (aref (ants-heading a) i))
                    (hvx (aref (ants-hvx a) i)) (hvy (aref (ants-hvy a) i))
                    ;; The choice function runs in *both* directions.  A
                    ;; returning ant is not blind to the trail — it is
                    ;; pulled home as well, and the two combine.
                    (dir 0.0f0) (smell 0.0f0) (bias 0.0f0)
                    (turn 0.0f0) (noise 0.0f0))
               (declare (type f32 heading hvx hvy dir smell bias turn noise))
               (multiple-value-setq (dir smell bias)
                 (choose-turn w (colony-id c) id tick x y heading))
               ;; Two steering terms, blended by how much pheromone is
               ;; actually there.
               ;;
               ;; With none, this is the stochastic choice at a fixed turn
               ;; rate — exactly the correlated random walk of §3.2, and
               ;; search is untouched.  With a strong trail it becomes
               ;; proportional: turn hard when far off the centre line,
               ;; barely at all when on it.  Bang-bang steering could only
               ;; be made stronger by turning harder, which oscillated
               ;; across the trail and got *worse* past a gain of about 3.
               (setf turn (* *turn-rate*
                             (+ (* (- 1.0f0 smell) dir)
                                (* *trail-turn-gain* smell bias)))
                     noise (* *turn-sigma*
                              (- 1.0f0 (* *trail-noise-suppression* smell))
                              (rnd-normal id tick +stream-turn+ seed)))
               (setf heading (wrap-angle (+ heading turn noise)))
               ;; homing urge: total for a returning ant, and growing as
               ;; energy falls for an outbound one (§3.5)
               (let* ((hv-len (sqrt (+ (* hvx hvx) (* hvy hvy))))
                      ;; against the colony's threshold, so the urge to
                      ;; turn back grows from the same point at which the
                      ;; ant would actually give up
                      (ethr (colony-energy-threshold c))
                      ;; Total for a returning ant, and deliberately so.
                      ;;
                      ;; The home vector is a *vector*, not a path: it
                      ;; cannot route around anything, so a laden ant
                      ;; steers into whatever stands between it and the
                      ;; nest and slides along it.  That is visible in the
                      ;; window as a trail bent along an obstacle's edge
                      ;; and ants dying on it, and the obvious fix is to
                      ;; let the trail override the bearing — follow the
                      ;; road out, which is what a real forager has and
                      ;; what §3.4 describes.
                      ;;
                      ;; Measured, that fix is a regression.  Scaling the
                      ;; urge down by trail strength (suppression 0.9)
                      ;; delivered 262 units of food against 367 over four
                      ;; seeds — 29% *less*.  An ant that meanders along a
                      ;; trail takes longer to get home than one that
                      ;; drives at the bearing, and the collision pass
                      ;; already slides it around obstacles eventually.
                      ;; The detour is real; it is cheaper than the
                      ;; alternative tried here.
                      ;;
                      ;; Left as it is, with the flaw recorded rather than
                      ;; traded for a worse one.  A proper fix is route
                      ;; memory — the path walked out, not the trail field
                      ;; — which is §3.4's landmark system and is not M1.
                      (urge (if returning
                                1.0f0
                                (* *homing-weight-low-energy*
                                   (max 0.0f0
                                        (/ (- ethr
                                              (aref (ants-energy a) i))
                                           (max 1.0f-6 ethr)))))))
                 (declare (type f32 hv-len urge ethr))
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
                    ;;
                    ;; Laid as discrete packets a fixed *distance* apart,
                    ;; not as a mark per tick in the nearest cell.  Both
                    ;; halves of that matter.  By distance, because a
                    ;; laden ant walks slower and a per-tick deposit would
                    ;; therefore lay a heavier line for the same journey —
                    ;; strength would encode speed rather than traffic.
                    ;; As packets, because a one-cell mark is narrower
                    ;; than the span the antennae sample, so an ant could
                    ;; straddle a trail with a sensor either side of it
                    ;; and read nothing at all.
                    ;;
                    ;; MOVED is the step the ant *attempted*, read before
                    ;; BODIES-RESOLVE! has pushed it back out of whatever
                    ;; it walked into — deliberately, and note that this
                    ;; is the opposite choice from path integration, which
                    ;; uses actual net displacement (see
                    ;; PATH-INTEGRATION-STEP!).  Both are right, for
                    ;; different reasons.  Path integration is about where
                    ;; the ant *is*, so it must use where it got to.
                    ;; Deposition is about walking effort — an ant shoving
                    ;; against a crowd is still walking, gaster still
                    ;; touching down — so it uses what the ant tried to
                    ;; do.
                    ;;
                    ;; The visible consequence is at a bottleneck, where
                    ;; laden ants queue: they keep marking while barely
                    ;; advancing, so the congested spot is laid down more
                    ;; heavily than open trail, and that mark recruits
                    ;; more ants into the queue.  Congestion and
                    ;; recruitment are separate rules that know nothing
                    ;; about each other, and the geometry closes the loop.
                    (let ((moved (sqrt (+ (* (- x2 x) (- x2 x))
                                          (* (- y2 y) (- y2 y))))))
                      (declare (type f32 moved))
                      (incf (aref (ants-trailed a) i) moved)
                      (when (and (> (aref (ants-crop a) i) 0.0f0)
                                 (>= (aref (ants-load-quality a) i)
                                     *trail-quality-threshold*)
                                 (>= (aref (ants-trailed a) i)
                                     *trail-packet-spacing*))
                        ;; The packet carries what the ant would have laid
                        ;; over the distance it stands for, so the pheromone
                        ;; unit — and with it every ratio calibrated against
                        ;; *choice-k* — is untouched by the spacing.
                        (let ((n (aref (ants-trailed a) i)))
                          (declare (type f32 n))
                          (setf (aref (ants-trailed a) i) 0.0f0)
                          (field-deposit-packet!
                           (colony-field c) x2 y2
                           (* (trail-deposit-rate)
                              (aref (ants-load-quality a) i)
                              (/ n (* *walk-speed-laden* *motion-dt*)))))))
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
                    ;; The give-up threshold is the colony's, not the
                    ;; constant: a forager from a hungry nest pushes
                    ;; deeper into its reserve before turning back.
                    (cond ((world-food-at w x2 y2)
                           (setf (aref (ants-state a) i) +ant-at-food+))
                          ((< (aref (ants-energy a) i)
                              (colony-energy-threshold c))
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
  ;; A source is a blocking body, so as it is eaten its body has to shrink
  ;; with it — before the collision pass, not after, or ants spend a tick
  ;; queueing against a pile that is no longer there.
  (let ((b (world-bodies w)))
    (dolist (f (world-foods w))
      (setf (aref (bodies-r b) (food-body f)) (food-current-radius f))))
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
