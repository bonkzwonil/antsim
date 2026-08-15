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

(defparameter *trail-turn-gain* 14.0f0
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

(defparameter *trail-noise-suppression* 0.85f0
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

(defparameter *trail-decay-scale* 30.0f0
  "How many times faster than life the trail evaporates.  [display]

The one honest departure from the literature in this file, and it is
here rather than hidden in *trail-tau* so that the real value stays
readable and the compression stays a single number anyone can turn off
by setting it to 1.

The reason is that nothing else in the model runs on the pheromone's
timescale.  A watcher sees minutes; a 21-minute half-life is, over a
session, a constant.  Trails that never visibly fade make the field look
like a painted map rather than a decaying memory, which misrepresents
the one mechanism §3.3 exists to show.

Deposition is deliberately *not* scaled to match — see
TRAIL-DEPOSIT-RATE, which records why the obvious compensation is unsound
and why none turns out to be needed.")

(defun trail-tau ()
  "Effective evaporation time constant, seconds."
  (/ *trail-tau* (max 1.0f-3 *trail-decay-scale*)))

(defparameter *trail-cap* 600.0f0
  "Saturation ceiling.  [cal] A real trail is not unboundedly strong.

Raised from 100, which was far too tight and was doing real damage.
Measured on the gallery scenario with the ceiling lifted, a working route
peaks around 300 and the busiest cells — where traffic converges at the
nest entrance — reach about 890.  Against a cap of 100 that meant every
cell with meaningful traffic pinned to the same value.

The consequences were not cosmetic.  Clipping destroys the gradient
*after* deposition: both antennae read the ceiling, their difference is
exactly zero, and the choice function has nothing to discriminate on
precisely where the trail is strongest.  Deposits are laid with an
exponential falloff and the ceiling was flattening them back out.

A cap this size leaves the route's own profile intact and still saturates
the few hottest convergence points, which is what a saturation ceiling is
actually for.")

(defparameter *trail-deposit* 1.0f0
  "Units laid per motion tick by a laden ant returning from ideal food.
[cal] This is the parameter that *defines* the pheromone unit — see
*choice-k*.  An ant crossing a 5 mm cell at the laden speed spends about
7 ticks in it, so a single pass lays a few units and a trail needs
several passes before it outweighs k.  That is the intended regime: one
ant must not be able to commit the colony.")

(defun trail-deposit-rate ()
  "Units per motion tick at ideal food, for one ant on a packet's worth of
walking.

Deliberately *not* scaled by *trail-decay-scale*, and the reason is worth
recording because the obvious choice is the wrong one.

Steady-state concentration under steady traffic is deposit-rate x tau, so
the tempting move is to multiply deposition by whatever divides tau and
keep the steady state fixed.  That was tried and it is not sound: the
same multiplier also makes a *single* ant's fresh mark that much louder,
and at 30x it put one pass at 43 units against a *choice-k* of 20.  One
ant could then commit the colony on its own, which is precisely the
regime *trail-deposit* documents itself as avoiding.  Under a compressed
tau the two properties cannot both be preserved — a steady state held up
against 30x faster decay *is* 30x louder per deposit — and of the two,
the one that matters is the science.

It happens that no scaling is needed anyway.  A packet spreads over
roughly thirty cells where the old per-tick deposit marked one, and that
division very nearly cancels the compression on its own.  Measured, not
assumed: a busy trail settles around 40 units — comfortably above
*choice-k*, comfortably under *trail-cap*, so the gradient survives
instead of being flattened by the ceiling — and a single pass is worth
about 1.5 units per cell, which is the 'few units' the parameter asks
for."
  *trail-deposit*)

;;; --------------------------------------------------------------------
;;; Trail packets (§3.3)
;;; --------------------------------------------------------------------
;;;
;;; A returning ant does not paint a continuous stripe; it touches its
;;; gaster down at intervals, and each touch leaves a spot that spreads a
;;; little.  Depositing into the single nearest cell modelled neither
;;; part, and the difference is visible: a one-cell-wide trail is thinner
;;; than the sensor span that has to find it, so an ant could straddle a
;;; trail and read nothing on either flank.

(defparameter *trail-packet-spacing* 0.02f0
  "Distance walked between packets, metres.  [cal] Two centimetres — a
few body lengths, so a trail is a row of overlapping spots rather than a
continuous line, and a single crossing lays a handful of them.")

(defparameter *trail-packet-radius* 0.015f0
  "Radius, metres, beyond which a packet contributes nothing.  [cal]
Comfortably wider than *sensor-spread* at the sensing offset, which is
what stops an ant straddling its own trail and reading zero on both
flanks.")

(defparameter *trail-packet-falloff* 0.006f0
  "Length scale of the packet's exponential falloff, metres, in
exp(-d/l).  [cal] About a third of the radius, so the packet is a
concentrated spot with a soft edge rather than a flat disc.  This is the
gradient the alpha channel draws and the sensors read.")

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
probability is how an ant decides to do it.

It is the *rested* rate: see *forage-ration*, which raises it as the
colony's larder runs down.")

(defparameter *nest-exit-scatter* 0.5f0
  "Spread, radians, on the bearing an ant sets off from the nest (§3.4).

An ant that came home from a source leaves again roughly the way it came
in — route fidelity, and it is well documented: experienced foragers
return to a known sector while naive ants strike out at random.  This is
the scatter around that remembered bearing.

Deliberately generous, about 29 degrees, because it is the *only* thing
stopping fidelity from closing the colony's eyes.  With no scatter every
experienced ant would retrace one line, and a colony would never notice a
source that appeared anywhere else.  Exploration is left to the ants that
have nothing to remember — newborns, whose bearing is random from birth,
and foragers that came back empty and so never overwrote theirs.

Before this existed, departure did not set a heading at all: an ant left
with the heading it arrived on, which pointed *inward*, so it walked out
through the nest and away.  Measured over 613 departures on an
established trail, 65% set off within 30 degrees of exactly opposite the
source and not one left straight towards it.")

;;; --------------------------------------------------------------------
;;; Foraging urgency (§3.5, §3.10)
;;; --------------------------------------------------------------------
;;;
;;; Hunger is a colony-level state that an individual can read locally,
;;; because the thing it reads is its own feeding: an ant that asks the
;;; stock for energy and is given none has learned that the larder is
;;; empty without anybody telling it so.  That is the only channel used
;;; here — no ant consults a global variable about food it has not seen.
;;;
;;; This exists because leaving it out deadlocked the colony.  Departure
;;; needed energy, energy came from the stock, and the stock came from
;;; departures; when a source ran dry the three closed into a ring and
;;; every ant lay down in the nest and starved without one of them ever
;;; going to look.  A real colony does the opposite: a hungry colony
;;; forages harder, and its foragers push deeper into their reserve
;;; before turning back.

(defparameter *forage-ration* 0.5f0
  "Stock per live worker that counts as a full larder.  [cal] Upkeep is
*nest-upkeep* per worker per colony tick, so this is a couple of hours of
reserve — enough that a thriving colony sits near satiety and a failing
one does not.")

(defparameter *forage-urgency-gain* 12.0f0
  "Departure rate at an empty larder, as a multiple of the rested rate.
[cal] Large on purpose: an emptying nest should visibly turn itself out
of doors, and this is the number that says so.")

(defparameter *desperate-energy-fraction* 0.25f0
  "How far the energy thresholds fall at maximum urgency, as a fraction
of *energy-return-threshold*.  [cal]

One number moves two thresholds, and it has to move both: the energy at
which an ant will set out, and the energy at which an outbound ant gives
up.  Lowering only the first would send a starving ant out of the nest
and turn it round on the very next tick, which is a deadlock wearing a
different hat.")

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
  "Lifespan in motion ticks.  [cal] 1728000 ticks x 50 ms = 24 hours of
simulated time.  A real L. niger worker lives months, so this is already
a compression, and it is a calibration parameter rather than a claim.

**It is never reached, and that is worth stating plainly.**  The longest
scenario anyone runs is an hour — 72000 ticks, one twenty-fourth of this
— so no ant in this project has ever died of old age.  Starvation is the
only death that has ever fired.  An earlier version of this docstring
claimed the value was 'deliberately short so that demographics are
observable in a run that finishes', which was simply false: at 24x the
run length nothing about age is observable at all.

Lowering it was tried and does not do what it looks like it should.  A
colony whose stock has hit zero is trapped — too many spent ants drawing
upkeep for any of them to be fed back over the departure threshold — and
it is tempting to think that turnover would relieve the pressure.
Measured on the double bridge at 20-minute and 60-minute lifespans
against this one, the colony dies *sooner*, not later: culling ants
removes foragers as well as mouths, so delivery falls at least as fast as
upkeep does.  Killing workers does not create food.

So this stays as it is, honestly labelled, and age-structured demographics
wait for a scenario that runs long enough to have any.  §6's per-colony
`max_age_s` is the right place to set it when that day comes.")

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

(defparameter *nest-arrival-radius* 0.035f0
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
               *trail-tau* *trail-decay-scale* *trail-cap* *trail-deposit*
               *trail-packet-spacing* *trail-packet-radius*
               *trail-packet-falloff*
               *trail-quality-threshold*
               *energy-drain-walking* *energy-drain-resting*
               *energy-return-threshold* *crop-fill-rate* *crop-to-energy*
               *leave-probability* *nest-feed-rate*
               *forage-ration* *forage-urgency-gain*
               *desperate-energy-fraction*
               *brood-per-stock* *nest-upkeep*
               *pi-noise* *homing-weight-low-energy* *nest-arrival-radius*
               *nest-exit-scatter*
               *relax-slop*))

(declaim (type fixnum *max-age-ticks* *relax-iterations*))
