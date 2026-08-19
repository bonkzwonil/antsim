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

(defparameter *speed-spread* 0.10f0
  "How much individual ants differ in walking speed, as a fraction either
side of the colony's nominal speed.  [lit/cal]  0.10 means every ant
walks somewhere between 90% and 110% of *WALK-SPEED*, fixed for its life
(ANT-PACE).

Defensible from §3.1 rather than invented: the species figure is a
*range*, 1-3 cm/s, and the model had been taking the midpoint and
handing it to every worker identically.  A colony in which every
individual walks at exactly the same speed is the one claim in the
movement model that nothing in the literature supports and that a watcher
notices immediately — a trail of ants in perfect convoy, never
overtaking, never bunching.

Ten percent and not the full range the source quotes.  Three centimetres
a second against one is a factor of three, and a factor of three between
individuals would not be individual variation, it would be two castes;
the quoted range is across studies, colonies and temperatures at least as
much as it is across workers of one nest.  A tenth is a width that reads
as ants rather than as a mixture, and it is small enough that no
calibrated result moves — which was checked rather than assumed, see
below.

What it buys, beyond looking right: overtaking.  A single-speed column
can only ever queue, so every interaction on a trail was a collision
between equals and every jam dissolved only when its cause did.  With a
spread there is a fast ant behind a slow one, which is the condition
every result about lane formation is about — and which M3's second half
needs to have something to sort.

What it costs, and it is worth being explicit because it is not nothing:
energy drains per *tick*, not per metre (§3.5), so a brisk ant covers
more ground for the same fuel and is very slightly the fitter forager.
At ±10% that is a ±10% edge in range on an individual, which is inside
the noise of everything else about a foraging trip, and correcting it
means making metabolism speed-dependent — a real mechanism, and a
separate one.  Recorded here as a known asymmetry rather than papered
over.")

(defparameter *gait-stride* 0.003f0
  "Distance the body advances over one complete tripod cycle, metres
(§5.2).  [cal]

The one parameter of the walk that is *not* free, because the foot is
planted in world space: over the half-cycle a leg spends in stance its
foot must slide backward through the body frame by exactly the distance
the body slid forward, or the ant moonwalks.  So the stride sets the
drawn sweep of the legs as well as the step rate, and the two cannot be
tuned independently — a longer stride is a bigger, slower step, never a
bigger step at the same rate.

At 3 mm and the free walking speed above the colony steps at about 7 Hz,
which is at the slow end of what a real ant does (10-20 Hz) and was
chosen for exactly that reason: the honest rate at this body size is a
blur, and a blur carries none of the information the gait exists to
carry.  It is the one place in the renderer where legibility was
preferred to the measurement, and it is recorded here rather than hidden
in a shader.

It is also, in the other direction, bounded by the legs: the foot has to
reach both ends of the stride, so a longer one needs longer links and
past a point the ant stops looking like an ant.  1.2 ant radii is where
those two pressures meet.

Nothing in the model reads it — the phase it drives is display state
(ANTS-GAIT) and no rule branches on it.")

(defparameter *ant-disc-pixels* 4.0f0
  "Below this on-screen radius, in pixels, an ant is drawn as the plain
disc of §3.11 rather than the vector body of §5.2 (LOD, §5.2).  [tune]

The lowest of the three tiers, and the one that keeps the published
figures alone: every whole-arena frame in the README is at about 3 px per
ant, so those pictures are drawn by exactly the shader that drew them
before this milestone.  It is also simply the right picture — at three
pixels the legs are noise, and an analytic circle antialiases better than
ninety triangles ever will.

Four rather than three and a half, and the half is the whole reason to
write this down.  The README's hero frame works out at 3.57 px per ant,
which put it on the wrong side of a knife edge: a picture whose entire
look flips when someone renders it eight pixels wider is not a figure, it
is an accident.  The threshold belongs clear of the sizes the
documentation actually uses, and this is where that is.")

(defparameter *ant-detail-pixels* 5.5f0
  "Above this on-screen radius, in pixels, an ant gets legs, antennae,
mandibles and payload; between it and *ANT-DISC-PIXELS* it gets the four
body segments only (LOD, §5.2).

One mesh, not two.  The index buffer is ordered legs, body, appendages,
so the simplified ant is a *range* of the full one and the two can never
disagree about where the gaster is.")

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

(defparameter *trail-lane-offset* 0.004f0
  "How far off the centre line of a trail an ant may prefer to walk,
metres.  Each ant draws its own, uniformly in ±this, and keeps it for
life (ANT-TRAIL-OFFSET).  0 restores the old behaviour exactly — every
ant steering to dead centre — which is what makes the difference
measurable rather than asserted.

The old behaviour was a mistake with a very ordinary cause.  Tropotaxis
was written to null the difference between the two antennae, and nulling
that difference *is* the definition of standing on the ridge of the
gradient — so the rule that makes ants good at following trails also made
every one of them follow the identical line.  A deposit is a packet 3 cm
across (*trail-packet-radius*) and the colony was walking it in single
file, shoulder to shoulder, with nowhere to pass and no width for traffic
to sort into.  Real trails are broad; this is what makes this one broad.

**Measured**, 400 ants on an 80 cm trail, three seeds.  Band width is the
mean |lateral offset| of ants in the corridor; blocked is the fraction of
trail time an ant spends with another same-direction ant inside 8 mm and
34 degrees of dead ahead — which is the complaint this fixes, quantified:

    lane    band     blocked   food
    0.000   0.0183   80.0%     877
    0.004   0.0194   64.6%     852
    0.008   0.0238   47.0%     834
    0.012   0.0272   39.9%     739

Eighty percent at zero.  Four ticks in five, an ant on the trail had
another ant right in front of it going the same way.

**4 mm and not 8, and the reason is a second measurement.**  Displacing
an ant's sensing frame displaces its *body* the other way, and the test
for arriving at food asks about the body — so an ant on the outer lane can
walk around a full source and go home empty.  Reported from the window as
a stream of ants curving past food none of them touched.  Measured, on
outbound legs that came within 5 mm of a pile's edge:

    lane    legs close   missed        food
    0.000       2683      1 (0.0%)     3232
    0.004       2520      7 (0.3%)     3048
    0.008       2128     38 (1.8%)     2654
    0.012       1859     27 (1.5%)     2343

The misses are real and scale with the offset, but note that they are not
where the food goes: 1.8% of approaches cannot account for an 18% fall in
delivery.  Most of that is the cost this parameter always had — ants
spread across a road are nearer its edges and lose it sooner — and a
small source makes it much worse than the 80 cm trail measured above,
which is exactly where being 8 mm off the line matters most.

So 4 mm keeps most of the traffic benefit (80% blocked to 65%) for a
third of the delivery cost and a sixth of the misses, and §3.8 passes with
it.  8 mm is available and documented; it is not the better trade.

**Four attempts to fix the miss directly are on record and all of them
cost a §3.8 row**: widening the arrival radius, widening it only for
detection, testing at the sensing point, and testing at the sensing point
on both sides (0.550, 0.558, 0.555, 0.670 against a bar of 0.80).  The
useful by-product was learning that gating eating on WORLD-FOOD-AT is
itself a regression, and that detection and feeding must ask at the same
point or an ant notices food, is told on the next tick there is none, and
leaves with nothing.

The obvious implementation is the wrong one and is recorded because it
looks right.  Steering `bias` to a constant instead of to zero — telling
the ant to hold a given left/right imbalance — measures at -21% food:
`bias` is a *normalised* asymmetry, so a fixed target asks for a
particular gradient shape rather than a particular position, and there is
no such place at a stable distance from a trail whose strength changes as
it is used.  Ants holding one drifted off the trail entirely, and the
blocking metric duly fell, which looked like success and was ants
leaving.  Offsetting the sensing frame in metres asks a question the
geometry can answer.")

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

(defparameter *obstacle-avoidance* 1.0f0
  "How strongly an antenna over terrain vetoes that direction, 0..1 (§3.2).

At 1.0 an ant never *chooses* to turn into a wall it can feel; at 0.0 it
cannot feel walls at all, which is how this model behaved before and is
what makes the difference measurable rather than asserted.

The failure it fixes is not the collision — the collision pass is fine —
it is what the collision pass leaves behind.  Removing only the component
into a wall leaves the component along it, so a blind ant pressed against
a surface slides down it, and because deposition counts attempted motion
it marks the surface while sliding.  The mark then recruits others onto
the same wall.  What that produces is a route bent along an obstacle edge
with corpses on it, which is exactly what the window showed, and it is a
wall-following behaviour nobody wrote.

Antennal contact is how a real ant learns a wall is in front of it, and
the sample points and the terrain mask both already exist — the field
carries the mask because a blocked cell cannot hold pheromone (§3.3).  So
this costs three array reads and adds no new sense.")

(defparameter *homing-scan-steps* 12
  "How far around a blocked bearing a homing ant will look, in 15-degree
steps (§3.2).  0 disables the scan; 12 is a half turn, the most a
deflection can ever be.

*obstacle-avoidance* gave the antennae a veto over the *choice function*
and nothing else, and for a laden ant the choice function is not what
decides where it goes.  The homing term runs afterwards and rotates the
heading halfway to the nest bearing every tick, so whatever the antennae
reported is overwritten before the ant moves.  A returning ant therefore
walked into a wall standing between it and the nest and kept walking into
it: the collision pass removed only the component into the surface, the
ant slid along the face, deposition counted the attempted step, and the
false road so laid recruited outbound ants onto the same wall.  Ants died
strung out along the edge with the source still full.  Fixing the choice
function alone could not touch this, because the ants doing it were not
choosing.

So the bearing gets the same veto: if the nest lies through terrain, the
ant homes on the nearest walkable direction instead.  The scan is not
symmetric — it opens toward whichever side the ant's current heading is
already on.  Without that an ant meeting a wall head-on finds equal
deflections both ways and picks a different one each tick, dithering in
place; with it, the first turn commits and the ant walks the edge until
the bearing comes clear.  That is edge-following as a consequence of
still trying to go home, rather than a wall-following rule of its own.

A half turn rather than the right angle this first had.  A right angle is
the intuitive cap — turn until parallel to the wall, no further — and it
is wrong, because it is measured from the *bearing* and the bearing is
not perpendicular to the wall except at one instant.  Let the ant drift a
few centimetres along the surface and the tangent moves outside the arc,
so the scan finds nothing on the near side and hands the ant a large turn
the other way; measured, it walked 8 mm in 20 000 ticks.  With the full
half turn available and one side scanned before the other, the first
clear direction *is* the tangent, whatever angle the bearing happens to
make with the wall.

It still does not make the home vector a path.  The ant is choosing a
direction from where it stands, with no memory of where it has been, so a
concavity that needs a long detour is still a trap — it walks in, the
bearing comes clear, it turns back to the wall.  The fix for that is
route memory (§3.4), not a wider scan.")

(defparameter *trail-lost-threshold* 0.0f0
  "How faint a trail has to get before an outbound ant decides it has
lost the one it was following, as C/(k+C) of the best antenna (§3.2).
0 disables U-turns altogether, **which is the default**, and the reason
is measurement rather than doubt about the behaviour.

0.15 is the calibrated value if you want them on: C of about 3.5 against
*choice-k* = 20 — well under the strength of a used route and well over
the stray packets an ant meets crossing open ground, so the edge fires
when a trail genuinely runs out and not when one is merely thin.

At 0.15 the rule does what it claims.  One ant walked off the end of a
trail stays with it three times longer, summed over six seeds, and on
one of them never leaves at all — that is the acceptance test.  What it
does not do is pay: over four seeds it is neutral on the double bridge
(2364 units of food against 2368) and costs about 4% in the open
foraging arena (2333 against 2435, population 682 against 708),
consistently in every seed.

Holding ants on a known trail and letting them wander off it are the
same trade seen from two sides, and this model is already stable enough
at the trail-following end that the extra grip costs more in lost
exploration than it returns.  Left off, implemented, and measured, so
that the number is here to argue with rather than an omission to
rediscover.")

(defparameter *trail-follow-threshold* 0.5f0
  "How strong a trail has to have been for an ant to count as having
*followed* it, on the same C/(k+C) scale (§3.2).  0.5 is C = k = 20 —
the concentration at which the choice function's preference for a
marked direction is already decisive.

The pair matters more than either number.  With one level an ant U-turns
whenever it crosses and leaves any faint mark, which on a used route is
most ticks; with two it U-turns only after leaving something it was
genuinely committed to.")

(defparameter *trail-memory-decay* 0.93f0
  "Per-tick decay on an ant's memory of the last trail it smelled.
[cal] Half-lives in about ten ticks, half a second, so the ant is still
'on a trail it just lost' for roughly a body length of walking and not
much more.")

(defparameter *uturn-ticks* 40
  "How long an ant casts about after losing a trail, motion ticks.  [cal]
40 is two seconds at 20 Hz.")

(defparameter *uturn-cast-gain* 3.0f0
  "How much wider an ant's heading noise is while casting.  [cal]

The U-turn alone only sends the ant back the way it came, which finds
the trail again only if it left the trail travelling forwards.  Real
ants that lose a trail turn *and* sweep — the turn puts them back over
the ground they know, the sweep is what re-acquires the line.  Written
as a multiplier on the existing noise rather than a new search mode,
because a wider correlated random walk is what casting is.")

(defparameter *queen-lay-rate* 12.0f0
  "The most eggs one queen lays per colony tick — per simulated minute
(§3.10).  [cal]  0 or less means no ceiling, which is how this behaved
before.

Calibrated against the shipping configuration, which matters: swept on
top of a per-worker reserve the cap looked free at any value above 25,
because the reserve was doing the regulating and the cap was a formality.
Without it the cap *is* the feedback term and the sweep looks nothing
alike.  Over five seeds: 12 delivers the most food and holds twice the
larder of no cap at all, 6 and 9 throttle the colony to half its size,
18 is worse than either neighbour, and 25 and above never bind.

So 12 is a narrow optimum on a non-monotonic response, measured at one
colony size on one scenario.  Treat it as calibration and not as a law —
and note that the development delay alone already lifts the minimum
larder from 8 to 149, so this doubles what is left rather than supplying
the regulation by itself.

There is one queen.  Whatever the larder holds, brood production has a
hard ceiling that food cannot raise, and leaving that out is what let a
windfall become a population spike in the same minute it arrived.  A
colony that can convert any surplus into workers instantly has no
characteristic timescale, so it overshoots every fluctuation and then
starves on the far side of it — which is the oscillation between piling
out and dying that the window shows.

A rate limit is a different kind of regulator from a reserve and the two
do different jobs: *brood-reserve-ration* decides how much the colony is
willing to spend, this decides how fast it can spend it at all.  Neither
substitutes for the other.")

(defparameter *brood-development-minutes* 8
  "How long an egg takes to become a worker, in colony ticks (§3.10).
[cal, compressed]  1 means the old behaviour — brood emerges in the tick
it is paid for.

Real development is weeks; this model runs an hour, so the number is a
compression rather than a measurement and is marked accordingly.  What
it has to preserve is the *sign* of the effect, not its scale: a colony
whose workforce answers a food surplus only after a delay cannot track
its food supply exactly, so it necessarily overshoots and undershoots,
and a population that breathes is the honest behaviour of one.  Brood
that emerges instantly makes the colony a controller with no lag, which
is both unreal and — because it never builds a reserve — more fragile
rather than less.")

(defparameter *forager-maturity-ticks* 0
  "How old a worker must be before it will leave the nest, in motion
ticks (§3.5, §3.10).  [cal, compressed]  6000 is five simulated minutes
at 20 Hz; 0 restores the old behaviour, where an ant could be born and
sent out in the same second.

Temporal polyethism, and it is one of the best-attested facts about ant
societies: a callow worker nurses brood and tends the nest, and takes up
foraging only later in life.  Foraging is the *last* job an ant holds,
which is also why §3.5 can treat a forager as expendable — it is already
near the end of its working life.

Structurally it does something the other two brood rules cannot.  A lay
rate bounds how fast eggs appear and a development time delays their
emergence, but both of those still deliver workers straight into the
foraging pool.  Maturity puts a second buffer *after* emergence, so a
colony that has just doubled its brood does not double its foraging
pressure at the same instant.  The three together give the population an
age structure, which is the thing this model has never had: born, then
developing, then in the nest, then out.")

(defparameter *route-memory* t
  "Whether a laden ant walks the path it came by instead of steering at
the straight-line bearing home (§3.4, §3.9).

**The home vector is a vector and not a path**, and §3.4 has recorded the
consequence since M1: it cannot route around anything, so a returning ant
drives at whatever stands between it and the nest and slides along it.
From the window that is a trail bent along an obstacle's edge with corpses
on it.  The obvious fix — let the trail argue with the bearing — was
measured at M2.1 and is a 29% regression, because an ant that meanders
along a road takes longer to get home than one that drives at the
bearing.

Route memory is the fix §3.4 actually names.  The ant already walks a
path that got it *to* the food, and that path is by construction
walkable: it contains no wall, because the ant did not walk through one.
Remembering it costs a short list of points and turns the return leg from
a bearing into a route.

[lit] The landmark/route mode of *Formica* and *Cataglyphis* — a forager
learns a habitual route and follows it, rather than recomputing a straight
line.  Here it is the ant's own outward track and not learned scenery,
which is the honest abstraction: the model has no landmarks to learn.")

(defparameter *route-waypoints* 12
  "How many points of its outward path an ant remembers.  [cal]

A budget, and *only* a budget: it bounds the memory, never the length of
journey the route covers.  A full list halves its resolution and doubles
its spacing rather than stopping, so twelve points span a 20 cm walk and a
5 m one alike — see ROUTE-DECIMATE!.

This docstring used to argue the opposite, and the argument is worth
keeping as a warning: twelve points at *route-spacing* covers a quarter of
a metre, said the old text, and past that the ant is far enough from where
it started that the straight bearing home is a fair guess again.  It is
not.  The bearing is a fair guess when nothing is in the way, and the
whole reason a route exists is the case where something is.  `two-tribes`
is the counter-example that was already in the repository — 41 cm to a
source behind a wall — and there the exhausted route pointed laden ants
back through the wall.

Costs three floats per ant plus two per point per ant — at the shipped
capacity, under a megabyte for the whole colony.")

(defparameter *route-spacing* 0.020f0
  "How far the ant walks between remembered points at the *start* of a
leg, in metres.  [cal]

Two centimetres, which is a little under one obstacle-avoidance sensing
distance.  Finer spacing does not buy a better route: the ant re-steers
every tick and the points are targets to aim at, not a track to trace.
Coarser spacing lets a corner fall between two points, which is the one
failure that matters — the whole property being bought here is that the
line between successive points is known to be walkable.

Which is why this is the *initial* value and doubles as the buffer fills.
Coarsening is not free by the argument above, so it is spent only where it
must be: on a journey long enough that twelve points cannot span it at
this spacing, where the alternative is not a finer route but no route at
all over most of the walk.  Short journeys — the bridges, one obstacle in
a demo arena — never leave 2 cm.")

(defparameter *route-reach* 0.015f0
  "How close counts as having reached a remembered point, in metres.  [cal]
Comfortably wider than the ant, so a point is not missed by being jostled
past it — an ant that overshoots its target and turns back to it would
stall on the spot.")

(defparameter *search-spiral* t
  "Whether an ant whose path integrator has run out short of the nest
searches systematically instead of wandering (§3.9, M4).

[lit] Wehner & Srinivasan (1981), \"Searching behaviour of desert ants\",
J. Comparative Physiology 142:315.  *Cataglyphis* that reaches the end of
its home vector and finds no nest does not mill about: it runs loops of
steadily growing radius centred on the point the vector ran out.  That is
the optimal thing to do given what the animal knows — the nest is near
that point, and the error in the estimate is unbiased, so the search
should start where the estimate says and widen.

**This is the failure mode path integration actually has**, which is why
it is worth the arithmetic.  A home vector accumulates error over the
whole outward journey (*pi-noise*); when it runs down, the ant is not
lost in general, it is lost within a radius, and the radius is the only
thing it knows.  Before this the model had such an ant fall through to
the correlated random walk — the homing term is skipped once the vector
is shorter than a tenth of a millimetre — which is a search that revisits
where it has been and has no reason to widen.")

(defparameter *spiral-turn* 0.22f0
  "Turn rate at the centre of the search, radians per motion tick.  [cal]

Sets the tightest loop the ant will run: at the walking speed of §3.1 and
a tick of 50 ms, 0.22 rad gives a first circle a couple of centimetres
across, which is about the accuracy the home vector has left when it runs
out.  Starting tighter searches ground the ant has already ruled out.")

(defparameter *spiral-growth* 400.0f0
  "How fast the loops widen: the turn rate is *spiral-turn* / (1 + t/g)
with t the ticks spent searching.  [cal]

The 1/t law is the one that matters rather than the constant.  Constant
speed with a turn rate falling as 1/t traces a spiral whose successive
loops are evenly spaced, which is what covers an area without gaps and
without going over the same ground twice — Wehner's ants do this and the
geometry is why.  A constant turn rate would run one circle for ever.")

(defparameter *spiral-trigger* 0.030f0
  "How short the home vector must get before the ant treats the journey as
finished and starts searching, in metres.  [cal]

Just under *nest-arrival-radius*, so an ant that is genuinely home
arrives rather than starting to search on the doorstep.  Above the radius
the two rules would fight: the ant would begin looping while still
walking in, and the loop would carry it back out.")

(defparameter *repel-weight* 1.0f0
  "How strongly a no-entry mark divides down a direction's choice weight,
as the w in 1/(1 + w·R) (§3.3, §3.9).  0 disables the field's effect on
steering entirely, which is what makes every consequence of it measurable
against the model without it.

**A divisor on the finished Deneubourg weight, not a negative term inside
it**, and the difference is not cosmetic.  Subtracting inside (k + C − R)^n
can drive the base negative, which makes the exponentiation complex for
fractional n and is meaningless besides.  A divisor is bounded, always
positive, and says the honest thing: a marked direction is less attractive
by a factor, never impossible.

[lit] Robinson, Jackson, Holcombe & Ratnieks (2005), \"Insect
communication: no entry signal in ant foraging\", Nature 438:442.
*Monomorium pharaonis* marks unrewarding branches of a trail network with
a repellent, and the mark is read as a negative at the branch point.  The
mechanism matters because it is the colony's only *fast* negative
feedback — evaporation unlearns a route on the trail's own timescale,
which is minutes, and a branch that has just been found empty needs
answering sooner than that.")

(defparameter *repel-tau* 900.0f0
  "Evaporation time constant of the no-entry field, seconds.  [cal]
Divided by *trail-decay-scale* exactly as the trail is, so the two
chemicals stay on comparable clocks and the compression stays one number.

Half the trail's, and the ratio is the point rather than either value.
The colony has to be able to change its mind about a dead end *faster*
than it forgets a road, or the first temporary blockage becomes a
permanent one — an aversive mark that outlives the reason for it is how a
self-organised system talks itself out of a route that came good.")

(defun repel-tau ()
  "Effective no-entry evaporation time constant, seconds.  Compressed by
*trail-decay-scale* exactly as the trail is, so the two chemicals keep
their ratio however hard the clock is squeezed."
  (/ *repel-tau* (max 1.0f-3 *trail-decay-scale*)))

(defparameter *repel-dead-end* 1.0f0
  "No-entry units laid by an ant that walked out, found nothing, and
turned for home.  [cal] One ant's verdict.

**Flat rather than proportional, and deliberately.**  A dead end is
categorical — the direction either led to food or it did not — and there
is no sense in which one empty stretch of ground is emptier than another.
Inventing a magnitude here would be dressing a boolean up as a
measurement.

0 switches the marking off while leaving the field's plumbing in place,
which is what lets the reading and the writing be measured apart.")

(defparameter *repel-cap* 20.0f0
  "Saturation ceiling on the no-entry field.  [cal] Twenty ants' worth of
verdict, past which further agreement changes nothing.

A ceiling matters more here than on the trail.  An aversive mark that
could grow without bound would eventually beat any amount of contrary
evidence, and the colony could never walk that ground again — the failure
mode is permanent, where an over-strong trail merely decays.")

;;; --------------------------------------------------------------------
;;; Alarm (§3.3, M5)
;;; --------------------------------------------------------------------
;;;
;;; The fourth of §3.3's chemicals, and the only one released by something
;;; outside the model.  Nothing in this simulation attacks a nest — there
;;; is no predator, no fighting and no colony that raids another — so
;;; alarm exists exactly when a person pokes one (§5.5).  That is what
;;; makes it M5's chemical rather than M4's: the three mechanisms M4 built
;;; and could not exercise were waiting on preconditions the model does
;;; not produce, and this one's precondition is the mouse.
;;;
;;; It follows that a colony nobody pokes must be *untouched*, not merely
;;; unaffected.  The field is therefore allocated on first release rather
;;; than at construction: with no alarm there is no array, no chemistry
;;; step, and nothing for an ant to read.

(defparameter *alarm* t
  "Whether ants respond to alarm pheromone (§3.3, M5).

NIL leaves the field and its chemistry entirely in place and stops the
ants reading it, which is what lets the plume be measured apart from the
response to it — the same switch *repel-weight* 0 gives the no-entry
field, and for the same reason.")

(defparameter *alarm-tau* 30.0f0
  "Evaporation time constant of the alarm field, seconds.  [lit]

Sixty times shorter than the trail's, thirty times shorter than the
no-entry mark's, and the *ratio* is the character of the chemical rather
than the number.  Alarm substances are small and volatile — they have to
be, to cross the air to a nestmate in the second that matters — and
volatility buys speed at the price of persistence.  A trail is a claim
about where food is and should outlive the ant that laid it.  Alarm is a
claim about *now*, and one that outlived its cause would leave a colony
permanently frantic.

Not divided by *trail-decay-scale*.  That constant compresses the
colony's memory so an experiment fits in a run, and alarm is not memory;
squeezing it would change what the signal *is* rather than how long the
watching takes.

[lit] Hölldobler & Wilson, The Ants (1990), on alarm communication:
active for seconds to a few minutes, and short-lived by design so that a
colony can stop being alarmed.")

(defparameter *alarm-cap* 20.0f0
  "Saturation ceiling on the alarm field.  [cal] The same ceiling the
no-entry field carries, and for a sharper version of the same reason: the
response is a threshold rule, so without a ceiling a long enough poke
would drive a cell to a concentration no amount of decay could bring back
under the panic line inside a run.")

(defparameter *alarm-diffusion* 0.2f0
  "Fraction of the difference to each neighbouring cell that moves per
diffusion sub-step.  [cal] Bounded above by 0.25 — see FIELD-DIFFUSE!.

§3.3 lists alarm as the fast-diffusing field, and this is deliberately
*not* fast enough to be the transport mechanism.  At four sub-steps a
second the plume smears about a cell and a half per tick, which is 7 mm —
enough to give the antennae a gradient to read across their 1.2 cm span,
nowhere near enough to cross a nest.

That is the design, not a compromise.  Making diffusion carry the signal
needs on the order of eighty sub-steps a tick to reach 10 cm, and it
would model alarm as a physical process happening *to* a colony.  What
actually carries alarm through a nest is the ants: one smells it, becomes
alarmed, and releases its own.  Here that is *alarm-release*, and it
means the wave front travels at the speed of a crowd relaying a signal
rather than at the speed of a gas — which is both the real mechanism and
the one that is worth watching.")

(defparameter *alarm-diffusion-steps* 4
  "Diffusion sub-steps per pheromone tick.  [cal] See *alarm-diffusion*
for why this is small.")

(defparameter *alarm-threshold* 1.0f0
  "Concentration at which an ant becomes alarmed.  [cal]

A threshold rather than a graded response, which is the one place this
mechanism resembles the response thresholds of §3.9 and gets to keep
their justification: an ant is alarmed or it is not, and behaviour that
faded smoothly in would show up as a colony that is slightly agitated all
the time.")

(defparameter *alarm-panic* 8.0f0
  "Concentration above which an alarmed ant runs *away* from the alarm
instead of towards it.  [cal]

This is the whole of §3.3's \"aggregation then dispersal\", and it is one
rule rather than a timer.  Below the line an alarmed ant runs up the
gradient — towards whatever is wrong, which is the aggregation — and
because it releases its own alarm on the way, the concentration where the
crowd gathers keeps climbing.  Above the line the same ants turn and
scatter.  Neither phase is scheduled: the sequence comes out of a
positive feedback running into a threshold, which is the same shape as
every other decision in this model.")

(defparameter *alarm-ticks* 400
  "How long an ant stays alarmed once triggered, in motion ticks.  [cal]
400 at 20 Hz is 20 seconds.

A fixed episode rather than \"for as long as it can smell alarm\", and
that distinction is the difference between a model and a runaway.  With
the response tied to the reading, an alarmed ant releases, which keeps
its own reading up, which keeps it alarmed: measured, one poke took 400
of 400 ants and held every one of them alarmed indefinitely, saturating
the arena and starving 244 of them, because a permanently frantic ant
never forages and never goes home to be fed.

A fixed episode also happens to be the honest description of a startled
animal: it runs for a while and then stops, rather than sampling the air
each moment to decide whether to keep running.")

(defparameter *alarm-refractory* 1200
  "How long an ant ignores alarm after an episode ends, in motion ticks.
[cal] 1200 at 20 Hz is one minute.

Habituation, and the thing that makes this an excitable medium rather
than a resonating one.  Without a refractory period a wave re-enters its
own tail: the ants behind the front become susceptible again while the
front is still releasing, and the disturbance never finishes.  With one,
the wave sweeps outwards, passes, and ends — which is what a disturbance
does.

Three times the episode, so an ant that has just run is done running
before it can be started again.")

(defparameter *alarm-release* 20.0f0
  "Alarm units an ant discharges when it becomes alarmed.  [cal]

**A single burst at the moment of alarm, not a rate**, and scaled by the
dose that triggered it: an ant in a saturated plume discharges all of
this, one alarmed by a faint relay discharges proportionally less.  Both
halves came out of measurement, and the second is what makes the
mechanism work at all.

The first version released every tick for the whole episode.  That makes
a fleeing ant paint a twenty-second line of alarm across the arena and
alarm everything it passes, and the result is an epidemic whose
reproduction number rises with how many ants happen to be standing near
each other: measured, the boundary between \"dies out in forty seconds\"
and \"never ends\" sat between 0.25 and 0.3 units a tick, and it *moved
with colony size* — 0.3 was quiet at 35 s with 150 ants and permanent
with 400.  A parameter balanced on a bifurcation is not calibrated, it is
lucky.

One dose-scaled discharge is sub-critical by construction, because a
relayed burst is strictly weaker than the burst that caused it, so a
front damps instead of sustaining.  Measured across a 40x range of this
number and a 5x range of colony size, every run went quiet within 42
seconds — and the size of the response still tracks how many ants were
at home, which is the part that should vary.

It is also what a gland does.  Alarm compounds sit in the mandibular
reservoir and are discharged on stimulation; an ant does not secrete
continuously for as long as it is frightened.

20 is one *alarm-cap* worth: a discharge that saturates the air the ant
is standing in and nothing beyond it.

0 leaves the poke and the response in place and switches the relay off,
which is what makes the two measurable apart.")

(defparameter *alarm-poke* 400.0f0
  "Alarm units a poke releases (§5.5).  [cal]

Spread over the nest disc rather than a point, because the thing being
modelled is a disturbance to a nest and not an ant with a syringe.  Large
against *alarm-cap* on purpose: a poke should put the cells it covers
straight to saturation, so that what follows is the colony's answer
rather than a question about whether the poke was hard enough.")

(defparameter *alarm-speed* 1.6f0
  "Speed multiplier for an alarmed ant.  [cal] Alarm is visible before it
is legible: the first thing anyone should notice about a poked nest is
that it is moving faster.")

(defparameter *necrophoresis* t
  "Whether workers carry corpses out of the nest and pile them (§3.9, M4).

Until M4 nothing removed a corpse, and the concept doc listed that as a
known defect rather than a simplification: a run of any length ends with
the approaches to a busy nest silted up with the colony's own dead, and
the crowding that causes is an artefact of a missing behaviour.

**The model is Deneubourg's, not a rule about tidiness.**  Deneubourg,
Goss, Franks, Sendova-Franks, Detrain & Chrétien (1991), \"The dynamics
of collective sorting\": a worker picks a corpse up with a probability
that *falls* with the local density of corpses, and puts it down with a
probability that *rises* with it.  Neither rule mentions a cemetery and
no ant knows where one is; clusters appear because a corpse is more
likely to be dropped where corpses already lie, and once a cluster starts
it is also the place items are least likely to be removed from.  It is
the same positive feedback the trail runs on, in a different currency,
which is why it belongs in this project rather than being a housekeeping
chore bolted on.")

(defparameter *undertaker-range* 0.010f0
  "How close a corpse has to be to be noticed, in metres.  The antennal
range (*antennal-range*), and the same value for the same reason: a
corpse is recognised by contact, not seen.")

(defparameter *midden-radius* 0.030f0
  "The radius over which local corpse density is felt, in metres.

This sets the *grain* of the sorting and very little else.  Too small and
every corpse is its own cluster because no ant can tell two of them are
near each other; too large and the whole arena reads as one density and
the feedback has no gradient to work on.  Three centimetres is about a
nest radius, which is the scale a midden is supposed to be separate at.")

(defparameter *midden-pickup-k* 1.0f0
  "k1 in the pickup probability (k1/(k1+f))^2, where f is the local corpse
count.  Squared, like every other threshold response in this model, and
for the same reason: a linear falloff makes an ant merely *less* keen to
disturb a pile, where what is wanted is that it substantially stops.")

(defparameter *midden-drop-k* 2.0f0
  "k2 in the drop probability (f/(k2+f))^2.  Larger than *midden-pickup-k*
on purpose: an ant should need more evidence to add to a pile than to
leave one alone, or every chance pair of corpses becomes a midden and the
arena ends up evenly speckled instead of sorted.")

(defparameter *undertaker-rate* 0.08f0
  "Per-tick scale on both probabilities.  [cal]  It sets how *fast* the
sorting runs and not what it converges to — the two probabilities are
ratios, so scaling both leaves the equilibrium alone.")

(defparameter *midden-base-drop* 0.03f0
  "The floor under the drop probability, so a corpse carried out to empty
ground is eventually put down.

Deneubourg's rule alone has none, and without one an ant that picks up
the first corpse in a clean arena carries it for ever: f is zero
everywhere, so the drop probability is zero everywhere, and no cluster
can ever be seeded.  The floor is what breaks that symmetry.  Small,
because it is competing with the density term and a large floor would
scatter corpses at random — which is the behaviour the whole mechanism
exists to avoid.")

(defparameter *midden-min-distance* 0.060f0
  "How far from its own nest an ant will carry a corpse before it will put
it down at all, in metres.

The one rule here that is not Deneubourg's, and it is what makes this
*necrophoresis* rather than sorting: real workers carry refuse away, and
the sorting rules on their own are direction-blind — they would happily
build a midden across the nest entrance.  Three nest radii.")

(defparameter *response-threshold-lo* 0.0f0
  "Low end of the range individual foraging response thresholds are drawn
from; see ANT-RESPONSE-THRESHOLD.  Both ends at 0.0 turns the mechanism
off exactly — the engagement term reverts to the colony's urgency, which
is what every measurement before M4 was taken with.

**The fixed-threshold model** (Bonabeau, Theraulaz & Deneubourg 1996;
Robinson 1992 for the biology).  Every worker carries its own bar for
every task, and engages when the stimulus it perceives clears that bar.
Division of labour is then not assigned by anyone: a colony whose larder
empties raises one stimulus, and the ants with the lowest bars respond
first.  Take those ants away and the stimulus keeps rising until ants
with higher bars respond — which is the whole of the task-reallocation
row in §3.8, and the reason that row says *without any global
controller*.

The spread is the mechanism.  With every ant on the same threshold a
colony has one switch and flips it all at once; with a spread it has a
graded reserve, and that reserve is what makes the response continuous
rather than an oscillation between everybody out and everybody home.")

(defparameter *response-threshold-hi* 0.0f0
  "High end of the range; see *RESPONSE-THRESHOLD-LO*.")

(defparameter *response-steepness* 2.0f0
  "The exponent n in Bonabeau's response function

    R(S) = S^n / (S^n + θ^n)

Two, and for the same reason *CHOICE-N* is two: the nonlinearity is what
makes the response a threshold rather than a slope.  At n = 1 an ant with
a high bar is merely *less* likely to engage at every stimulus, which is
a scaling of the rate and not a reserve; the reserve is the part that has
to hold ants back until the colony needs them.")

(defparameter *age-shade-ticks* 36000
  "The age at which an ant is drawn as fully mature, in motion ticks
(§5.1).  Display only — nothing in the model reads it.  30 simulated
minutes, so a run shows the whole ramp.

Age is shaded only on ants that are not saying something more urgent.
An ant carrying food, sitting at a source, or too spent to set out keeps
its own colour, because those are what the picture is *for*; age is the
background variable and it gets the ants that have nothing else to
report.  Encoding it that way also costs nothing — the instance buffer
packs one float per body, and the states that matter are a short list,
so the rest of the range is free for a ramp.")

(defparameter *brood-investment* 0.1f0
  "The fraction of the breedable larder the colony turns into brood each
colony tick (§3.10).

A rate, not a regulator, and the distinction is worth stating because
capping it looks like the obvious cure for runaway growth and is not.
A reserve expressed as a share of the stock scales away with the stock:
keeping back half and breeding from a tenth of the rest breeds a
twentieth instead of a tenth, which reaches the same fixed point more
slowly.  Stock zero stays the attractor because the quantity protecting
the larder shrinks in lockstep with the larder.

What makes an equilibrium is a reserve measured against the number of
mouths — see *brood-reserve-ration*.  Breeding then stops at a larder
proportional to the population instead of at nothing.  This rate governs
how fast the colony climbs to that line; it cannot decide where the line
is.")

(defparameter *brood-reserve-ration* 0.0f0
  "How much larder the colony keeps back per living worker before it
breeds, as a multiple of *forage-ration* (§3.10).  0 restores the old
rule — breed from the whole larder — so the difference is measurable.

The old rule invested a tenth of the stock in brood every minute and
asked nothing else: not whether the workers it had could feed the ones
it was about to make, not whether the road could carry them.  A rule
with no feedback term has a fixed point, and this one's fixed point is
stock zero.  Traced over forty minutes on the double bridge, the
population climbed monotonically from 169 to 745 while the larder fell
monotonically from 358 to nothing — and delivery was never the problem,
averaging 120 units a minute throughout.  The colony was not starving
because it could not fetch food.  It was starving because it converted
every surplus into mouths and then had no surplus.

Breeding from the *surplus* instead closes the loop.  The reserve is
measured in the same units as *forage-ration* — stock per living worker
— deliberately, because that is already the quantity the colony reads to
decide how hungry it is (COLONY-FORAGE-URGENCY).  One number therefore
means one thing throughout: a colony breeds when it is above the line it
calls comfortable, and forages harder when it is below it.  Nothing new
is measured and no new sense is added.

This is also what real colonies do — brood is fed by trophallaxis from
what foragers bring in, and egg-laying tracks nutrition rather than
running open-loop.")

(defparameter *resting-ants-block* nil
  "Whether ants resting in the nest still collide with everything else
(§3.11).  NIL — they do not — is the model; T restores the behaviour
this had before, so the difference is measurable rather than asserted.

The nest is a disc a couple of centimetres across and a mature colony
rests hundreds of workers in it at once, which cannot be true of a disc
that small.  What the disc actually represents is the *door*; the nest
itself is a chamber system going down, and the model is two-dimensional.
Leaving resting ants in the collision pass therefore puts the entire
resting population in its own doorway, where it obstructs its own
foragers and draws as a crowd many times the size of the nest.

The nest entrance body is already exempt from collision for exactly this
reason — making it solid would seal the colony in — so this is the same
exemption applied to the same fiction, one level further in.

It also pays, once the colony is regulated: 2400 units of food against
2296, with departing ants leaving 27% closer to the exit bearing they
remember (0.308 rad against 0.420).  The mechanism came from watching the
toggle rather than from the numbers — a crowded nest shoves the ants
resting in it, so a departing forager no longer sets off from the spot it
arrived at, and the route fidelity of §3.4 is corrupted before it takes a
step.

An earlier A/B had this costing 10-14%, and that measurement was taken
before brood regulation, on a colony that grew unbounded past 600 ants.
A nest crowd at that size is not the same phenomenon.  An A/B is only
valid against the model it was run on.

Left switchable rather than settled, and bound to N in the live window:
passing runs smoother, colliding looks better, and nothing in the model
ranks those against each other.")

(defparameter *forager-expendability* 1.0f0
  "How far the give-up threshold falls below the departure threshold when
the larder is empty, as a fraction of it (§3.5).  1.0 keeps them equal,
which is how this model behaved before; 0.0 means a forager from a
starving nest never turns back and searches until it dies.

Equal was a bug, and a self-inflicted one.  An ant leaves when its
energy is above the bar, so an ant that leaves at the margin is *at* the
bar, and with one number that is also the bar for giving up — it turned
round on the next tick.  Measured on the double bridge at minute 26 of a
collapse: 560 ants outside the nest, 3 of them carrying anything, and
nothing delivered that minute.  Not a shortage of foragers and not a
blocked entrance; the colony was walking its whole workforce out of the
door and straight back in.  From the window that is the oscillation
between piling out in a panic and dying quietly.

Setting the floor to zero rather than merely lowering it is the
colony's arithmetic, not cruelty.  A nest with an empty larder and a
full complement of rested survivors is dead in an hour either way, so an
ant held back to conserve itself is an ant wasted; the expected return on
spending it is strictly greater.  Foraging is the last caste an ant
belongs to and the risk it accepts rises with the colony's need — the
model just makes that a number.")

(defparameter *trail-homing-suppression* 0.0f0
  "How much a strong trail under a laden ant's antennae overrides its
straight-line bearing home, 0..1 (§3.4).  0 is the bearing always
winning, which is how this behaves.

The home vector cannot route.  It points *through* whatever stands
between the ant and the nest, so an ant that walks into a concavity
cannot leave it: getting out means walking away from the nest, and a
bearing has no way to say that.  Watched on the word scenario, that is
ants piling into the pockets of the letters and dying there — and their
corpses are blocking bodies that nothing removes, so the pocket narrows
and takes the next one more easily.

Following the road home instead is the obvious answer and it was measured
at **-29%** — 262 units of food delivered against 367 — and left out.
That measurement predates the antennal veto (§3.2) and brood regulation
(§3.10) both: it was taken on a model where ants died on walls constantly
and the colony ran at zero reserve.  The nest-occupancy A/B reversed sign
for exactly that reason once the model changed underneath it.

So this exists again to be re-measured rather than because it is
believed.  A negative result is a fact about the model it was measured
on, and this one is two rounds out of date.")

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

(defparameter *forager-eats-at-source* t
  "Whether a forager feeds *itself* at a source before carrying anything
home (§3.5).  NIL restores the old behaviour, in which energy was only
ever restored at the nest.

The crop is the **social** stomach: it is what the ant carries for the
colony, and this model already keeps it separate from personal energy —
an ant can starve carrying a full crop, which is real and is why the two
are different fields.  What was missing is the other half of that
distinction.  A forager standing *on* a food source is standing on food,
and it eats.

Leaving it out meant a forager made the entire return trip on whatever
reserve it set out with, so a long route killed runners in transit no
matter how rich the source at the end of it — and the ants that died
were carrying a full crop, which is exactly the absurdity the separate
fields exist to describe rather than to cause.

Not charged to the source.  A forager's gut is negligible against the
crop it is filling from the same pile, so the bookkeeping would be noise
dressed as rigour — and the consequence that matters is unaffected: a
colony's *reach* stops being set by whatever reserve an ant happened to
set out with.")

(defparameter *nest-meals-per-tick* 2
  "How many resting ants the colony feeds to satiety each motion tick,
hungriest first (§3.5).  0 falls back to the old behaviour, in which
every resting ant sipped *nest-feed-rate* from a common store.

The sip is why a colony starves with food coming in.  Every resting ant
draws 0.002 a tick, so one forager's load — about a unit — is spread over
five hundred ant-ticks; with several hundred ants in the nest that is
roughly one tick each and nobody is fuelled by it.  An empty larder has
meanwhile pushed the departure bar down to about 0.11, so an ant holding
almost nothing still qualifies to leave, walks out, and exhausts.

Watched, that is a ratchet rather than an equilibrium.  Each delivery
lifts the whole nest a hair over the bar at once, the whole nest departs,
and a fraction of it does not come back.  Repeat until the colony is
gone: measured on the word scenario, extinction at T10000 with both
sources untouched and full, and a ring of corpses centred on the nest
door.  The food was never the constraint.  The distribution rule was.

Two properties matter and neither is optional:

  - **Fully restored.** A unit of stock buys one forager that completes a
    trip, or five hundred that get halfway.  Only the first is worth
    anything, and the second is what makes corpses.
  - **Hungriest first.** Serving in table order would feed the
    low-numbered ants for ever, which is an artefact of the array's
    layout.  Serving whoever is nearest empty is fair by construction and
    needs no ordering to be maintained.

This is trophallaxis without the pairwise coupling §3.9 defers — the
recipient side of it.

**Measured, in the regime it exists for.**  On a colony that is *not*
income-constrained this changes nothing, and four early measurements duly
said so — a nest with food to spare does not care how it shares it.  On
one that is, it is the whole difference.  1400 ants on 40 units of stock
(`scenarios/antsim-overload.json`), run to T7200:

    trough   population locks at 644 after 929 deaths, stock pinned at
             zero from T2400 onward, 83 ants able to work.  It does not
             die and it never recovers.
    meals    dips to 851, climbs back to 1146, holds a larder throughout,
             807 able at the worst point.

Ten times the able foragers at the low point, which is the number the
colony's future actually depends on.

Brood regulation (§3.10) stops a colony *growing into* that state, which
is why it is hard to reach by accident now.  It does nothing for a colony
that starts there — so the failure was never cured, only made harder to
provoke.")

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
;;; When two ants meet (§3.4, §3.11, M3)
;;; --------------------------------------------------------------------
;;;
;;; The broad phase has always reported *overlaps to be resolved*.  An
;;; encounter is the same geometry read as an event — this ant met that
;;; ant, at this bearing, going that way — and once the model can see one,
;;; several things that were infrastructure problems become one-line rules.
;;;
;;; What an encounter is allowed to carry is worth stating up front,
;;; because the obvious version is wrong.  **Ants do not tell each other
;;; which way the food is.**  That was tested directly in this genus and
;;; came out negative (Grüter, Czaczkes et al., "No evidence for tactile
;;; communication of direction in foraging Lasius ants", Insectes Sociaux
;;; 2017), and a model that let a contact hand over a bearing would be
;;; inventing a channel the animal has been shown not to have.
;;;
;;; What a contact does carry is *that things are going well*.  A laden
;;; nestmate walking the other way is current, first-hand evidence that
;;; persisting on this course has been paying, where pheromone is an
;;; average over the last several minutes.  So an encounter here changes
;;; how long an ant is willing to keep trying, and never where it points.
;;; That distinction is the whole of the design.

(defparameter *antennal-range* 0.010f0
  "How far apart two ants can be and still be in antennal contact,
metres, centre to centre.  [scale] Two touching ants are 5 mm apart at
*ant-radius*, and an antenna reaches a few millimetres past the head, so
this is contact plus a reach.  0 switches every encounter rule off at
once, which is the off position the tests measure against.")

(defparameter *encounter-cone* 1.5f0
  "Half-angle ahead of an ant within which it reacts to another, radians.
[cal] About 85 degrees, so an ant responds to what is in front of it and
ignores what is behind — which is both what antennae can reach and what
keeps a column from turning itself inside out as ants overtake.")

(defparameter *yield-rate* 0.05f0
  "How hard an ant turns away from one it is about to meet head-on,
radians per motion tick at contact, before its role multiplier.  [cal]
Comparable to *turn-rate*, because giving way is an ordinary steering
correction and not a special manoeuvre.  0 disables it while leaving
recognition and trophallaxis alone.")

(defparameter *yield-laden* 0.25f0
  "Yield multiplier for a laden ant on its way home.  [lit]

Right of way for the loaded, and it is documented rather than invented:
on leaf-cutter trails most inbound clusters are headed by a laden ant
that the others do not attempt to overtake, and in *Eciton* columns the
laden inbound stream holds the centre while outbound ants take the
flanks.  The mechanism reported is exactly this — an asymmetry in how
much each party deviates during the avoidance turn, not a rule about
sides.

Which is why these are three numbers and not a lane assignment.  Nothing
here says 'walk on the left'.  **And measured, lanes do not appear**: on
a 55 cm trail with 600 ants the mean lateral offset between the outbound
and returning streams is about 2 mm either way, less than one
*ant-radius*.  This rule is symmetric in a way the reported behaviour is
not — each ant turns away from where the other actually is, so left and
right deflections cancel across a population, and ANT-HANDEDNESS is a
deliberate even split.  A lane needs a shared convention or a
population-level bias to seed it and there is neither.  What the rule
does buy is throughput, which is a different claim and holds.")

(defparameter *yield-returning* 0.6f0
  "Yield multiplier for an unladen ant on its way home.  [cal] Between
the other two: it has a bearing to hold, but nothing to protect.")

(defparameter *yield-outbound* 1.0f0
  "Yield multiplier for an outbound ant.  [lit] The one that gives way.
Outbound ants deviate most from their heading during avoidance, which is
the asymmetry the whole three-lane structure is reported to rest on.")

(defparameter *yield-overtake* 0.8f0
  "How hard an ant steps aside to pass a nestmate that is *in its way*,
as a multiplier on *yield-rate*.  0 restores queueing.

*speed-spread* had already named the hole this fills: individual pace
exists so that there is 'a fast ant behind a slow one', and a model that
gives ants different speeds and then no way to pass has spent the
variation on nothing.

The trigger is being **obstructed** — same direction, close, nearly dead
ahead — and not being nominally faster, which is what it was at first and
is the wrong question in the one case that matters.  In a stalled column
nobody is moving, so comparing free-walking speeds lets only the ants
that happen to be quicker on paper try to pass and leaves the rest
shoving: a queue whose leader presses an obstacle while everyone behind
presses into the ant in front.

Honest about what it is worth: the aggregate effect measures as null.
What actually washes individual pace out of achieved speed is *load* —
laden and unladen differ by 25% against a plus-or-minus 10% pace spread —
plus collision noise.  It is kept because an ant pressed against the back
of another for seconds at a time is visibly wrong in a way no aggregate
catches, and it costs nothing measurable.")

(defparameter *stranger-avoidance* 2.0f0
  "How much harder an ant turns away from a non-nestmate than from a
nestmate.  [cal]

Recognition itself is not in doubt — a worker discriminates colony
membership by cuticular hydrocarbons on antennal contact, and this is one
of the best-attested facts about ants.  What that recognition *leads to*
is the part being kept deliberately small here: this model gives it
avoidance and nothing else.

No fighting, no recruitment of defenders, no alarm chemistry.  Those are
real and they are §3.12's subject, and a fight is worth having only once
there are two colonies with something to fight over.  What matters now is
that the *channel* exists and that nestmate and stranger already take
different code paths, so adding a consequence later is a rule rather than
an infrastructure change.

The other half of recognition is what does not happen: a stranger is
never fed and never believed.  See ANT-ENCOUNTER-STEP!.")

(defparameter *encounter-confidence* 0.30f0
  "How much a single encounter with a laden nestmate raises an outbound
ant's confidence, 0..1 saturating.  [cal]

Note what is being raised.  Not a heading, not a memory of where food is
— an ant learns neither of those from a contact (see the note at the head
of this section).  It learns that ants are coming back loaded, which
means the ground it is walking has been paying *recently*, and the honest
consequence of that is a longer willingness to keep at it.")

(defparameter *confidence-decay* 0.997f0
  "Per-tick decay on that confidence.  [cal] Half-lives in about 230
ticks, twelve seconds — long enough to carry an ant a good way further
out, short enough that news goes stale.  A colony whose evidence never
expired would keep sending ants down a route for as long as it once
worked.")

(defparameter *encounter-resolve-gain* 0.5f0
  "How far a fully confident ant lowers its own give-up threshold, as a
fraction of it.  [cal] 0 is an exact off position: encounters still
happen, still sort traffic and still feed nestmates, but change nobody's
mind about turning back — which is how the navigational half of this is
measured apart from the physical half.

This is the *only* thing confidence does, deliberately.  One quantity,
one consequence, one measurement.")

(defparameter *partner-memory* 40
  "How long the inspector remembers who an ant last shared food with, in
motion ticks.  [display] 40 is two seconds.

Display only — no rule reads it.  It exists because a trophallaxis lasts
one tick at a time and the panel is read by a person: an event that
appears for 50 ms at 20 Hz, and for rather less than that when the window
is running at 8x, is an event nobody can follow.  Holding it for a couple
of seconds is the difference between a readout and a flicker.")

(defparameter *trophallaxis-rate* 0.004f0
  "Crop transferred from one ant to another per motion tick of contact.
[cal] A full crop takes about 250 ticks — twelve seconds — to hand over
entirely, so a meal is an event with a duration rather than an instant,
and a donor that walks on has given only part of one.

0 disables ant-to-ant feeding.  §3.9 deferred exactly this as 'the only
mechanism in the model needing pairwise coupling', and it is: everything
else an ant does it does to itself or to a field.

**Measured, and it changes sign with range.**  A single source, 200 ants,
24 000 ticks, four seeds, with against without:

    source at 0.55 m     3904 against 3727    +4.7%, and up on every seed
    source at 0.75 m     3003 against 3117    -3.6%, and 35 deaths to 26

The reversal has a mechanism rather than being noise.  A laden ant on its
way home hands food to a hungry ant walking the *other* way.  At moderate
range that ant completes its trip and brings back more than it was given.
At a range where foragers are dying anyway it does not: the crop is gone
from the colony's ledger, only *crop-to-energy* of it ever became usable,
and what it bought was a few more metres of walking away from home.")

(defparameter *trophallaxis-threshold* 1.0f0
  "How hungry an ant must be before a nestmate will feed it in the field,
as a multiple of the colony's own departure bar
(COLONY-ENERGY-THRESHOLD).  [cal] 1.0 means 'too spent to set out again'.

**Not an absolute fraction of a tank, and the first version was.**  At a
flat 0.5 every outbound ant qualified within a minute of leaving — an
ordinary forager dips below half a tank as a matter of course — so laden
returners handed food to essentially everyone they passed, which is
visible from the window as a trail of ants doing nothing but pass a meal
back and forth.  Feeding the merely peckish is not what trophallaxis in
the field is for.

Tying it to the departure bar fixes both halves at once.  It is the right
*quantity*: an ant below it cannot start another trip, so it is the point
at which help changes an outcome rather than topping somebody up.  And it
moves with the colony — a hungry nest lowers the bar
(COLONY-FORAGE-URGENCY), so its foragers are also more sparing with what
they are carrying, which is the correct direction and comes for free.

It is also exactly the threshold the renderer draws as *spent* (§5.1,
ANT-DISPLAY-STATE), so the rule and the picture are the same number: an
ant is fed when, and only when, it is drawn as being in trouble.  That
makes it checkable by eye, which is how the flat version was caught.")

;;; --------------------------------------------------------------------
;;; Bodies (§3.11)
;;; --------------------------------------------------------------------

(defparameter *ant-collision* t
  "Whether two *ants* push each other apart (§3.11).  T is the model; NIL
lets ants pass through one another freely and is a **diagnostic**, not a
species variant.  Bound to `c` in the live window.

Terrain, food piles and corpses still block either way.  Only the ant-ant
pair is switched off, because the question it exists to ask is narrow:
how much of what looks like a navigation failure is actually the crowd?

**Run on the word scenario, and the answer is no.**  12 000 ticks, three
seeds summed; stuck is ants that travel under 3 cm in 400 ticks:

    contact   stuck   of those against terrain   corpses   food taken
    on          197                        171        58        1617
    off         217                        185       114        3259

Ants trapped against terrain are unchanged — 171 against 185, if anything
slightly worse without the crowd.  Take every ant out of every other
ant's way and the same ants are still stuck in the same corners, so the
furball is the *appearance* of the failure and not its cause: bodies pile
up where ants are already failing to leave.  Escaping a concavity is a
navigation problem and no amount of tuning contact or the give-way rules
reaches it.

The other number was not the question and is the larger finding: contact
costs **half the food delivered**, 1617 against 3259 on that scenario and
about 19% on the live-demo arena.  That is congestion at the nest
entrance, at the source, and along every metre between them, and nothing
in this project had measured it before.

**And it cannot be switched off, for a reason that is not realism.**  Run
the §3.8 rows with it NIL and the binary bridge fails in the most
interesting way available: every replicate commits, and *all six choose
the same arm*.  That is a preference, not symmetry breaking, and it is
the one outcome the row exists to rule out.

The likely mechanism is worth stating, flagged as a reading rather than a
measurement: congestion is a **negative feedback**.  A crowded arm is a
slower arm, which pushes some of its traffic to the other one, and that
is what keeps the choice genuinely open long enough for a seed to decide
it.  Take contact away and the earliest tiny lead is amplified without
anything to oppose it, so the same arm wins every time regardless of the
seed.  Deneubourg's result needs the ants to be in each other's way.

So this stays a diagnostic.  It is the fastest way to find out whether a
jam is navigation or crowding — which is what it was built for and what it
answered — and it is not a configuration anyone should run science on.")

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
               *speed-spread*
               *gait-stride* *ant-disc-pixels* *ant-detail-pixels*
               *sensor-offset* *sensor-spread* *turn-rate*
               *trail-turn-gain* *trail-noise-suppression* *trail-lane-offset*
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
               *nest-exit-scatter* *obstacle-avoidance*
               *trail-homing-suppression*
               *forager-expendability* *brood-reserve-ration*
               *queen-lay-rate*
               *brood-investment*
               *trail-lost-threshold* *trail-follow-threshold*
               *trail-memory-decay* *uturn-cast-gain*
               *antennal-range* *encounter-cone* *yield-rate*
               *yield-laden* *yield-returning* *yield-outbound*
               *yield-overtake* *stranger-avoidance*
               *encounter-confidence* *confidence-decay*
               *encounter-resolve-gain*
               *trophallaxis-rate* *trophallaxis-threshold*
               *relax-slop*))

(declaim (type fixnum *max-age-ticks* *relax-iterations* *homing-scan-steps*
               *nest-meals-per-tick*
               *uturn-ticks* *brood-development-minutes*
               *forager-maturity-ticks* *age-shade-ticks*
               *partner-memory*))
