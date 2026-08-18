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

(defconstant +stream-uturn+ 7
  "Scatter on the about-face an ant makes when it loses a trail.")

(defconstant +stream-hand+ 6
  "Which way an ant turns when the way home is shut — see ANT-HANDEDNESS.

Drawn on the ant's id alone, with no tick, so it is a fixed property of
the individual rather than a per-tick coin flip.")

(defconstant +stream-lane+ 9
  "Which part of a trail's width this ant prefers — see ANT-TRAIL-OFFSET.

On the ant's id alone with no tick, exactly like +STREAM-HAND+ and
+STREAM-PACE+, and for the same reason: it is a property of the
individual, and a value re-rolled every tick would be noise on the step
rather than a trait.  The model already has noise on the step, in the
heading, where it belongs.")

(defconstant +stream-pace+ 8
  "How fast this ant walks relative to its colony — see ANT-PACE.

Its own stream, and on the ant's id alone, for the same reason
+STREAM-HAND+ is: a lifelong trait must not be re-rolled every tick, and
it must not be correlated with anything the ant decides.")

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
             ;; IN-NEST from birth, so it starts behind the door rather
             ;; than in it (see +BODY-RESTING+).
             (bi (bodies-alloc b sx sy *ant-radius*
                               (if *resting-ants-block*
                                   +body-ant+ +body-resting+))))
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
                 ;; Its own point in the tripod cycle (§5.2).  Zero would
                 ;; work and looks wrong: a cohort emerging together would
                 ;; step in unison, which is a thing ants conspicuously do
                 ;; not do, and the eye catches it immediately.  Drawn
                 ;; from the ant's id, so it costs no stream and repeats.
                 (aref (ants-gait a) i) (rnd01 id 0 94 seed)
                 (aref (ants-smelled a) i) 0.0f0
                 (aref (ants-cast a) i) 0
                 ;; It is standing in the nest, which is the one place
                 ;; this reading is legitimate.
                 (aref (ants-resolve a) i) (colony-giveup-threshold c)
                 (aref (ants-waited a) i) 0
                 ;; A newborn has no route to be faithful to, so its exit
                 ;; bearing is simply random — which is what makes the
                 ;; naive ants the colony's explorers (§3.4).
                 (aref (ants-exit a) i)
                 (* 6.2831855f0 (rnd01 id 0 93 seed))
                 ;; and the home vector is the way back from where it
                 ;; actually is, which is not quite the nest centre
                 (aref (ants-hvx a) i) (- (colony-nest-x c) sx)
                 (aref (ants-hvy a) i) (- (colony-nest-y c) sy)
                 ;; nobody has told it anything yet
                 (aref (ants-confidence a) i) 0.0f0
                 (aref (ants-dturn a) i) 0.0f0
                 (aref (ants-dcrop a) i) 0.0f0
                 (aref (ants-denergy a) i) 0.0f0
                 (aref (ants-met a) i) 0
                 (aref (ants-partner a) i) +no-ant+
                 (aref (ants-partner-ttl a) i) 0
                 (aref (ants-partner-gave a) i) 0
                 ;; and the broad phase can now find the ant from the body
                 (aref (ants-of-body a) bi) i)
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

(defconstant +bearing-step+ 0.2617994f0
  "15 degrees — the increment *homing-scan-steps* counts in.")

(declaim (inline ant-handedness))
(defun ant-handedness (id seed)
  "-1 or +1, fixed for the life of the ant: which way it goes round when
the way home is shut.

The first version derived the side from the ant's current heading, on the
argument that an ant already sliding one way should keep going.  That
reasoning is sound and the implementation of it cannot work, because the
heading is not a stable quantity to hang commitment on: an ant stalled
against a wall is laying pheromone under itself, the trail term then
steers it into its own mark, and the side derived from the heading flips
with it.  Measured, the ant oscillated between due left and due right for
20 000 ticks and travelled 12 mm.

Handedness fixes it by not depending on anything that moves.  It is drawn
from the id and the world seed only — no tick — so it is decided once,
per individual, and no feedback can reach it.  It is also the more
defensible model: lateralisation is documented in ants, including a
population-level turning bias in wall-following, and an even split here
means a colony meeting an obstacle sends ants round both ends instead of
committing all of them to one."
  (declare (type (unsigned-byte 32) id seed) (optimize (speed 3) (safety 0)))
  (if (< (rnd01 id 0 +stream-hand+ seed) 0.5f0) -1.0f0 1.0f0))

(declaim (inline ant-pace))
(defun ant-pace (id seed)
  "This ant's walking speed as a multiple of its colony's, fixed for
life: 1 +/- *SPEED-SPREAD* (§3.1).

Drawn on the id with no tick, exactly like ANT-HANDEDNESS, and for the
same two reasons.  It is a property of the individual, so re-rolling it
every tick would make it noise on the step rather than a trait — and
noise on the step is something the model already has, in the heading
(§3.2), where it belongs.  And keeping it off every stream a decision is
taken from means an ant's pace cannot become correlated with what it
decides to do.

Uniform rather than normal.  §3.1 gives the species a *range* of 1-3
cm/s and no distribution, so a range is the honest thing to sample; a
Gaussian here would be inventing a shape the source does not have, and at
this width the two are indistinguishable anyway."
  (declare (type (unsigned-byte 32) id seed) (optimize (speed 3) (safety 0)))
  (+ (- 1.0f0 *speed-spread*)
     (* 2.0f0 *speed-spread* (rnd01 id 0 +stream-pace+ seed))))

(declaim (inline ant-trail-offset))
(defun ant-trail-offset (id seed)
  "How far to one side of the trail this ant likes to walk, in metres.
Zero is the centre line.  Fixed for the life of the ant.

Implemented by sliding the ant's whole three-point sensing frame sideways
(CHOOSE-TURN), so the ant still steers to put *the ridge of the gradient*
between its antennae — it simply holds those antennae offset from its
body.  Its body therefore settles that far off the centre line, and the
equilibrium is as stable as the centred one because it is the same
equilibrium in a shifted frame.

Uniform, and a lifelong trait rather than a per-tick draw, for the
reasons given at +STREAM-LANE+ and in ANT-PACE.  It costs no per-ant
storage at all: it is derived from the id the ant already has, on a
stream of its own, which is what lets a new trait be added for the price
of one constant.

Lateralisation in ants is documented — ANT-HANDEDNESS already leans on it
— so individual variation in antennal steering is the defensible reading
rather than a convenience."
  (declare (type (unsigned-byte 32) id seed) (optimize (speed 3) (safety 0)))
  (* *trail-lane-offset* (- (* 2.0f0 (rnd01 id 0 +stream-lane+ seed)) 1.0f0)))

(defun clear-bearing (f x y bearing prefer off)
  "BEARING if an antenna held that way is over open ground, else the
nearest direction that is.

The home vector points through walls, and until now a returning ant
followed it through them: it pressed against the surface, slid along it
because the collision pass removes only the component into it, marked the
surface while sliding because deposition counts the attempted step, and
so laid a road along the obstacle that recruited outbound ants onto the
same wall.  Antennal veto in CHOOSE-TURN cannot reach that, because the
homing term overwrites the heading afterwards — the ants walking into the
wall are not choosing to.

The scan opens toward PREFER — the ant's handedness, -1 or +1 — and that
asymmetry is the whole of the edge-following.  Scanned symmetrically, an
ant meeting a wall square on finds the same deflection either way and
takes a different one every tick, so it dithers on the spot; opened to
one side, it walks the edge until the nest comes clear.  Nothing here
follows edges on purpose — it is what wanting to go home looks like when
the direct way is shut.

Beyond *homing-scan-steps* increments the ant gives up and keeps the
bearing it had.  At the default that is a right angle: parallel to a wall
square across its way, and no further.  An ant in a pocket needs to walk
*away* from the nest to get out, which a bearing cannot express however
wide the scan; that is route memory (§3.4)."
  (declare (type field f) (type f32 x y bearing prefer off)
           (optimize (speed 3) (safety 1)))
  (flet ((clear-p (ang)
           (declare (type f32 ang))
           (not (field-blocked-p f (+ x (* off (cos ang)))
                                 (+ y (* off (sin ang)))))))
    (if (clear-p bearing)
        bearing
        (let ((steps *homing-scan-steps*))
          (declare (type fixnum steps))
          ;; The whole of the preferred side before any of the other one.
          ;;
          ;; Interleaving them — trying prefer and -prefer at each
          ;; deflection in turn, which is the obvious way to find the
          ;; smallest turn — reintroduces the dithering by another route.
          ;; An ant resting on a wall bobs a couple of millimetres, that
          ;; is enough to move one antennal sample across a cell
          ;; boundary, and the ant is handed the opposite direction: a
          ;; 150-degree reversal for two millimetres of vertical noise.
          ;; Measured, it walked 8 mm in 20 000 ticks.  Committing to a
          ;; side costs a wider turn now and again and is the only
          ;; version that goes anywhere.
          (dolist (side (list prefer (- prefer)) bearing)
            (declare (type f32 side))
            (loop for s of-type fixnum from 1 to steps
                  for ang of-type f32
                    = (wrap-angle (+ bearing (* side s +bearing-step+)))
                  when (clear-p ang)
                    do (return-from clear-bearing ang)))))))

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
         ;; This ant's own place across the width of a trail
         ;; (ANT-TRAIL-OFFSET): the whole sensing frame slides sideways,
         ;; so the ant still centres the gradient's ridge between its
         ;; antennae and its *body* ends up that far off the middle.
         ;;
         ;; Without it every ant nulls the same imbalance, and nulling the
         ;; imbalance is the definition of standing on the ridge — so the
         ;; colony walked a 3 cm trail in single file down one line, with
         ;; nowhere to pass and no width for traffic to sort into.
         (lane (ant-trail-offset id (world-seed w)))
         (lx (* lane (- (sin heading)))) (ly (* lane (cos heading)))
         ;; The three antennal sample points, bound once.  Every sense
         ;; this ant has is taken at these same three places, so computing
         ;; them once is both cheaper than the copies this grew and the
         ;; only way the readings cannot drift apart from one another.
         (xl (+ x lx (* off (cos hl)))) (yl (+ y ly (* off (sin hl))))
         (xc (+ x lx (* off (cos heading)))) (yc (+ y ly (* off (sin heading))))
         (xr (+ x lx (* off (cos hr)))) (yr (+ y ly (* off (sin hr))))
         (cl (sense-at w colony-id xl yl))
         (cc (sense-at w colony-id xc yc))
         (cr (sense-at w colony-id xr yr))
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
         (bl (blocked-factor fld xl yl avoid))
         (bc (blocked-factor fld xc yc avoid))
         (br (blocked-factor fld xr yr avoid))
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
    (declare (type f32 spread off n k hl hr cl cc cr wl wc wr total u
                      lane lx ly xl yl xc yc xr yr))
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

          ;; The body kind follows the state, derived here rather than
          ;; assigned at each transition.  Set at the transitions it was
          ;; possible for the two to disagree — anything that moved an
          ;; ant between states without also moving its body left an ant
          ;; that collided with nothing and therefore walked through
          ;; walls, which is exactly what the wall regression test
          ;; caught.  One place, every tick, no way to drift.
          (setf (aref (bodies-kind (world-bodies w)) bi)
                (if (and (= state +ant-in-nest+) (not *resting-ants-block*))
                    +body-resting+
                    +body-ant+))

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
             ;; The old communal sip, kept only as the off-position of
             ;; *nest-meals-per-tick*.  Meals are served by COLONY-FEED!,
             ;; which cannot run here: this loop visits ants in table
             ;; order and cannot know which one is hungriest until it has
             ;; seen them all.
             (when (<= *nest-meals-per-tick* 0)
               (let ((want (min (- 1.0f0 energy) *nest-feed-rate*)))
                 (when (and (> want 0.0f0) (> (colony-stock c) want))
                   (decf (colony-stock c) want)
                   (incf (aref (ants-energy a) i) want))))
             ;; How long this ant has been waiting to be fed: resting,
             ;; and still under the bar it needs to set out.  Cleared the
             ;; moment it can work again, so the number always means
             ;; "unbroken ticks spent unable to leave", not a lifetime
             ;; total.
             (if (<= (aref (ants-energy a) i) (colony-energy-threshold c))
                 (let ((w0 (aref (ants-waited a) i)))
                   (declare (type (unsigned-byte 32) w0))
                   (when (< w0 4294967295) (setf (aref (ants-waited a) i) (1+ w0))))
                 (setf (aref (ants-waited a) i) 0))

             ;; Whether to set out, and the bar for doing so, both move
             ;; with how hungry the colony is (COLONY-FORAGE-URGENCY).  A
             ;; nest with a full larder trickles foragers out; one with an
             ;; empty larder turns itself out of doors, and accepts ants
             ;; with far less in reserve, because the alternative is to
             ;; lie down and starve with the door shut.
             ;; A callow worker nurses; foraging is the last job an ant
             ;; takes up (§3.5).  This is also the buffer the brood rules
             ;; cannot provide on their own: emerging is not the same
             ;; event as joining the foraging pool.
             (when (and (>= (aref (ants-age a) i) *forager-maturity-ticks*)
                        (> (aref (ants-energy a) i) (colony-energy-threshold c))
                        (< (rnd01 id tick +stream-leave+ seed)
                           (colony-leave-probability c)))
               ;; How deep this trip will dig, learnt here and carried.
               ;; An ant in the field cannot read the larder (§3.5).
               (setf (aref (ants-resolve a) i) (colony-giveup-threshold c))
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
             ;; WORLD-FOOD-NEAR, not WORLD-FOOD-AT, and the difference is
             ;; the whole of this branch's correctness.
             ;;
             ;; "Am I standing on it" is the wrong question for an ant
             ;; that is *already eating*.  A source is a blocking body
             ;; with a queue round it, a feeding ant does not hold its own
             ;; position, and the edge itself retreats as the pile is
             ;; eaten (FOOD-CURRENT-RADIUS) — so the ant is shoved off
             ;; constantly and has not thereby finished its meal.  Asking
             ;; the strict question sent it home with whatever it had:
             ;; measured, **48% of all departures from food** were ants
             ;; that had been pushed off rather than filled up, mean load
             ;; 0.63 instead of 1.0.
             ;;
             ;; Feeding from the wider radius rather than only stepping
             ;; back toward it also matters, and getting that wrong is how
             ;; this was first written: an ant that walks back but cannot
             ;; eat until it is exactly on the pile hovers at the edge
             ;; being pushed out as fast as it steps in, filling nothing,
             ;; for ever.  That is an ant circling a source it never
             ;; leaves, which is precisely the symptom.
             ;; The slack is one ant radius, not the antennal offset.  It
             ;; exists to survive being *jostled* off a pile — a couple of
             ;; millimetres — and anything wider is a quiet enlargement of
             ;; every food source in the model: more ants feed at once,
             ;; each trip takes longer, and on the §3.8 bridges that is
             ;; enough to slow the recruitment feedback below the point
             ;; where a colony commits to an arm at all.  Measured: at the
             ;; antennal offset a binary-bridge replicate finished at
             ;; 0.507, which is no choice having been made.
             (let ((f (world-food-near w x y *ant-radius*)))
               (cond
                 ((null f)
                  ;; Nothing within reach at all, so the meal really is
                  ;; over and the ant turns for home with what it has.
                  (setf (aref (ants-state a) i) +ant-returning+))
                 (t
                  ;; Shoved off the pile: walk back on, exactly as a
                  ;; resting ant walks itself into the nest (see
                  ;; +ANT-IN-NEST+ above) and for the same reason.
                  ;; Arrival is a threshold for a *transaction*, never a
                  ;; place the ant stops caring where it is.
                  (unless (world-food-at w x y)
                    (let* ((fdx (- (food-x f) x)) (fdy (- (food-y f) y))
                           (fd (sqrt (+ (* fdx fdx) (* fdy fdy)))))
                      (declare (type f32 fdx fdy fd))
                      (when (> fd 1.0f-6)
                        (let ((step (min (* 0.5f0 *walk-speed* dt) fd)))
                          (declare (type f32 step))
                          (setf (aref bxs bi) (+ x (* (/ fdx fd) step))
                                (aref bys bi) (+ y (* (/ fdy fd) step)))))))
                  (let* ((rate (* *crop-fill-rate* (food-quality f)))
                         ;; the crop is f32 and the source is double, so
                         ;; the clamp is done in double and the result
                         ;; comes back to f32 for the crop
                         (take (float (min (float rate 1.0d0)
                                           (float (- 1.0f0
                                                     (aref (ants-crop a) i))
                                                  1.0d0)
                                           (food-amount f))
                                      1.0f0)))
                    (incf (aref (ants-crop a) i) take)
                    (decf (food-amount f) (float take 1.0d0))
                    ;; and it eats.  The crop is the colony's; this is
                    ;; the ant's own, and an ant standing on food is not
                    ;; hungry.  Not charged to the source: a forager's
                    ;; gut is negligible against the crop it is filling
                    ;; from the same pile, and the arithmetic would be
                    ;; noise dressed as rigour.
                    (when *forager-eats-at-source*
                      (setf (aref (ants-energy a) i) 1.0f0))
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
                              (if (plusp (aref (ants-cast a) i))
                                  *uturn-cast-gain*
                                  1.0f0)
                              (rnd-normal id tick +stream-turn+ seed)))
               (setf heading (wrap-angle (+ heading turn noise)))

               ;; U-turn on losing a trail (§3.2).
               ;;
               ;; An ant that was following a trail and finds it gone
               ;; turns about and casts, rather than carrying on into
               ;; open ground.  This is observed in L. niger and it is a
               ;; large part of why trails are stable: the ants actively
               ;; re-find them, so a trail does not have to be strong
               ;; enough to hold every ant on every tick.
               ;;
               ;; Outbound ants only.  A returning ant that loses the
               ;; trail is not lost — it has a home vector, which is a
               ;; second navigation system doing exactly this job — and
               ;; turning it round would fight the very term that gets it
               ;; home.  Being clueless without a trail is specifically
               ;; the outbound ant's problem.
               ;;
               ;; The trigger is an edge, not a level: it fires on the
               ;; tick the smell crosses down through the threshold, so
               ;; an ant in open ground that never had a trail never
               ;; U-turns, and one already casting is not re-triggered
               ;; every tick.  That is what ANTS-SMELLED is for.
               ;; Two levels, not one.  "Was on a trail" is
               ;; *trail-follow-threshold* against a memory that decays
               ;; over a second or so; "is off it" is
               ;; *trail-lost-threshold* against the reading now.  A
               ;; single level tested against last tick's reading fires
               ;; on every faint trail an ant brushes past, and measured
               ;; that cost 28% of the food delivered.
               (let ((prev (aref (ants-smelled a) i))
                     (lost *trail-lost-threshold*))
                 (declare (type f32 prev lost))
                 (setf (aref (ants-smelled a) i)
                       (max smell (* prev *trail-memory-decay*)))
                 (cond
                   ((plusp (aref (ants-cast a) i))
                    (decf (aref (ants-cast a) i)))
                   ((and (not returning)
                         (> lost 0.0f0)
                         (>= prev *trail-follow-threshold*)
                         (< smell lost))
                    ;; and it is no longer on the trail it remembers, so
                    ;; forget it — otherwise the latch is still armed
                    ;; when the casting ends and the ant U-turns again.
                    (setf (aref (ants-smelled a) i) 0.0f0)
                    (setf (aref (ants-cast a) i)
                          (min 255 (max 0 *uturn-ticks*)))
                    (setf heading
                          (wrap-angle
                           (+ heading 3.1415927f0
                              (* 0.5f0 (rnd-normal id tick +stream-uturn+
                                                   seed))))))))
               ;; homing urge: total for a returning ant, and growing as
               ;; energy falls for an outbound one (§3.5)
               (let* ((hv-len (sqrt (+ (* hvx hvx) (* hvy hvy))))
                      ;; against the colony's threshold, so the urge to
                      ;; turn back grows from the same point at which the
                      ;; ant would actually give up
                      (ethr (aref (ants-resolve a) i))
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
                                ;; Total, unless a trail is allowed to
                                ;; argue with it (§3.4).
                                (- 1.0f0 (* *trail-homing-suppression* smell))
                                (* *homing-weight-low-energy*
                                   (max 0.0f0
                                        (/ (- ethr
                                              (aref (ants-energy a) i))
                                           (max 1.0f-6 ethr)))))))
                 (declare (type f32 hv-len urge ethr))
                 (when (and (> hv-len 1.0f-4) (> urge 0.0f0))
                   ;; Home on the bearing if it is walkable and on the
                   ;; nearest walkable direction if it is not — the same
                   ;; antennal veto the choice function got, applied to
                   ;; the term that actually steers a laden ant.  See
                   ;; CLEAR-BEARING for why the veto in CHOOSE-TURN could
                   ;; not reach these ants.
                   (setf heading
                         (angle-toward heading
                                       (clear-bearing (colony-field c) x y
                                                      (atan hvy hvx)
                                                      (ant-handedness id seed)
                                                      *sensor-offset*)
                                       (min 1.0f0 (/ urge (+ 1.0f0 urge)))))))
               (setf (aref (ants-heading a) i) heading)

               ;; advance
               ;;
               ;; The pace is the individual's, not the colony's (§3.1).
               ;; It multiplies both speeds rather than being added to
               ;; one, so a fast ant is fast laden and unladen alike and
               ;; the laden/unladen *ratio* — which is what makes a long
               ;; arm cost more on the return leg — is untouched.
               ;;
               ;; Deposition is deliberately not scaled with it.  A packet
               ;; carries what the ant would have laid over the distance
               ;; it stands for (§3.3), so the trail is already per metre
               ;; rather than per tick, and a brisk ant lays exactly the
               ;; same road as a slow one — it simply lays it sooner,
               ;; which is the whole of what the difference should do.
               (let* ((speed (* (ant-pace id seed)
                                (if (> (aref (ants-crop a) i) 0.0f0)
                                    *walk-speed-laden* *walk-speed*)))
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
                          (when (> load 0.0f0)
                            (incf (colony-harvested c) load)
                            (incf (colony-trips c)))
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
                              (aref (ants-state a) i) +ant-in-nest+)
                        )))
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
                    ;; The give-up threshold, lowered by whatever recent
                    ;; evidence this ant has that persisting is paying
                    ;; (M3).  An ant that has just passed nestmates coming
                    ;; back loaded pushes further before turning round.
                    ;;
                    ;; This is the *only* thing confidence does.  It is
                    ;; not a bearing and it never becomes one — an ant
                    ;; learns from a contact that things are going well,
                    ;; not which way to walk (see ANT-ENCOUNTER-STEP!).
                    (cond ((let ((arrived (world-food-at w x2 y2)))
                             ;; The tally rides on the transition rather
                             ;; than on a scan, so it counts arrivals and
                             ;; not ant-ticks-spent-on-a-pile.  A counter
                             ;; is commutative, so the tick stays
                             ;; order-independent.
                             (when arrived (incf (food-visits arrived)) t))
                           (setf (aref (ants-state a) i) +ant-at-food+))
                          ((< (aref (ants-energy a) i)
                              (* (aref (ants-resolve a) i)
                                 (- 1.0f0
                                    (* *encounter-resolve-gain*
                                       (aref (ants-confidence a) i)))))
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
          (decf (aref (ants-hvy a) i) (* my (+ 1.0f0 ex)))
          ;; And, off the same displacement, the stride phase of §5.2.
          ;;
          ;; It rides here rather than in a pass of its own because this
          ;; is the one place in the tick that knows how far an ant
          ;; actually got — which is exactly what a planted foot needs and
          ;; what the *attempted* step (used for deposition, §3.3) is
          ;; deliberately not.  An ant wedged in a jam deposits at full
          ;; rate and its legs stop moving, and both of those are correct.
          ;;
          ;; Kept as a phase in [0,1) rather than as a distance so it
          ;; cannot lose precision in a colony that runs for an hour, and
          ;; so the renderer needs no wrap of its own.
          (setf (aref (ants-gait a) i)
                (mod (+ (aref (ants-gait a) i)
                        (/ (sqrt (+ (* mx mx) (* my my))) *gait-stride*))
                     1.0f0))))))
  (values))

(declaim (inline ant-afield-p))
(defun ant-afield-p (state)
  "Out of doors and walking — the only two states an encounter applies to.

An ant in the nest is behind the door (+BODY-RESTING+) and takes no part
in ant-ant contact at all; one standing at a source is not going
anywhere, so it has no traffic to sort and nothing to be persuaded of.
Both are excluded here rather than filtered by body kind alone, because
*resting-ants-block* can put a resting ant back into the collision table
and it must not thereby start antennating."
  (declare (type (unsigned-byte 8) state) (optimize (speed 3) (safety 0)))
  (or (= state +ant-outbound+) (= state +ant-returning+)))

(defun ant-encounter-step! (w)
  "Antennal contact: what happens when two ants meet (M3, §3.4, §3.11).

The broad phase has always reported *overlaps to be resolved*.  This
reads the same geometry as an event — this ant met that ant, at this
bearing, going that way — which is the piece §7 called the expensive part
of the social channel.  Three rules ride on it, and they are cheap
precisely because the event is not.

**1. Recognition.**  Nestmate or not, by colony, which stands for the
cuticular hydrocarbon profile a real worker reads off another's antennae.
A stranger is turned away from harder (*stranger-avoidance*), is never
fed, and is never believed.  That is all it does here: fighting, alarm
and defence are §3.12's subject and want two colonies with something to
fight over.  What matters now is that the two already take different
paths, so a consequence added later is a rule and not an excavation.

**2. Giving way.**  Two ants closing head-on each turn aside, and *how
much* depends on what they are carrying: a laden ant on its way home
yields least, an outbound ant most.  That asymmetry is taken from the
traffic literature rather than invented — laden inbound ants are reported
to hold their line while outbound ants deviate around them, and the lane
structure on a busy trail is a consequence of the asymmetry rather than
of any rule about sides.  Nothing here says 'walk on the left'.  If lanes
appear, they are a finding.

The tie-break when two ants meet exactly nose to nose is the ant's
handedness — already a lifelong per-individual trait (ANT-HANDEDNESS),
already drawn from the id with no tick, and already the answer to this
exact problem in a different guise: a side derived from anything that
moves flips with it, and two ants dithering nose to nose is the same
20 000-tick oscillation in miniature.

**3. Trophallaxis, and confidence.**  A laden ant hands food to a hungry
nestmate; §3.9 deferred this as 'the only mechanism in the model needing
pairwise coupling', and it is.  Meeting a laden nestmate coming the other
way also raises an outbound ant's *confidence* — which is not a direction
and must never become one.  Ants of this genus were tested for tactile
transfer of direction and the answer was no; what a contact honestly
carries is that nestmates are coming back loaded, which is evidence about
*when*, not about *where*.  So confidence buys persistence and nothing
else (*encounter-resolve-gain*).

**Determinism.**  Every rule reads the state the tick began with and
writes to a buffer applied afterwards — the same discipline as the Jacobi
collision buffers (§3.11) and the field deposit buffer (§3.3).  An ant
that turned in place would be seen already turned by every
higher-numbered neighbour, which makes the result depend on table order:
a bug that survives every test until the day something is threaded.  The
energy buffer is accumulated into by donors rather than owned by one ant,
which is fine for the same reason a pheromone deposit is — addition
commutes.  A threaded version needs the fixed partition of §4.5, exactly
as BODIES-RESOLVE! does."
  (declare (type world w) (optimize (speed 3) (safety 1)))
  (let* ((a (world-ants w))
         (b (world-bodies w))
         (n (ants-n a))
         (range *antennal-range*)
         (decay *confidence-decay*))
    (declare (type fixnum n) (type f32 range decay))
    (when (<= range 0.0f0)
      ;; the off position: confidence still decays away, so switching
      ;; encounters off mid-run cannot leave ants permanently persuaded
      (dotimes (i n)
        (when (ant-live-p a i)
          (setf (aref (the f32v (ants-confidence a)) i)
                (* decay (aref (the f32v (ants-confidence a)) i)))))
      (return-from ant-encounter-step! (values)))
    (let ((bxs (bodies-x b)) (bys (bodies-y b))
          (kinds (bodies-kind b)) (hash (bodies-hash b))
          (obm (ants-of-body a))
          (bodyv (ants-body a))
          (states (ants-state a)) (cols (ants-colony a))
          (heads (ants-heading a)) (crops (ants-crop a))
          (energies (ants-energy a))
          (dturn (ants-dturn a)) (dcrop (ants-dcrop a))
          (denergy (ants-denergy a)) (confs (ants-confidence a))
          (met (ants-met a)) (partner (ants-partner a))
          (pttl (ants-partner-ttl a)) (pgave (ants-partner-gave a))
          (fed-by (ants-fed-by a))
          (seed (world-seed w))
          (cone *encounter-cone*) (yrate *yield-rate*)
          (stranger *stranger-avoidance*) (overtake *yield-overtake*)
          (trate *trophallaxis-rate*)
          ;; The hunger bar is the colony's departure threshold, not a
          ;; flat fraction of a tank — see *trophallaxis-threshold*.  One
          ;; per colony, read once, because it is a colony-wide quantity
          ;; and an ant may only ever feed a nestmate.
          (thresholds (map 'vector
                           (lambda (col)
                             (* *trophallaxis-threshold*
                                (colony-energy-threshold col)))
                           (coerce (world-colonies w) 'vector)))
          (gain *encounter-confidence*)
          (r2 (* range range)))
      (declare (type f32v bxs bys heads crops energies dturn dcrop denergy
                          confs)
               (type u8v kinds states cols pgave)
               (type u32v obm bodyv met partner fed-by) (type u16v pttl)
               (type f32 cone yrate stranger overtake trate gain r2)
               (type simple-vector thresholds))
      ;; --- 1. clear the buffers and age the evidence -------------------
      (dotimes (i n)
        (setf (aref dturn i) 0.0f0
              (aref dcrop i) 0.0f0
              (aref denergy i) 0.0f0
              (aref fed-by i) +no-ant+)
        (when (ant-live-p a i)
          (setf (aref confs i) (* decay (aref confs i)))
          ;; the inspector's memory of the last meal, running down
          (when (plusp (aref pttl i))
            (decf (aref pttl i)))))
      ;; --- 2. the sweep ------------------------------------------------
      (dotimes (i n)
        (when (and (ant-live-p a i) (ant-afield-p (aref states i)))
          (let* ((bi (aref bodyv i))
                 (xi (aref bxs bi)) (yi (aref bys bi))
                 (hi (aref heads i))
                 (sti (aref states i))
                 (coli (aref cols i))
                 (cropi (aref crops i))
                 (returning (= sti +ant-returning+))
                 ;; What this ant owes the traffic.  Right of way for the
                 ;; loaded: it yields least, an outbound ant most.
                 (role (cond ((and returning (> cropi 0.0f0)) *yield-laden*)
                             (returning *yield-returning*)
                             (t *yield-outbound*)))
                 (turn 0.0f0)
                 ;; the neediest nestmate this ant could feed, and how
                 ;; empty it is — one partner per donor, so a donor can
                 ;; never give away more than it has however many hungry
                 ;; ants are pressed around it
                 (mouth -1) (mouth-e 2.0f0)
                 ;; too spent to set out again — the same bar the
                 ;; renderer draws as spent, so the rule is checkable
                 ;; by eye
                 (tthr (the f32 (aref thresholds coli))))
            (declare (type f32 xi yi hi cropi role turn mouth-e tthr)
                     (type fixnum bi mouth))
            (do-shash-neighbours (jb hash xi yi range)
              (let ((jbb (the fixnum jb)))
                (when (and (/= jbb bi) (= (aref kinds jbb) +body-ant+))
                  (let ((j (aref obm jbb)))
                    ;; Checked rather than trusted: a body outlives the
                    ;; ant that had it, so a stale entry must be capable
                    ;; only of being ignored.
                    (when (and (/= j +no-ant+) (< j n)
                               (ant-live-p a j)
                               (= (aref bodyv j) jbb)
                               (ant-afield-p (aref states j)))
                      (let* ((dx (- (aref bxs jbb) xi))
                             (dy (- (aref bys jbb) yi))
                             (d2 (+ (* dx dx) (* dy dy))))
                        (declare (type f32 dx dy d2))
                        (when (and (<= d2 r2) (> d2 1.0f-12))
                          (let* ((d (sqrt d2))
                                 ;; where it is, relative to where I face
                                 (beta (wrap-angle (- (atan dy dx) hi))))
                            (declare (type f32 d beta))
                            (when (< (abs beta) cone)
                              (let* ((same (= coli (aref cols j)))
                                     (stj (aref states j))
                                     ;; closing, rather than merely near:
                                     ;; an ant being overtaken is not an
                                     ;; obstruction and must not be
                                     ;; steered around
                                     (oncoming
                                       (< (cos (- (aref heads j) hi)) 0.0f0))
                                     (near (- 1.0f0 (/ d range))))
                                (declare (type f32 near))
                                ;; --- 2a. give way, or pass ------------
                                ;;
                                ;; Three cases, and the third was missing
                                ;; for long enough to be worth naming.
                                ;; A stranger is stepped away from
                                ;; whatever it is doing.  A nestmate
                                ;; closing head-on is given way to, by
                                ;; role.  And a nestmate ahead going the
                                ;; *same* way, which this ant is gaining
                                ;; on, is passed rather than queued
                                ;; behind — without that last case
                                ;; *speed-spread* buys nothing at all,
                                ;; because a fast ant simply walks into
                                ;; the back of a slow one and the
                                ;; collision solver holds the pair
                                ;; together at the slower pace.
                                (when (> yrate 0.0f0)
                                  (let ((weight
                                          (cond
                                            ((not same) (* role stranger))
                                            (oncoming role)
                                            ;; **In the way**: same
                                            ;; direction, close, and
                                            ;; nearly dead ahead.
                                            ;;
                                            ;; The trigger used to be
                                            ;; "I am nominally faster",
                                            ;; which is the wrong
                                            ;; question in the one case
                                            ;; that matters.  In a
                                            ;; stalled column nobody is
                                            ;; moving, so comparing
                                            ;; free-walking speeds lets
                                            ;; only the ants that happen
                                            ;; to be quicker on paper try
                                            ;; to pass and leaves the
                                            ;; rest shoving.  What that
                                            ;; produces is a queue whose
                                            ;; leader presses a wall
                                            ;; while everyone behind
                                            ;; presses into the ant in
                                            ;; front of them, which is
                                            ;; what the pockets fill up
                                            ;; with.
                                            ;;
                                            ;; Being obstructed is the
                                            ;; honest trigger, and it is
                                            ;; also the one an ant can
                                            ;; actually sense: something
                                            ;; is under my antennae and
                                            ;; it is not moving out of
                                            ;; the way.
                                            ((and (< d (* 0.75f0 range))
                                                  (< (abs beta) 0.7f0))
                                             overtake)
                                            (t 0.0f0))))
                                    (declare (type f32 weight))
                                    (when (> weight 0.0f0)
                                      ;; Away from where the other ant
                                      ;; is; dead ahead or nose to nose,
                                      ;; the ant's own hand.
                                      ;;
                                      ;; Deliberately *no* terrain check
                                      ;; here.  Giving way into a wall is
                                      ;; a real failure — in a pocket
                                      ;; every ant has rock on one side
                                      ;; and a nestmate on the other, so
                                      ;; the whole crowd yields into the
                                      ;; rock and wedges — but the fix
                                      ;; belongs at the end of the tick
                                      ;; rather than here.  Every rule
                                      ;; that can turn an ant would
                                      ;; otherwise need its own copy of
                                      ;; it, and they would drift apart.
                                      ;; See the single veto in
                                      ;; ANT-MOTION-STEP!.
                                      (let ((side
                                              (if (> (abs beta) 1.0f-3)
                                                  (if (plusp beta)
                                                      -1.0f0 1.0f0)
                                                  (ant-handedness
                                                   (aref (ants-id a) i)
                                                   seed))))
                                        (declare (type f32 side))
                                        (incf turn
                                              (* side yrate near weight))))))
                                ;; --- 2a2. it happened at all ----------
                                ;;
                                ;; Encounter rate, which the model has
                                ;; been producing and discarding.  Own
                                ;; slot, so it stays order-independent.
                                (when same
                                  (let ((c0 (aref met i)))
                                    (when (< c0 4294967295)
                                      (setf (aref met i) (1+ c0)))))
                                ;; --- 2b. news from a nestmate ---------
                                ;;
                                ;; Loaded, coming the other way, and mine.
                                ;; All three are needed: a stranger's
                                ;; success is not evidence for me, an
                                ;; empty nestmate is no evidence at all,
                                ;; and one walking beside me is on the
                                ;; same errand rather than back from it.
                                (when (and same oncoming
                                           (= sti +ant-outbound+)
                                           (= stj +ant-returning+)
                                           (> (aref crops j) 0.0f0))
                                  (setf (aref confs i)
                                        (min 1.0f0 (+ (aref confs i) gain))))
                                ;; --- 2c. a mouth to feed --------------
                                (when (and same (> trate 0.0f0)
                                           returning (> cropi 0.0f0)
                                           (< (aref energies j) tthr)
                                           (< (aref energies j) mouth-e))
                                  (setf mouth j
                                        mouth-e (aref energies j)))))))))))))
            (setf (aref dturn i) turn)
            (when (>= mouth 0)
              (let ((give (min trate cropi)))
                (declare (type f32 give))
                (decf (aref dcrop i) give)
                ;; Accumulated into, not assigned: several donors may feed
                ;; one ant in the same tick and addition commutes.
                (incf (aref denergy mouth) (* give *crop-to-energy*))
                ;; the giving half is this ant's own slot, so it is
                ;; recorded directly
                (setf (aref partner i) (aref (ants-id a) mouth)
                      (aref pgave i) 1
                      (aref pttl i) (min 65535 (max 0 *partner-memory*)))
                ;; and the receiving half goes through the commutative
                ;; buffer — see ANTS-FED-BY for why MIN and not assignment
                (setf (aref fed-by mouth)
                      (min (aref fed-by mouth) (aref (ants-id a) i))))))))
      ;; --- 3. apply ----------------------------------------------------
      (dotimes (i n)
        (when (ant-live-p a i)
          (unless (zerop (aref dturn i))
            (setf (aref heads i) (wrap-angle (+ (aref heads i) (aref dturn i)))))
          (unless (zerop (aref dcrop i))
            (setf (aref crops i) (max 0.0f0 (+ (aref crops i) (aref dcrop i)))))
          (unless (zerop (aref denergy i))
            (setf (aref energies i)
                  (min 1.0f0 (+ (aref energies i) (aref denergy i)))))
          ;; Being fed outranks having fed, for the readout only: an ant
          ;; that did both this tick is more interestingly the one that
          ;; was in trouble.
          (unless (= (aref fed-by i) +no-ant+)
            (setf (aref partner i) (aref fed-by i)
                  (aref pgave i) 2
                  (aref pttl i) (min 65535 (max 0 *partner-memory*))))))))
  (values))

(defun colony-feed! (w)
  "Serve meals from each colony's stock: the hungriest resting ants
first, each restored as far as the larder allows (§3.5).

Its own pass, and it has to be one.  The ant loop walks the table in
index order and cannot know which ant is hungriest until it has seen them
all, so feeding inside it can only ever be first-come — and since the
order is the array's layout, that means the low-numbered ants eat for
ever.

*nest-meals-per-tick* is both the bound on the work and the model.  A
nest serves a few ants at a time, not all of them at once, and that is
the whole difference between a colony that fields foragers and one that
fields hundreds of ants too weak to finish a trip.

O(meals x ants) with meals a small constant, which at the default is
about a thousand array reads against a tick that already does collision
resolution and three-point sensing for every ant.  Not the bottleneck,
and measured before it is optimised.

If it ever *is* the bottleneck, the structure to reach for is a bucket
priority queue rather than a sort: ants indexed by energy band, feeding
drawn from the lowest non-empty band.  It fits this problem unusually
well because energy only falls while an ant rests and jumps to full when
it is served, so an ant moves monotonically downward through the bands
and entries can be invalidated lazily instead of removed — push on
entry, and on pop discard any entry whose ant no longer belongs to that
band.

Two constraints it would have to respect, both from SS4.2 and SS4.4.  The
bands must hold ant indices in ascending order rather than live in a
hash table, because which of several equally hungry ants gets served has
to be decided the same way on every run or bit-exactness goes; and they
must be preallocated with the ant table, because an allocation every
tick would cost more than the scan it replaces."
  (declare (type world w))
  (let ((a (world-ants w))
        (meals *nest-meals-per-tick*))
    (declare (type fixnum meals))
    (when (plusp meals)
      (dolist (c (world-colonies w))
        (dotimes (k meals)
          (declare (ignorable k))
          (when (<= (colony-stock c) 0.0f0) (return))
          (let ((best -1) (beste 2.0f0)
                (cid (colony-id c)))
            (declare (type fixnum best) (type f32 beste))
            (dotimes (i (ants-n a))
              (when (and (ant-live-p a i)
                         (= (aref (ants-colony a) i) cid)
                         (= (aref (ants-state a) i) +ant-in-nest+)
                         (< (aref (ants-energy a) i) beste))
                (setf best i beste (aref (ants-energy a) i))))
            ;; nobody resting, or nobody hungry: the larder keeps
            (when (or (minusp best) (>= beste 1.0f0)) (return))
            (let ((want (min (- 1.0f0 beste) (colony-stock c))))
              (declare (type f32 want))
              (decf (colony-stock c) want)
              (incf (aref (ants-energy a) best) want)
              (setf (aref (ants-waited a) best) 0)))))))
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
  ;; Brood, out of the *surplus* — what the larder holds over and above a
  ;; reserve for the workers already alive (§3.10).
  ;;
  ;; Investing a tenth of the whole stock, which is what this did, is a
  ;; growth rule with no feedback term, and a rule with no feedback term
  ;; has a fixed point.  This one's is stock zero: every surplus becomes
  ;; mouths, the mouths consume the next surplus, and the colony grows
  ;; until its upkeep matches everything its foragers can carry and then
  ;; sits there.  Traced over forty minutes, population 169 -> 745 while
  ;; the larder went 358 -> 0, with delivery averaging 120 a minute the
  ;; whole way.  Nothing was failing to fetch food; the colony was
  ;; spending it all on workers to fetch more.
  ;;
  ;; The reserve is stock per living worker, in the same units as
  ;; *forage-ration*, because that is already the number the colony reads
  ;; to decide whether it is hungry.  So one quantity carries one meaning
  ;; throughout: above the line it breeds, below the line it forages
  ;; harder.
  ;;
  ;; Fractional, so a birth rate below one worker per tick still
  ;; accumulates instead of rounding to zero for ever.
  ;; The ring is sized from the parameter here rather than at
  ;; construction, so rebinding the development time actually takes
  ;; effect — which is what makes it measurable.
  (let ((len (max 1 *brood-development-minutes*)))
    (declare (type fixnum len))
    (when (or (null (colony-brood-pipe c))
              (/= (length (the f32v (colony-brood-pipe c))) len))
      (setf (colony-brood-pipe c) (mkf32 len)
            (colony-brood-head c) 0)))
  (let* ((pipe (colony-brood-pipe c))
         (len (length (the f32v pipe)))
         (head (mod (colony-brood-head c) len)))
    (declare (type f32v pipe) (type fixnum len head))
    ;; 1. the oldest cohort emerges
    (incf (colony-brood c) (aref pipe head))
    (setf (aref pipe head) 0.0f0)
    ;; 2. the queen lays into the slot just vacated, so it comes out LEN
    ;;    ticks from now.  Bounded twice over: by what the colony can
    ;;    afford above its reserve, and by what one animal can lay.
    (let* ((reserve (* (colony-population c) *forage-ration*
                       *brood-reserve-ration*))
           (surplus (max 0.0f0 (- (colony-stock c) reserve)))
           (affordable (* *brood-per-stock* *brood-investment* surplus))
           (eggs (if (plusp *queen-lay-rate*)
                     (min affordable *queen-lay-rate*)
                     affordable)))
      (declare (type f32 reserve surplus affordable eggs))
      (when (plusp eggs)
        ;; pay only for the eggs actually laid
        (decf (colony-stock c) (/ eggs (max 1.0f-6 *brood-per-stock*)))
        (setf (aref pipe head) eggs)))
    (setf (colony-brood-head c) (mod (1+ head) len)))
  ;; 3. emerged brood becomes workers.  Fractional, so a birth rate below
  ;;    one worker per tick still accumulates instead of rounding to zero
  ;;    for ever.
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
      (setf (aref (bodies-r b) (food-body f)) (food-current-radius f)))
    ;; A source that is gone should stop being anything at all.  At zero
    ;; amount its radius is zero, but a zero-radius body is still a body:
    ;; the renderer draws a point where the pile was, so an exhausted
    ;; source left a small dot sitting in the arena for the rest of the
    ;; run, which reads as a source that is somehow still there.
    ;;
    ;; Only sources that cannot come back.  A renewing source at zero is
    ;; empty *now* and will refill on a later colony tick, so removing it
    ;; would delete a scenario's feature rather than tidy a leftover.
    (when (some (lambda (f)
                  (and (food-empty-p f) (<= (food-renew f) 0.0f0)))
                (world-foods w))
      (setf (world-foods w)
            (remove-if (lambda (f)
                         (when (and (food-empty-p f)
                                    (<= (food-renew f) 0.0f0))
                           (bodies-free! b (food-body f))
                           t))
                       (world-foods w)))))
  (bodies-resolve! (world-bodies w) (world-obstacles w))
  ;; Encounters read the positions the collision pass settled on, and the
  ;; spatial hash BODIES-RESOLVE! leaves rebuilt behind it.  Nothing here
  ;; moves an ant, so path integration is unaffected by where in the tick
  ;; this sits; what it must not do is read positions two ants are still
  ;; overlapping at.
  (ant-encounter-step! w)
  (path-integration-step! w)
  ;; after the drain, so a meal is measured against what the ant has
  ;; actually spent this tick
  (colony-feed! w)
  (incf (world-tick w))
  (when (zerop (mod (world-tick w) (world-pheromone-every w)))
    (dolist (c (world-colonies w))
      (field-step! (colony-field c) *pheromone-dt*)))
  (when (zerop (mod (world-tick w) (world-colony-every w)))
    (dolist (f (world-foods w))
      (when (plusp (food-renew f))
        (setf (food-amount f)
              (min (food-initial f)
                   (+ (food-amount f) (float (food-renew f) 1.0d0))))))
    (dolist (c (world-colonies w))
      (colony-step! w c)))
  (values))

(defun world-run! (w ticks)
  (declare (type world w) (type fixnum ticks))
  (dotimes (i ticks) (world-step! w))
  w)

(defun world-seed-population! (w c n)
  "Place the colony's starting workers (§3.10).  A starting count, not
*the* count: births and deaths run from tick one.

The starting workers are given *ages*, spread over the maturity window
and beyond it, rather than all being newly emerged.  A scenario opens on
a colony that already exists, and a colony that already exists is not
three hundred callow workers hatched at once — that is the demography of
a colony founded this morning, which is not what any scenario here
describes.

Left at zero it also breaks the scenarios outright once foraging has a
maturity gate (§3.5): every starting ant is too young to leave, so
nothing forages until the whole founding cohort matures simultaneously,
and then all of it does.  Spreading the ages removes both the dead
opening and the cohort that moves as one block afterwards.

Deterministic, from the ant's own id, so a seeded run stays bit-exact."
  (declare (type world w) (type colony c) (type fixnum n))
  (let ((a (world-ants w))
        (seed (world-seed w)))
    (dotimes (i n)
      (let ((idx (spawn-ant w c)))
        (unless idx (return))
        ;; A spread of ages, so the colony looks and behaves like a going
        ;; concern rather than a cohort hatched this morning.
        ;;
        ;; Scaled against the *larger* of the maturity window and the age
        ;; at which an ant is drawn as fully mature.  Keying it to
        ;; maturity alone was wrong the moment maturity was switched off:
        ;; the window collapses to a single tick, every founder is born
        ;; newborn, and the whole colony renders as callow for the rest of
        ;; the run.  A parameter set to zero should not silently take a
        ;; second quantity to zero with it.
        (setf (aref (ants-age a) idx)
              (floor (* 1.5f0 (max (* 2 *forager-maturity-ticks*)
                                   *age-shade-ticks*)
                        (rnd01 (aref (ants-id a) idx) 0 94 seed)))))))
  (colony-population c))
