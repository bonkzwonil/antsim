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
  ;;
  ;; **Double, and single precision was silently wrong here.**  Everything
  ;; else in the model is f32 on purpose — positions, fields, crop — and
  ;; this is the one place that fails, because it is the only accumulator
  ;; in the system whose *magnitude* and whose *increment* are separated
  ;; by six orders of magnitude.  A forager takes 0.02 units of a
  ;; 500 000-unit pile in a tick.  At 500 000 an f32 ulp is 0.031, so
  ;; 0.02 is below half an ulp and `(decf amount take)` **rounds back to
  ;; where it started** — the pile is eaten from for ever and never goes
  ;; down.  Found by the Beckers apparatus, which reported 850 feeding
  ;; visits to a source that had lost nothing at all; a poor source is
  ;; worse still, since its take is quality-scaled and smaller yet.
  ;;
  ;; It is not only the unlimited sources.  Wherever the take is near half
  ;; an ulp the *rate* is wrong rather than absent — at 500 000 with
  ;; quality 1.0, take 0.02 rounds up to 0.031 and the pile empties 56%
  ;; too fast.  Below about 30 000 units the error stops mattering, which
  ;; is why the shipped scenarios never showed it and the acceptance
  ;; apparatus did.
  (amount 0.0d0 :type double-float)
  (initial 0.0d0 :type double-float)
  ;; Units of food per square metre of pile (§5.1).
  ;;
  ;; This is what makes the drawn disc mean something absolute.  Without
  ;; it the radius could only be a *fraction* of a starting size, so a
  ;; source holding 500 000 units and one holding 2 500 looked exactly
  ;; alike at full — the picture said "how much of it is left" when the
  ;; question being asked of it was "how much is there".
  ;;
  ;; Defaulted from the authored radius and starting amount, which makes
  ;; a scenario that does not mention density behave exactly as before:
  ;; density = initial / (pi r^2) gives back r at full and r*sqrt(a/initial)
  ;; as it empties.
  (density 0.0f0 :type f32)
  ;; Quality sets crop fill rate *and* trail deposition rate, which is why
  ;; a rich source out-recruits a poor one at equal distance, and why a
  ;; source below *trail-quality-threshold* is eaten but never recruited
  ;; to.  Two acceptance rows depend on this one number.
  (quality 1.0f0 :type f32)
  (renew 0.0f0 :type f32)               ; units per colony tick
  ;; Feeding arrivals, ever.  This is the traffic measure the two Beckers
  ;; rows are actually about, and it is not the same as depletion: crop
  ;; fill rate is quality-modulated, so a poor source gives up less food
  ;; per visit and depletion confounds "how many ants came" with "how
  ;; much each one got".  Counted where an ant enters AT-FOOD.
  (visits 0 :type fixnum))

(defun food-empty-p (f)
  (declare (type food f))
  (<= (food-amount f) 0.0d0))

(defconstant +pi-f+ 3.1415927f0)

(defun food-current-radius (f)
  "The source's *present* radius: the radius of a pile of that much food
at this source's density.

    area = amount / density,   r = sqrt(amount / (pi * density))

So the disc's **area** is the quantity, and — because density is a
property of the source rather than of its starting size — the radius is
absolute.  Two sources drawn side by side can be compared: the bigger
circle really does hold more food, which was not true when the radius was
a fraction of whatever the source happened to start with.

This is the collision radius, not just the drawn one, and that is the
point: a smaller pile has a shorter edge, so fewer ants can reach it at
once and the queue behind it grows as it empties.  Feeding rate falling
as a source runs down is a real constraint on foraging, and it comes out
of the geometry for free rather than needing a rule of its own."
  (declare (type food f))
  (let ((d (food-density f)))
    (if (plusp d)
        ;; the amount is double (see the struct); the radius is a world
        ;; coordinate and stays f32 like every other one
        (float (sqrt (/ (max 0.0d0 (food-amount f))
                        (* (float +pi-f+ 1.0d0) (float d 1.0d0))))
               1.0f0)
        0.0f0)))

(defun food-density-for (r amount)
  "The density that makes a pile of AMOUNT come out at radius R.

The default when a scenario gives a radius but no density, which keeps
every existing scenario behaving exactly as it did."
  (declare (type f32 r) (type double-float amount))
  (if (and (plusp r) (plusp amount))
      (float (/ amount (* (float +pi-f+ 1.0d0) (float r 1.0d0) (float r 1.0d0)))
             1.0f0)
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
  ;; Gross crop carried in, ever.  STOCK is a *balance* — it nets out
  ;; upkeep, brood and the meals handed to ants in the nest — so two
  ;; colonies with equal stock may have foraged very differently, and
  ;; the §3.8 competition row is a claim about foraging.  Counted at the
  ;; nest door, before any of it is spent.
  (harvested 0.0f0 :type f32)
  (trips 0 :type fixnum)                ; laden arrivals, ditto
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
  (brood 0.0f0 :type f32)
  ;; Eggs in development, as a ring of cohorts one colony tick apart
  ;; (§3.10).  Slot BROOD-HEAD is the oldest and emerges next; new eggs
  ;; are laid into it once it has been emptied, so the ring's length is
  ;; exactly the development time.
  ;;
  ;; A pipeline rather than a number because brood is neither instant nor
  ;; parallel.  There is one queen: she lays at a bounded rate whatever
  ;; the larder holds, and what she lays becomes a worker weeks later,
  ;; not the same afternoon.  Modelled as a single figure that converts
  ;; food to workers on the spot, a colony answers a windfall with an
  ;; immediate population spike and answers a famine by stopping dead —
  ;; both of which are artefacts of leaving the queen and the developing
  ;; brood out of the model rather than behaviours of a colony.
  (brood-pipe nil :type (or null f32v))
  (brood-head 0 :type fixnum))

(defun colony-alive-p (c)
  (declare (type colony c))
  (plusp (colony-population c)))

(defun colony-forage-urgency (c)
  "How hungry the colony is, 0.0 (full larder) to 1.0 (empty), from the
stock it holds per living worker (§3.5).

This is the model's whole account of why a colony forages harder when it
is short of food, and it is deliberately the *only* thing that reads the
stock as a colony-wide quantity — an individual ant never does.  An ant
learns the same fact locally and honestly: it asks the stock for energy
while it rests, and being given none is what tells it the larder is
empty.  Nothing here lets an ant know about food it has not visited.

Leaving this out deadlocked the colony outright.  Setting out needed
energy, energy came from the stock, and the stock came from ants setting
out; when the source ran dry those three closed into a ring, and every
ant lay down in the nest and starved without one of them going to look.
Extinction is a legitimate outcome (§3.10) — dying in bed with the door
shut is not."
  (declare (type colony c))
  (let ((pop (max 1 (colony-population c))))
    (- 1.0f0
       (clampf (/ (/ (colony-stock c) (float pop 1.0f0))
                  (max 1.0f-6 *forage-ration*))
               0.0f0 1.0f0))))

(defun colony-leave-probability (c &optional urgency)
  "Chance per tick that a rested ant sets out, raised as the larder empties.

URGENCY defaults to the colony's own.  An individual ant passes its
*engagement* instead (ANT-ENGAGEMENT) — the same colony-wide stimulus
seen through that ant's own response threshold — so ants differ in when
they take the job up without the colony ever knowing which ones did."
  (declare (type colony c))
  (let ((u (or urgency (colony-forage-urgency c))))
    (declare (type f32 u))
    (* *leave-probability*
       (+ 1.0f0 (* u (- *forage-urgency-gain* 1.0f0))))))

(defun colony-energy-threshold (c)
  "The energy an ant needs to set out.

Moving this one alone, upward, would push a starving ant out of the nest
and turn it round on the very next tick — a deadlock in a different
place — which is why the give-up threshold below is defined *relative*
to it and is never above it."
  (declare (type colony c))
  (* *energy-return-threshold*
     (- 1.0f0 (* (colony-forage-urgency c)
                 (- 1.0f0 *desperate-energy-fraction*)))))

(defun colony-giveup-threshold (c)
  "The energy at which an ant already out gives up and turns for home.

The same number as the departure threshold while the larder is full, and
falling below it — toward not turning back at all — as the larder
empties (§3.5).

These were one number for a long time, on the reasoning that setting out
and turning back are two ends of one decision.  They are not, and the
difference is the whole of what a colony is.  Whether to *spend* a
forager is the colony's question and the answer depends on what the
colony has left; whether the forager comes back alive is the forager's,
and a superorganism does not weight it equally.  A worker is somatic
tissue with legs.  When the larder is empty the expected value of one
more ant searching exceeds the expected value of that ant resting safely
at home, because a colony with no food and a full nest of survivors is
dead anyway — so the bar for turning back drops, and at
*forager-expendability* = 0 it reaches zero and the ant searches until
it dies.

This is documented behaviour, not licence: forager risk-taking rises
with colony need across many species, and foraging is the caste's
terminal role rather than a stage it survives.  What the model adds is
that it is also the arithmetic."
  (declare (type colony c))
  (* (colony-energy-threshold c)
     (- 1.0f0 (* (colony-forage-urgency c)
                 (- 1.0f0 *forager-expendability*)))))

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
            :ants (make-ants capacity :body-capacity capacity)
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

(defun add-food (w x y r amount &key (quality 1.0f0) (renew 0.0f0) density)
  "Add a food source.

R and DENSITY are two ways of saying the same thing and giving both is a
contradiction, so R is treated as the radius *at the starting amount* and
DENSITY, when given, wins.  With neither, a scenario behaves as it always
has."
  (declare (type world w))
  (let* ((x (float x 1.0f0)) (y (float y 1.0f0)) (r (float r 1.0f0))
         (amount (float amount 1.0d0))
         (d (if density
                (float density 1.0f0)
                (food-density-for r amount)))
         (f (%make-food :body 0 :x x :y y :r r
                        :amount amount :initial amount
                        :density d
                        :quality (float quality 1.0f0)
                        :renew (float renew 1.0f0))))
    ;; allocate the body at the radius the density actually implies, so
    ;; the very first frame is already honest rather than being corrected
    ;; on the next tick
    (setf (food-body f) (bodies-alloc (world-bodies w) x y
                                      (food-current-radius f) +body-food+))
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

(defun world-food-near (w x y slack)
  "The nearest source whose disc comes within SLACK of (X, Y), or NIL.

WORLD-FOOD-AT asks whether an ant is *on* a source.  This asks whether it
is near enough to get back onto one, which is a different question and
the one a feeding ant needs: the pile is a blocking body surrounded by a
crowd, so an ant that is part of that crowd is shoved off the edge
constantly and has not thereby finished its meal."
  (declare (type world w) (type f32 x y slack))
  (let ((best nil) (bestd 0.0f0))
    (declare (type f32 bestd))
    (dolist (f (world-foods w) best)
      (unless (food-empty-p f)
        (let* ((dx (- x (food-x f))) (dy (- y (food-y f)))
               (d2 (+ (* dx dx) (* dy dy)))
               (rr (+ (food-current-radius f) *ant-radius* slack)))
          (declare (type f32 dx dy d2 rr))
          (when (and (<= d2 (* rr rr))
                     (or (null best) (< d2 bestd)))
            (setf best f bestd d2)))))))

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
