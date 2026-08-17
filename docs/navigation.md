# Navigation, phase 2 — the vector is not the route

A concept for a later phase, expanding §3.4 of `concept.md`. Nothing here
is built. It is written now because the failure it addresses is already
visible in the window, and because the fix that suggests itself first —
make the home vector cleverer — is the wrong one, and that is worth
recording before someone spends a week on it.

## 1. Where this starts

An ant that leaves the nest carries a running vector back to it. Every
tick, `PATH-INTEGRATION-STEP!` subtracts the ant's actual net displacement
from `hvx, hvy`, and a returning ant steers at `(atan hvy hvx)`. That is
the whole of homing. It works: the acceptance row *homing without trail*
passes, the first trail can be laid in virgin territory, and the
recruitment cascade has its seed.

It fails in exactly one way, and the way is well documented in the code
itself. `CLEAR-BEARING` exists because the bearing points *through*
obstacles and the ant used to walk into them, press against them, slide
along them, and lay a trail down the wall that then recruited more ants
onto the same wall. The scan fixed the wall-following, and its own
docstring says what it does not fix:

> Beyond `*homing-scan-steps*` increments the ant gives up and keeps the
> bearing it had. […] An ant in a pocket needs to walk *away* from the
> nest to get out, which a bearing cannot express however wide the scan.

A concave obstacle is still a trap. The ant walks out of the pocket
because the wall deflects it, the bearing comes clear at the mouth, it
turns back in, and it does this until it dies. Widening the scan cannot
help — the scan already covers a half turn — because the missing
information is not *which way is open here*. It is *which way was open
back there*.

There is a second thing worth noticing before proposing anything. The
homing term computes `hv-len` and uses it for one purpose: a validity
check, `> 1.0e-4`. The ant knows how far away home is, to within the
model's error, and throws that number away every tick. Half of what path
integration produces is currently unused.

## 2. The biology, and what it licenses

### 2.1 It really is an inertial system

The mechanism is not a metaphor for an INS; it is one, built from
different parts.

**Attitude reference — the sky compass.** The dorsal rim area of the
insect eye is specialised for the polarisation pattern of the sky, which
is a fixed geometric function of the sun's position and survives cloud
that hides the sun itself. *Cataglyphis* reads e-vector orientation there
and holds a course against it (Wehner, decades of it). The reference
drifts through the day as the sun moves, and the ant compensates with a
learned **ephemeris function** rather than a hard-wired one — a naive ant
has a crude default and refines it with experience. A geomagnetic compass
is also in play, at least during the learning walks a callow ant performs
around the nest entrance before it ever forages (Fleischmann et al.,
2018).

**Odometer — the stride integrator.** The ant counts its own steps. This
is not an inference; it was demonstrated by gluing pig bristles to ants'
legs to lengthen them and cutting other ants' legs shorter, and releasing
both on a homeward run. Stilt-walkers overshot the nest, stump-walkers
stopped short, and both by roughly the ratio of the leg-length change
(Wittlinger, Wehner & Wolf, *Science*, 2006). Ventral optic flow
contributes too, and dominates in bees, but on the ground in a desert ant
the pedometer carries it.

**The accumulator.** Heading and distance are combined continuously in
the central complex, where a population of neurons encodes heading as a
sinusoidal activity bump and a second population accumulates
speed-gated projections of it — a phasor integrator in wetware. The
circuit has been modelled in the bee (Stone et al., 2017) and the
vector-integration half of it directly recorded in the fly (Lyu, Abbott &
Maimon, 2022).

The aviation analogy the mechanism invites is exact enough to be useful
for design: the compass is the attitude reference, the pedometer is the
accelerometer's honest cousin, the accumulator is the IRS, and the nest
is the position fix that zeroes it. Everything an IRS suffers from, the
ant suffers from — drift proportional to time and distance, no absolute
position, graceful failure rather than a wrong answer — and everything an
IRS needs, the ant has, including the fix.

### 2.2 What it does not give the ant

**A route.** This is the whole point of the phase. The home vector is a
*displacement*, and a displacement cannot encode a detour: two ants at
the same place with the same vector will steer the same way whether one
of them has just walked round a wall and the other has not. Real ants
solve this with a second system entirely — memorised panoramic views,
learned in sequence along a familiar corridor, retrieved by scanning and
matching (Graham, Wystrach, Zeil and others). Route memory is not a
refinement of path integration. It is a different sense doing a different
job, and the two are combined by confidence.

**A map.** Whether any insect holds a metric, Tolman-style map that
supports novel shortcuts between arbitrary remembered places is
genuinely contested — argued for in bees, argued against on the grounds
that vector memories plus view memories explain the same data (Cheung et
al. vs Menzel et al.; the debate is live). For ants the conservative
reading is: multiple stored vectors, yes; sequences of learned views,
yes; a surveyor's map in the head, no evidence that needs one. §4 takes
that seriously, because it happens to also be the cheap answer.

### 2.3 The simplification: an accurate vector, deliberately

The obvious refinement — model compass drift and odometer gain as
separate per-ant error channels, so homing goes wrong the way real homing
goes wrong — is **not proposed**, and the reason is arithmetic.

PI error scales with the distance walked. In *Cataglyphis* it is
measured on foraging runs of tens to hundreds of metres, where the
end-point scatter is metres wide and the systematic component is large
enough that Müller & Wehner (1988) could reverse-engineer the ant's
approximate integration rule from the shape of it. Search-pattern width
grows with the length of the home run for the same reason (Merkle, Knaden
& Wehner, 2006).

antsim runs in a one- to two-metre arena. A foraging leg is 30–50 cm. At
any error rate that reproduces the desert-ant literature, a 40 cm run
comes home wrong by a couple of centimetres — comparable to
`*nest-arrival-radius*` (3.5 cm), which exists to accommodate the queue
at the door and already absorbs it. Modelling the error properly at this
scale buys a correction smaller than the tolerance it has to pass
through.

So: **the ant knows the course and the distance to its nest, near enough
exactly.** `*pi-noise*` stays as it is, as an honest small perturbation
and a hook for anyone who wants to run a 20 m arena. What that decision
buys is the whole complexity budget for the thing that is actually
missing, and the rest of this document spends it.

Stated plainly, because it inverts the intuition: at this scale the
interesting fact about an ant is not that its vector is noisy. It is that
a vector is not a route.

## 3. What "map" means here

Four things get called a map, and they are not the same, so this section
fixes the vocabulary the rest of the document uses.

1. **A world map** — an occupancy grid of the arena, in world
   coordinates, consulted by every ant. Cheap to write, and rejected on
   sight: it is a global read, no ant can sense it, and it turns the
   model into a pathfinder wearing an ant costume. The moment an ant
   consults something no ant could have measured, every emergent result
   in §3.8 becomes an assertion instead of a consequence.
2. **A navigation function** — a distance-to-nest field, diffused around
   obstacles, followed downhill. Elegant, correct, and the same objection
   with a nicer gradient. Named here so that nobody proposes it later
   without knowing it was considered.
3. **A private memory of places** — a handful of remembered points, held
   by one ant, expressed in a frame that ant can actually construct.
   This is defensible, cheap, and §4.3.
4. **An externalised colony memory** — a mark in the world that says
   *not this way*, deposited by ants that found out the hard way and read
   by ants that did not. This is not a metaphor either: Pharaoh ants lay
   a genuine repellent "no entry" mark on unrewarding trail branches
   (Robinson, Jackson, Holcombe & Ratnieks, *Nature*, 2005), and §3.9
   already has the no-entry field on the deferred list. §4.4.

The colony gets something that behaves like a map. No ant contains one.
That distinction is the design.

### The coordinate frame, which is the load-bearing trick

An ant has no world coordinates and must never be given any. It does,
however, have an origin: the nest, at the tip of its own home vector.
Every remembered place in this design is stored as **the home vector the
ant would hold if it were standing there** — a nest-centred, ant-derived
frame.

Three consequences, all free:

- It is constructible from state the ant already maintains. Remembering
  where you are is `(hvx, hvy)`, and no new sense is added.
- Memory inherits the integrator's error automatically. If PI drifts,
  every remembered place drifts with it, coherently, exactly as it should
  — no second error model, and no possibility of a memory that is more
  accurate than the system that recorded it.
- It is comparable *between nestmates of the same colony*, because they
  share a nest and therefore a frame. That is what makes §4.4 possible
  without anyone reading a global anything.

With PI accurate (§2.3), the nest frame is the world frame minus a
constant. The implementation will therefore look, at a glance, as though
ants are sharing world coordinates. They are not, and the frame must stay
explicit in the code, because the moment `*pi-noise*` is raised the two
stop being the same thing and every remembered place has to smear with
its owner's error rather than staying pinned to ground truth.

## 4. Four layers, in dependency order

Each layer is useful alone, each is measurable alone, and each is
strictly more expensive than the one before. That ordering is the
schedule.

### 4.1 Layer 0 — use the half of the vector already computed

The ant knows its distance home. Track whether that distance is *going
down*.

One f32 per ant, `hv-best`: the smallest `hv-len` seen since the ant
turned for home. On each tick, if `hv-len < hv-best`, update it. The
difference `hv-len - hv-best` is a progress deficit, in metres, and it is
the only thing an ant needs in order to know it is in trouble — no map,
no memory, no new sense, and no interaction with anything else in the
tick.

By itself this changes no behaviour. It is the sensor the next three
layers steer on, and it is worth landing on its own so that it can be
plotted before anything depends on it. The measurement to make first:
over a run with obstacles, what is the distribution of the deficit for
ants that get home, and for ants that die returning? If those two
distributions do not separate, the rest of this document is wrong and
should be rewritten before it is built.

### 4.2 Layer 1 — commitment, which is what the scan lacks

`CLEAR-BEARING` chooses a direction from where the ant stands, with no
memory of where it has been. That is why the pocket is a trap: at the
mouth of it the direct bearing is clear, so the ant takes it, and it is
back inside.

Add a latch. When the progress deficit exceeds `*detour-trigger*`, the
ant enters a **detour** state: it stops steering on the bearing and
follows the obstacle edge on its own handedness side — which the scan
already produces, and which `ANT-HANDEDNESS` already fixes per individual
for reasons that apply here unchanged. It leaves the detour state only
when `hv-len` beats the value it held at the moment it latched, by
`*detour-release*`. That is the condition the pocket cannot satisfy from
inside, and the mouth can.

This is the pledge/Bug2 family of algorithms, and it is worth being
honest that it was chosen because it is correct and one f32, not because
an ant does it. What an ant does — a real one, in a real detour — is
scan, match a remembered view, and go. The defensible claim is weaker and
still worth making: an ant that is not getting closer to home has
information, it plainly acts on it, and committing to one side rather
than re-deciding every tick is the *same* lesson the code already learned
the expensive way in `ANT-HANDEDNESS` and in the "whole of the preferred
side before any of the other one" comment in `CLEAR-BEARING`. Both of
those exist because an ant that re-decides from local information every
tick oscillates and travels 8 mm in 20 000 ticks. Layer 1 is that lesson
applied to the trip instead of the tick.

Expected cost: detours get longer in the easy cases, because a latched
ant walks past the point where the direct bearing would have served.
`*detour-release*` is the knob and it is a real trade, not a free win.

### 4.3 Layer 2 — the private memory: corners, not paths

Layer 1 gets an ant out of a pocket once. Layer 2 is what makes the
second trip cheaper than the first, which is the observable signature of
route learning and the reason to build it.

**Do not store the path.** A breadcrumb trail of every position is
per-ant state proportional to trip length, it is mostly redundant, and
retracing it is slower than the detour that produced it. Store the
*decision points*: when an ant releases a detour latch, it records one
point — the place where the way home came clear — as a home-vector-frame
coordinate. `*waypoint-capacity*` of these, ring-buffered, four is
probably plenty, and a newborn has none.

On a later trip, a waypoint is consulted only when it is useful, and the
test for useful is geometric and cheap: the ant is heading home, the
remembered corner lies within `*waypoint-relevance*` of the straight line
to the nest, and the ant is further from the nest than the corner is.
Then the ant homes on the corner instead of on the nest, until it reaches
it or the direct bearing beats it.

Two properties fall out and both are worth testing rather than assuming.
An ant that has been round an obstacle once takes a straighter path the
second time — the classic route-learning result, and a clean acceptance
row. And because the exit bearing (§3.4's route-memory stub) already
sends an ant back out the way it came, an experienced forager approaches
the obstacle from a repeatable direction, which is exactly the condition
under which a single remembered corner keeps working.

**Corollary, nearly free: the exit vector should have a length.**
`ants-exit` is a bearing, read off the reversed home vector at the source.
The home vector also has a magnitude at that moment, and storing it makes
the outbound leg a *food vector* rather than a food *direction*: run out
along the bearing for about that far, then switch to local search. That
is what a desert ant does with its outbound vector, it is one more f32,
and it should probably land with this layer since it is the same idea
pointed the other way.

### 4.4 Layer 3 — the colony memory: no-entry, as chemistry

Everything so far is private, and §3.4 already argues at length that a
model where every ant navigates as though it were the first forager gets
the common case wrong. The colony-level version of obstacle memory is a
second field.

Structurally this is free. `field` already carries a concentration, a
deposit buffer folded in on the pheromone clock, a blocked mask, a decay
constant and a cap; a second instance at a coarser cell size is the
cheapest new thing in this document, and `grid.lisp`'s own header says
each further chemical "is a second instance of this same structure rather
than new machinery".

**What deposits.** An ant in a detour latch — an ant that has *measured*
that the way home is shut here — lays repellent behind it as it goes.
Nothing else does. The mark therefore accumulates along the faces of
obstacles that actually obstruct traffic between a source and the nest,
and nowhere else: a wall nobody needs to pass never gets marked.

**What reads it.** The same place the trail is read, in `CHOOSE-TURN`,
with the opposite sign — a repellent term in the Deneubourg weighting.
The framing that keeps this honest is that the map does not get its own
controller: **it is an antenna with memory**, a fourth sample alongside
the three the ant already takes, differing only in that the chemistry
outlives the ant that laid it.

**Why it must decay.** An obstacle is permanent and a mark that decays
looks like an inefficiency. It is not, for two reasons. Obstacles in this
project are *not* permanent — M5 is explicitly about placing and moving
them in a running world — and a colony that has permanently written off a
corridor that was reopened an hour ago is a colony with a bug. And decay
is what makes the mark a claim about traffic rather than about geometry:
a face that stops obstructing anyone stops being marked, and fades.

**The result to look for** is the one visible in the window today and
wrong: the trail that bends along an obstacle edge, with ants dying on
it. With Layer 3 the trail should stand off the obstacle by a margin set
by `*noentry-weight*`, and the standing-off should be visibly *learned* —
absent in the first minutes of a run and present later.

**Where it is weakest.** The repellent is a colony-wide object that no
individual can attribute, so it can only ever say *not here*; it cannot
say *go round the left end*. Handedness supplies the sign at the
individual level and Layer 2 supplies it at the route level, and whether
those three together actually produce a coherent flow round an obstacle,
or a mess with a clean average, is not something this document can
settle. It is the first thing to look at in the window.

## 5. Data model

Per ant, in the struct-of-arrays of `ant/state.lisp`:

| field | type | meaning | layer |
|---|---|---|---|
| `hv-best` | f32 | smallest `hv-len` since turning for home | 0 |
| `detour` | u8 | 0 = none, else latched, side from `ANT-HANDEDNESS` | 1 |
| `hv-latch` | f32 | `hv-len` at the moment of latching | 1 |
| `wp-x`, `wp-y` | f32 × K | remembered corners, home-vector frame | 2 |
| `wp-n` | u8 | how many are valid | 2 |
| `exit-len` | f32 | length of the food vector | 2 |

That is 3 floats and 2 bytes per ant at Layer 1, plus 2K floats at
Layer 2. At K = 4 and 5 000 ants the whole thing is under 200 kB. No
allocation, no free list changes, no per-ant heap — the existing
`MAKE-ANTS` pattern extends unchanged.

Per colony: one more `field`, at a coarser cell than the trail field.
The trail runs at 5 mm because the choice function samples across a
trail's width; a repellent that says "there is something in the way over
there" does not need that, and 2 cm cells cut the memory and the decay
pass by sixteen.

Nothing in this design adds a per-tick pass. Layers 0 and 1 fold into the
existing homing block in the OUTBOUND/RETURNING branch; Layer 2 adds a
loop over K per returning ant, which is a handful of multiply-adds;
Layer 3 rides the pheromone clock that already exists.

**Determinism** is preserved by construction provided two rules hold:
every stochastic draw goes through `rnd01`/`rnd-normal` on a new stream
constant (`+stream-detour+`), never on an existing one, so no decision
becomes correlated with another; and every repellent deposit goes into
the deposit *buffer*, never the concentration, for the reason
`FIELD-DEPOSIT!`'s docstring already gives. The determinism test should
catch a violation of either, and if it does not, that is a gap in the
test.

## 6. Acceptance

New rows for §3.8, in the same spirit: consequences, not features.

| phenomenon | source experiment | what the test asserts |
|---|---|---|
| **Homing round a barrier** | U-shaped obstacle between source and nest | a laden ant reaches the nest; today it does not, and the before/after is the test |
| **Detours do not corrupt the vector** | forced detour, single ant | on emerging, the home vector still points at the nest within the error radius — the property that distinguishes an integrator from a memorised heading |
| **The second trip is straighter** | same ant, same obstacle, two trips | path length on trip 2 < trip 1, over a population and several seeds |
| **The trail stands off the wall** | source behind an obstacle | ant density in the cells adjacent to the obstacle boundary falls, and falls *over the run* rather than from the first minute |
| **Obstacle memory is not clairvoyance** | move the obstacle mid-run (M5) | the colony re-learns; the repellent over the old position fades and the trail re-routes |
| **Nothing changes with memory off** | all four layers disabled | bit-identical to the current model on a fixed seed — the regression guard that keeps every published figure valid |

The last row is the one that protects the project. Every existing figure
and every §3.8 result was produced by the current rule, and a phase that
cannot reproduce them on demand cannot be landed.

Two experiments from the literature become directly reproducible once
this exists, and both are better acceptance tests than anything invented
here because they have published answers:

**The displaced ant.** Catch a homing forager at the source, release it
somewhere else, and it runs its vector — the same course, the same
distance — arriving at a point offset from the nest by exactly the
displacement, and then searches. This is *the* canonical demonstration
that the ant is integrating rather than beaconing, it is trivially
implementable once M5 can pick an ant up, and it is a very good demo.

**Stilts and stumps.** Scale one cohort's stride length up and another's
down and release both on a homeward run: the long-legged overshoot and
the short-legged stop short, in proportion. This one requires the
odometer to be a stride count rather than a displacement — the very
refinement §2.3 declines — so it is an argument for keeping the
integrator's *increment* factored out behind a function even though its
error model stays trivial. One function, no cost, and the experiment
becomes a scenario knob later instead of a rewrite.

## 7. Risks, and what could regress

**A measured regression is the expected outcome of at least one layer.**
§3.4 records that letting the trail argue with the homing urge — an
obviously-more-realistic change — cost 29% of the food delivered over
four seeds, and was reverted. Layers 1 and 2 both make individual trips
*longer* in the common case in order to make rare trips possible at all.
Food delivered per unit time over ≥8 seeds, with and without obstacles,
is the metric, it must be run per layer rather than for the phase as a
whole, and any layer that does not pay for itself gets recorded as a
finding and dropped rather than kept because it is more realistic.

**Search behaviour is still missing underneath all of this.** There is no
`SEARCHING` state: an ant whose vector runs out at the wrong place keeps
its bearing and its noise and either stumbles onto the nest or dies.
Wehner & Srinivasan's expanding-loop search is the right behaviour and it
belongs in the same neighbourhood as this work — but §2.3's argument
means it is a rarity at arena scale rather than the load-bearing failure
mode it is at 100 m, so it stays deferred, and this document should not
be read as having built it.

**The layers can fight.** A latched detour steering one way and a
repellent gradient pushing another can produce an ant that does neither.
This is not hypothetical; it is the same class of failure as the heading
oscillation that `ANT-HANDEDNESS` exists to fix. Layer 0 first, in
isolation, with a plot, is the mitigation.

**Cognitive-map creep.** Every one of these layers has an obvious
"better" version that is a global read: share the corners colony-wide as
data, keep a permanent occupancy grid, compute the route. Each would
work and each would quietly convert an emergent result into an authored
one. The invariant to hold, and to state in the code where it is
enforced: *an ant reads its own state, its own antennae, and fields that
ants deposited.* Nothing else.

## 8. Sequencing

Layer 0 is a day and produces a plot. Layer 1 is the smallest change that
fixes the pocket and is worth landing and measuring entirely on its own.
Layers 2 and 3 are each a milestone's half, and they are independent of
one another — private route memory and colony repellent can land in
either order, which is a good property to have in a schedule.

None of it is M4 as §7 currently defines it, and the honest placement is
alongside the no-entry field already listed there, with Layer 3 *being*
that item rather than an addition to it. The displaced-ant experiment
needs M5's interaction and should be written down as one of the reasons
M5 exists.

## 9. Sources, and what still needs checking

Confident:

- Wittlinger, Wehner & Wolf (2006), *Science* — the stride integrator,
  by stilts and stumps.
- Wehner & Srinivasan (1981) — systematic search as expanding loops
  centred on the vector's end point.
- Müller & Wehner (1988), *PNAS* — the ant's integration rule is
  approximate, and its systematic error has a reproducible shape.
- Robinson, Jackson, Holcombe & Ratnieks (2005), *Nature* — a repellent
  "no entry" mark on unrewarding branches, in *Monomorium pharaonis*.
- Polarised-skylight compass in the dorsal rim area; the ephemeris
  function is learned rather than innate.
- Stone et al. (2017) — central-complex model of the accumulator, in the
  bee; Lyu, Abbott & Maimon (2022) — vector integration recorded in the
  fly.

Needs checking before any number is taken from it:

- **The error rate**, which §2.3's whole argument rests on. The claim
  used here is that PI end-point error scales with run length such that a
  40 cm run is wrong by centimetres. That is an extrapolation from
  desert-ant data at 10–100 m, across two orders of magnitude and across
  species, and it is exactly the kind of extrapolation §8 of `concept.md`
  flags as a high risk. If it is wrong, §2.3 is wrong and the error
  channels of the rejected design come back.
- **Whether *Lasius niger* path-integrates like *Cataglyphis* at all.**
  The reference species is a mass recruiter in cluttered vegetation, not
  a solitary desert forager, and the literature that this document leans
  on is nearly all *Cataglyphis*. PI is present broadly in ants; whether
  it is *dominant* in a species that has a pheromone road to follow is a
  different question, and the answer plausibly makes the home vector
  matter *less* here rather than more.
- **Repellent decay time constant** — Robinson et al. give a lifetime for
  the no-entry mark; `*noentry-tau*` should be fitted to it rather than
  guessed, since §4.4's argument turns on the mark being short-lived
  relative to the run.
- **Whether ants detour by view memory rather than by anything resembling
  Layer 1.** Almost certainly yes, and Layer 1 is a stand-in chosen for
  cost. Worth restating in the code so nobody mistakes it for a claim
  about ants.
- The cognitive-map debate is live and this document takes the
  conservative side of it. If the map advocates are right, Layer 2 is
  under-powered rather than wrong.
