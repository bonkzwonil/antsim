;;;; params.lisp — the Lasius niger parameter set, and the units it fixes.
;;;;
;;;; Everything here is a DEFPARAMETER rather than a DEFCONSTANT, because
;;;; README §8 lists "literature constants are in units the model does not
;;;; use" as a high severity risk and §10 flags most of these as recalled
;;;; rather than sourced.  They are calibration targets, and a scenario or
;;;; a test must be able to rebind them.  Anything genuinely fixed — the
;;;; shape of the choice function, say — is fixed in code, not here.
;;;;
;;;; UNITS, once, everywhere: metres, seconds, radians.  Pheromone is in
;;;; arbitrary "units" whose scale is set entirely by the relationship
;;;; between *trail-deposit* and *choice-k*; see the note on the latter.
;;;;
;;;; Provenance is marked on every value:
;;;;   [lit]   from the literature, in the literature's own units
;;;;   [scale] derived from the §3.1 scale table
;;;;   [cal]   a free parameter, chosen so §3.8 passes — the honest label
;;;;           for a number nobody measured

(in-package #:antsim)

;;; --------------------------------------------------------------------
;;; Space and time (§3.1)
;;; --------------------------------------------------------------------

(defparameter *cell-size* 0.005f0
  "Pheromone cell edge, metres.  [scale] One body length, so a trail is
about one cell wide and an ant cannot cross a cell in a single tick.")

(defparameter *motion-dt* 0.05f0
  "Motion tick, seconds — 20 Hz.  [scale] At the top walking speed an ant
covers 1.5 mm per tick, well under a cell: it cannot tunnel through a
one-cell wall, and deposition never skips a cell.")

(defparameter *pheromone-dt* 1.0f0
  "Pheromone tick, seconds — 1 Hz (§4.3).")

(defparameter *colony-dt* 60.0f0
  "Colony tick, seconds — 1/min (§4.3).")

;;; --------------------------------------------------------------------
;;; The ant (§3.1, §3.5)
;;; --------------------------------------------------------------------

(defparameter *ant-radius* 0.0025f0
  "Collision radius, metres.  [scale] Half a 4-5 mm body length (§3.11).")

(defparameter *walk-speed* 0.02f0
  "Free walking speed, m/s.  [lit] L. niger walks 1-3 cm/s; the midpoint.")

(defparameter *walk-speed-laden* 0.015f0
  "Walking speed carrying a full crop, m/s.  [cal] Laden ants are slower;
the ratio matters more than the value, because it is what makes a long
arm cost more than a short one on the return leg as well as the outbound.")

(defparameter *turn-sigma* 0.05f0
  "Standard deviation of the per-tick heading noise, radians.  [cal]
§3.9 replaces the wrapped Cauchy of §3.2 with a Gaussian: same
locally-straight, globally-diffusive path, and the tail shape is a
refinement rather than a mechanism.

The value is set by the *persistence length* it implies, which is the
only property of a correlated random walk that matters here: for a step
s and per-step angular sd sigma, L_p is about 2s/sigma^2.  With s = 1 mm
per tick, sigma together with *turn-rate* gives L_p on the order of
20 cm — the right scale for an ant searching a 1 m arena.

The first value tried was 0.35, which gives L_p = 1.6 cm.  Ants with a
path that tortuous never found a food source 40 cm away at all, the
colony burned its stock on fruitless trips, and the run died out.  That
looked like a broken foraging model and was in fact a walk with the
wrong correlation length.")

(defparameter *trail-turn-gain* 3.0f0
  "How much more sharply an ant turns when it is actually on a trail.
[cal]

The choice function decides *which way*; this decides *how hard*.  With a
saturated trail under its antennae an ant picks the right direction about
95% of the time, but at the bare *turn-rate* it turns only a little more
per tick than its own heading noise — so it drifts off the road it just
chose, rediscovers it, drifts off again, and the result looks like a
colony that has found the food and is still wandering.

Making the turn sharper in proportion to the concentration it can smell
is the fix, and it is not a fudge: a real ant following a strong trail
makes tighter, more corrective turns than one casting about in clean
ground.  Off the trail the term vanishes and the walk is exactly the
correlated random walk of §3.2, so search behaviour is untouched.

Deliberately *not* implemented by lowering k or raising n.  Both would
have moved trail-following in the same direction while changing the
choice function itself, which §3.8 is a test of.")

(defparameter *trail-noise-suppression* 0.6f0
  "How much of the heading noise a strong trail removes.  [cal] Same
argument as *trail-turn-gain*, from the other side: a committed
trail-follower is not just turning harder, it is wandering less.")

(defparameter *turn-rate* 0.08f0
  "Heading change per tick toward the antennal sample the choice function
picked, radians.  [cal]

Deliberately *not* the same number as *sensor-spread*.  The spread is
where the antennae are — a real geometric fact about the ant — while
this is how fast the animal can turn.  Conflating them, which is the
obvious first implementation, makes an ant snap through 30 degrees every
50 ms: a 20 Hz sequence of large discrete turns, which is both physically
absurd and destroys the persistence the walk needs.  Sensing wide and
turning slowly is what real ants do.")

(defparameter *sensor-offset* 0.012f0
  "How far ahead of the ant the antennal sample is taken, metres.

[scale, adjusted] A real *L. niger* antenna reaches perhaps 3 mm past the
head, which is where this started — and at that offset the model could
not discriminate at all.  The three sample points have to land in three
*different* grid cells, and with a 5 mm cell (§3.1) a 6 mm offset put the
centre and one flanking sample in the same cell perpetually.

The failure was quiet and exact: the choice function's preference for a
doubled arm came out at 4/9 with n = 2 instead of 4/6, which is precisely
what you get when two of the three weights are the doubled one.  Nothing
errored; the amplification was simply diluted.

12 mm makes the lateral separation about 2.4 cells.  This is the standard
compromise of a grid-based pheromone model — the sample points stand for
where the ant is *about to be* rather than where its antennae are — and
the honest alternative is a finer grid, which §3.1 sizes for other
reasons.  If the cell size changes, check this again.")

(defparameter *sensor-spread* 0.52f0
  "Half-angle between the left and right antennal samples, radians.
[scale] 30 degrees.  This doubles as the size of the discrete turn the
choice function selects, which is what makes trail following and the
correlated random walk literally the same code path (§3.5).")

;;; --------------------------------------------------------------------
;;; The choice function (§3.3) — the one thing that must be exactly right
;;; --------------------------------------------------------------------

(defparameter *choice-n* 2.0f0
  "Exponent of the Deneubourg choice function.  [lit] n ~ 2.  This is the
nonlinearity, and it is the whole model: n = 1 must produce no selection
at all, which is an acceptance test rather than a remark.")

(defparameter *choice-k* 20.0f0
  "Offset of the Deneubourg choice function.  [lit, units unverified]

k ~ 20 is quoted from bridge experiments where concentration is measured
in *passages* — the number of ants that have crossed — not in the
arbitrary units this field uses.  §8 flags exactly this as a high
severity risk.  The translation is handled by pinning the units instead
of the number: *trail-deposit* is scaled so that one laden ant crossing
one cell raises it by about one unit, which makes a unit a passage and k
comparable.  If that scaling changes, this number is meaningless until
recalibrated.")

(defparameter *choice-eavesdrop* 0.1f0
  "ε — weight on foreign colonies' trail fields (§3.12).  Small by
design: a large ε lets a neighbour's trail dominate the (k+C)^n weights
and collapses the colonies into one shared field.  M1 runs one colony, so
this never fires.")

;;; --------------------------------------------------------------------
;;; The trail field (§3.3)
;;; --------------------------------------------------------------------

(defparameter *trail-tau* 1800.0f0
  "Evaporation time constant, seconds, in C <- C exp(-dt/tau).  [lit,
converted] Reported trail *half-lives* for L. niger are tens of minutes;
tau = 1800 s is a half-life of tau ln 2 = 1248 s, about 21 minutes.  Note
the conversion: quoting a half-life into a time constant unchanged would
make trails 44% too persistent.

Evaporation is not a detail — it is the only mechanism by which the
colony forgets, and the acceptance row for trail death measures it.")

(defparameter *trail-cap* 100.0f0
  "Saturation ceiling.  [cal] A real trail is not unboundedly strong.")

(defparameter *trail-deposit* 1.0f0
  "Units laid per motion tick by a laden ant returning from ideal food.
[cal] This is the parameter that *defines* the pheromone unit — see
*choice-k*.  An ant crossing a 5 mm cell at the laden speed spends about
7 ticks in it, so a single pass lays a few units and a trail needs
several passes before it outweighs k.  That is the intended regime: one
ant must not be able to commit the colony.")

(defparameter *trail-quality-threshold* 0.3f0
  "Food quality below which no trail is laid at all.  [lit] Beckers et
al.: L. niger feeds on poor sucrose but does not recruit to it.  This
threshold is a switch, not a taper, and it is its own acceptance row.")

;;; --------------------------------------------------------------------
;;; Energy, crop, and life (§3.5, §3.10)
;;; --------------------------------------------------------------------

(defparameter *energy-drain-walking* 1.2f-4
  "Energy lost per motion tick while walking, as a fraction of full.
[cal] Full to empty in about 7 minutes of continuous walking.

This number sets the length of a *fruitless* search, and that turned out
to be the thing it controls that matters.  At the first value tried
(2.2e-5, 38 minutes) the model ran and laid trail, but 152 of 186 ants
were permanently OUTBOUND: an ant with no food to find kept walking for
29 simulated minutes before its energy fell far enough to turn it round,
so the colony had almost no returning traffic and the trail was built by
a trickle.  Foraging trips have a duration, and it is set here.")

(defparameter *energy-drain-resting* 2.0f-5
  "Energy lost per motion tick at rest.  [cal] Roughly a sixth of the
walking cost.")

(defparameter *energy-return-threshold* 0.45f0
  "Energy below which an outbound ant gives up and heads home.  [cal]
Not a hard switch: see *homing-weight-*, which makes the turn gradual.")

(defparameter *crop-fill-rate* 0.02f0
  "Crop filled per motion tick at quality 1.0.  [cal] Two and a half
seconds to fill at ideal quality; longer at poor food, which is one of
the ways quality shows up in the foraging rate.")

(defparameter *leave-probability* 0.005f0
  "Chance per motion tick that a rested ant in the nest sets out.  [cal]
About one departure every 10 s of simulated time, so a colony's foragers
trickle out rather than leaving in lockstep — and the trickle is what
lets a trail build gradually enough for the choice function's
amplification to have something to amplify.

This is also the whole of M1's task allocation: §3.9 defers response
thresholds and age polyethism, so there is exactly one task and this
probability is how an ant decides to do it.")

(defparameter *nest-feed-rate* 0.002f0
  "Energy per motion tick a resting ant draws from the colony's stock.
[cal] The nest is a resource rather than a waypoint (§3.5).  M1 has no
ant-to-ant trophallaxis — §3.9 defers it, because it is the only
mechanism in the model needing pairwise coupling — so an ant takes from
the common store directly.")

(defparameter *crop-to-energy* 0.35f0
  "Fraction of a unloaded crop that becomes the ant's own energy.  [cal]
The rest goes to nest stock.  Crop is social food and energy is personal
(§3.5); they are separate fields because an ant can starve carrying a
full crop.")

(defparameter *max-age-ticks* 1728000
  "Lifespan in motion ticks.  [lit, converted] 1728000 ticks x 50 ms =
24 hours of simulated time.  A real L. niger worker lives months; this is
deliberately short so that demographics are observable in a run that
finishes, and it is a calibration parameter, not a claim.")

;;; --------------------------------------------------------------------
;;; Colony demographics (§3.10)
;;; --------------------------------------------------------------------

(defparameter *brood-per-stock* 0.5f0
  "Workers produced per unit of nest stock consumed, per colony tick.
[cal] The colony converts food into ants; the coupling, not the rate, is
the point — the trail network thickens because there are more ants, and
there are more ants because the trail network works.")

(defparameter *nest-upkeep* 0.004f0
  "Stock consumed per ant per colony tick.  [cal] Non-zero so that a
colony which cannot reach food starves rather than idling forever —
extinction is a legitimate run outcome (§3.8), and this is the line that
makes it one.")

;;; --------------------------------------------------------------------
;;; Path integration (§3.4)
;;; --------------------------------------------------------------------

(defparameter *pi-noise* 0.02f0
  "Proportional error added to each path-integration increment.  [cal]
PI accumulates error, so a long trip comes home imprecisely.  Without any
noise, homing is exact and the search behaviour deferred to M4 would
never be needed; with too much, the first trail can never be laid.")

(defparameter *homing-weight-low-energy* 3.0f0
  "How strongly a fully spent ant is pulled onto its home vector,
relative to the trail-following choice.  [cal] Applied as a weight that
grows as energy falls, so a tired ant curves homeward rather than
flipping a switch (§3.5).")

(defparameter *nest-arrival-radius* 0.06f0
  "How close an ant must get to the nest centre to unload, metres.
[cal] Must be comfortably larger than the nest disc *and* than the queue
that forms around it.

Set equal to the nest radius at first, and the result was a colony that
died in its own doorway.  A returning cohort of a hundred ants cannot
physically fit inside a 2 cm circle — a hundred 2.5 mm discs need about
1.6x that area — so the non-overlap rule (§3.11) held them in a ring
outside it, no ant ever satisfied the arrival test, and they starved
while touching home.  The diagnostic signature was the mean distance of
returning ants sitting flat at 0.35 m and rising, when it should have
been falling.

The congestion itself is correct and worth keeping: real nest entrances
produce measurable traffic jams (§3.11), and the queue is emergent rather
than modelled.  What was wrong was requiring an ant to reach the *centre*
of a crowd it is part of.")

;;; --------------------------------------------------------------------
;;; Bodies (§3.11)
;;; --------------------------------------------------------------------

(defparameter *relax-iterations* 3
  "Jacobi relaxation iterations per motion tick.  [cal] §8: the
constraint is soft, so residual overlap is bounded rather than zero.  If
a queue at a rich source jitters, raise this before changing the scheme.")

(defparameter *relax-slop* 1.0f-5
  "Overlaps below this are left alone, metres.  [cal] Stops the
relaxation from chasing floating-point noise forever.")

;;; --------------------------------------------------------------------
;;; Types
;;; --------------------------------------------------------------------
;;;
;;; A special variable is type T unless declared, and reading one inside a
;;; declared-float expression forces a generic operation.  These are read
;;; in the tick loop, so declaring them is not tidiness — it is the
;;; difference between inline float arithmetic and a full call.  Rebinding
;;; still works; the type is the contract, not the value.

(declaim (type f32
               *cell-size* *motion-dt* *pheromone-dt* *colony-dt*
               *ant-radius* *walk-speed* *walk-speed-laden* *turn-sigma*
               *sensor-offset* *sensor-spread* *turn-rate*
               *trail-turn-gain* *trail-noise-suppression*
               *choice-n* *choice-k* *choice-eavesdrop*
               *trail-tau* *trail-cap* *trail-deposit*
               *trail-quality-threshold*
               *energy-drain-walking* *energy-drain-resting*
               *energy-return-threshold* *crop-fill-rate* *crop-to-energy*
               *leave-probability* *nest-feed-rate*
               *brood-per-stock* *nest-upkeep*
               *pi-noise* *homing-weight-low-energy* *nest-arrival-radius*
               *relax-slop*))

(declaim (type fixnum *max-age-ticks* *relax-iterations*))
