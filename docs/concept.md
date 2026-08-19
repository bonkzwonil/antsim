# antsim — a playful 2D ant colony, built on real science

**Status: concept. No code yet.** This document is the design; it is meant
to be argued with before anything is implemented.

A top-down, GL-rendered simulation of individual ants foraging in a scene
of nests, food sources, obstacles and pheromone fields. Every ant is an
agent with its own state — energy, crop load, age, a home vector, a set of
task thresholds — and every behaviour it runs is a mechanism that has been
measured in real ants and is cited here as such.

Colonies grow from a starting population and can starve to nothing; ants
that die stay where they fell; trails are only ever laid by ants that
walked. **§3.9 is the section to read second** — it is the explicit cut
between the model described here and the much smaller thing M1 actually
builds, because a design this deep ships nothing without one.


> Every tunable is a `defparameter` in `src/params.lisp`;
> [config.md](config.md) lists them with their defaults, which are off,
> and how to override them from a scenario file or the live window.
>
> Measurements live in [experiments.md](experiments.md) — a lab notebook
> recording the runs behind the decisions here, including the ones that
> decided against a change. Every behavioural change carries an
> off-switch so its claim can be measured rather than asserted.

## 1. What this is, and what it is not

**It is a toy that tells the truth.** The point is that you can watch it,
enjoy it, and what you are enjoying is a real mechanism. When a hundred
ants converge on one of two identical paths for no reason at all, that is
not a scripted effect — it is Deneubourg's symmetry breaking falling out of
a nonlinear choice function, and the sim reproduces the published
experiment as a test.

**It is not waldameisen.** waldameisen is a 3D thermophysical model of a
*Formica polyctena* mound: soil columns, microbial heat, a volume
raymarcher, and no ants in the simulation at all until M3. antsim is the
opposite half of the same world — the ants, outdoors, in 2D, individually
visible, doing things you can watch on a timescale of seconds.

What antsim takes from waldameisen is **the engineering, not the model**:

| carried over | why |
|---|---|
| SBCL + ASDF, dependency-free numeric core | the core stays portable and fast; deps live in the render/scenario layers |
| `src/render/preload.lisp` — the libGL trap fix | verbatim. Without it, every frame comes back black on this machine. See §5.4 |
| headless EGL 4.5 core context → FBO → PNG | headless is the *test* path, not a fallback. See §5.4 |
| dependency-free PNG writer (`png.lisp`) | verbatim, plus its CRC/Adler test vectors |
| counter-based RNG keyed on `(id, tick)` | determinism by construction; `*random-state*` stays banned |
| persistent worker pool, fixed partitions | never `make-thread` per tick; fixed ranges keep threaded runs bit-exact |
| struct-of-arrays + specialized `simple-array` | zero allocation in the tick loop, asserted by a test |
| persistent-mapped SSBO for instances | the ant instancing path is already proven at 3 000 instances |
| Makefile with `guix shell nvda@580` GPU targets | GPU work needs the driver from a guix profile |
| "nothing is silently tuned" | every unmeasured parameter is a `defparameter` whose docstring names what it was fitted against |

What antsim does **not** take: the thermal core, the voxel grid, the
raymarcher, the soil/weather model. Different problem.

## 2. Design principles

1. **Every behaviour cites a mechanism.** If a rule cannot be traced to a
   published observation or a named model, it is either a calibration
   parameter (documented as such) or it does not go in.
2. **Emergence is not scripted.** Trail selection, shortest-path finding,
   division of labour and the death of a trail after food runs out are all
   *consequences*, never special-cased. Each has an acceptance test that
   reproduces the published experiment.
3. **Determinism is a feature.** Same scenario + same seed ⇒ byte-identical
   run, single-threaded or threaded. This is what makes the acceptance
   tests meaningful and bug reports reproducible.
4. **Headless first.** The sim must run and render without a window, so it
   can be tested in CI and so results can be inspected as images.
5. **Legibility is a design goal.** An observer should be able to tell what
   an ant is doing by looking at it. State tinting, carried payloads, trail
   intensity and antennal sweep are all in service of that.
6. **Simple first, refined later — and the simplification must still be
   science.** The model below is deep enough to never ship. So M1 takes the
   *smallest* set of mechanisms that can still produce the §3.8 phenomena,
   and every one of them is a sound abstraction of something measured rather
   than a placeholder to be thrown away. §3.9 draws that line explicitly.
   Nothing deferred is deleted; it is scheduled.

## 3. The science model

### 3.1 Species, and the scale it sets

The choice of reference species is not cosmetic — it determines whether
pheromone trails are even the dominant navigation mode.

**Recommendation: calibrate on *Lasius niger*, the black garden ant**, with
species as a swappable parameter set.

The reason is that *Lasius niger* is a **mass recruiter** with the best
quantitative literature on trail laying and following anywhere in
myrmecology, and it is the species behind most of the modulation results
we want to reproduce. *Formica polyctena* — the waldameisen species — would
be the sentimental choice, but wood ants are comparatively *poor* trail
followers: they navigate primarily by visual landmark memory and individual
route fidelity, and their "trunk trails" are largely cleared physical paths
rather than chemical gradients. Building the pheromone core around Formica
would mean building it around the species that uses it least.

So: *Lasius niger* first, `+species-formica+` as a later parameter set that
turns down trail fidelity and turns up route memory. That contrast is
scientifically interesting in its own right and is a good later scenario.

This sets the spatial scale:

| quantity | value | note |
|---|---|---|
| worker body length | ~4 mm | *L. niger* minor worker |
| walking speed | ~1–3 cm/s | approximate; calibration parameter, see §10 |
| arena | 1–2 m square | ≈ 250–500 body lengths |
| pheromone cell | 5 mm | ≈ one body length |
| grid | 400 × 400 per species | 160 k cells — trivial |
| motion tick | 50 ms (20 Hz) | ant moves ≤ 1.5 mm/tick, sub-cell |

Sub-cell movement per tick matters: it means an ant cannot tunnel through a
one-cell obstacle wall, and pheromone deposition never skips cells.

**Walking speed is a range, and individuals sit in it.** The row above
quotes 1–3 cm/s, and the first version of the model took the midpoint and
gave it to every worker identically — which is not what the row says, and
is the one claim in the movement model that nothing in the literature
supports. Each ant now carries a lifelong multiplier, uniform in
1 ± `*speed-spread*` (0.10), drawn from its id and the world seed on its
own stream — the same construction as handedness in §3.4, and for the
same reason: a trait must not be re-rolled every tick, and must not be
correlated with anything the ant decides.

A tenth rather than the quoted range, because a factor of three between
individuals would be two castes rather than variation; the published
range is across studies, colonies and temperatures at least as much as
across workers of one nest. Measured over sixteen seeds on both bridges
it moves neither §3.8 row (experiments.md).

What it buys beyond honesty is **overtaking**. A single-speed column can
only ever queue: every meeting on a trail was between equals, and a jam
dissolved only when its cause did. A spread puts a fast ant behind a slow
one, which is the condition every result about lane formation is about —
so this is also the thing that gives §3.11's traffic rules something to
sort.

One asymmetry it introduces, recorded rather than hidden: energy drains
per tick and not per metre (§3.5), so a brisk ant gets more range for the
same fuel. At ±10% that is inside the noise of a foraging trip, and
correcting it means making metabolism speed-dependent, which is a real
mechanism and a separate one.

### 3.2 Individual movement — the correlated random walk

An ant with no information does not walk randomly in the naive sense. It
performs a **correlated random walk**: each step's heading is the previous
heading plus a turn drawn from a peaked, zero-centred distribution, so the
path is locally straight and globally diffusive.

- Turn angles from a **wrapped Cauchy** distribution with concentration ρ.
  ρ→1 is ballistic, ρ→0 is a pure random walk. Real ant search paths sit
  well toward the ballistic end, which is why searching ants cover ground
  rather than spinning in place.
- **Thigmotaxis**: ants preferentially follow edges and walls. Real, and it
  makes obstacles interesting rather than merely blocking — a wall becomes a
  route.

  **Built, and the reason it had to be is the opposite of what this bullet
  suggests.** The model had *too much* wall-following, not too little, and
  none of it was written. An ant that could not feel terrain kept choosing
  the heading that had put it against a wall; the collision pass removes
  only the component *into* the surface, so what survived was the component
  *along* it. The ant slid down the wall, deposited while sliding (deposition
  counts attempted motion, §3.3), and the mark recruited others onto the
  same surface. The result was a route bent along an obstacle edge with
  corpses on it — emergent thigmotaxis of the worst kind, and one that
  strangled foraging.

  The fix is antennal: the three sample points the choice function already
  computes are also tested against the field's terrain mask — which already
  exists, because a blocked cell cannot hold pheromone — and a direction
  whose antenna is inside terrain is not chosen. Three array reads, no new
  sense, and it is the mechanism a real ant uses to discover a wall is in
  front of it.

  Measured on the double bridge over four seeds: **571 units of food
  delivered against 367**, +55%, with the population up 28% and deaths down
  11%. Both §3.8 bridge rows are unaffected.

  **That fixed half of it, and the half it could not reach was the larger
  one.** The veto applies to the choice function, and a laden ant is not
  steered by the choice function. The homing term runs afterwards and
  rotates the heading halfway to the nest bearing every tick, so whatever
  the antennae reported is overwritten before the ant moves. An ant whose
  nest lay through a wall therefore still walked into it, still slid, still
  marked the surface while sliding — and the false road so laid recruited
  ants that *could* feel walls onto the same wall anyway. Watching it, this
  is a column of ants leaving a good trail at a corner to stream along an
  obstacle edge and fan out, clueless, at its far end, while exhausted ones
  pile against the face behind them and die there with the source still
  full. It was invisible to the choice function because the ants doing it
  were not choosing.

  So the bearing gets the veto too (§3.4): if the nest lies through
  terrain, the ant homes on the nearest walkable direction instead,
  scanned in 15-degree steps.

  Two details are the whole of it, and both were got wrong first, in ways
  worth keeping because each *looked* right and each left the ant walking
  millimetres per thousand ticks.

  - **The ant commits to a side.** Scanned symmetrically it finds equal
    deflections either way and takes a different one every tick, dithering
    on the spot. The first fix derived the side from the ant's current
    heading — an ant already sliding one way should keep going — and that
    cannot work, because a stalled ant is laying pheromone under itself
    and the trail term then steers it into its own mark, so the heading is
    the one quantity that is *not* stable. The side is now fixed per
    individual, drawn from the ant's id and nothing else. That is also the
    better model: lateralisation is documented in ants, and an even split
    sends a colony meeting an obstacle round both ends instead of all one
    way. The preferred side is scanned to exhaustion before the other is
    tried at all; interleaving them reintroduces the dither, because two
    millimetres of vertical bob moves one antennal sample across a cell
    boundary and hands the ant a 150-degree reversal.
  - **The cap is a half turn, not a right angle.** A right angle is the
    intuitive limit — turn until parallel to the wall, no further — and it
    is wrong, because the arc is measured from the *bearing*, which is
    perpendicular to the wall for exactly one instant. Let the ant slide a
    few centimetres and the wall's tangent falls outside the arc. With the
    full half turn available and one side scanned first, the first clear
    direction simply *is* the tangent, whatever angle the bearing happens
    to make.

  Following an edge is thereby a consequence of still trying to go home,
  not a rule of its own — which is what makes it thigmotaxis rather than a
  hack.

  Measured the same way, over four seeds: **2368 units of food delivered
  against 571**, more than four times as much, with the population up from
  181 to 488 — and deaths falling from 126 per run to **0.5**. That last
  number is the diagnosis confirming itself: essentially every death in
  this scenario was an ant stranded on a wall. Both §3.8 bridge rows still
  pass.

  The single-ant regression test is the one that matters, though, because
  neither failure was visible to the suite: one laden ant, one wall
  between it and its nest, does it get home. It asserts the disabled case
  too — a navigation test that also passes without the navigation rule is
  worth nothing, and this one nearly was, twice.
- **U-turns.** An ant that loses a trail it was following performs a
  characteristic U-turn and casts about, rather than continuing. This is
  observed in *L. niger* and is a large part of why trails are stable: the
  ants actively re-find them.

  **Built.** An outbound ant that was on a trail and is now off one turns
  about and walks with three times its usual heading noise for two
  seconds — the turn puts it back over ground it knows, the casting is
  what re-acquires the line. Outbound only: a returning ant that loses the
  trail is not lost, because it has a home vector, and turning it round
  would fight the term that gets it home.

  The trigger needs two levels and that is the entire difficulty.
  Written with one — was the smell above the threshold last tick, is it
  below now — it fires whenever an ant brushes any faint mark and leaves
  it, which on a used route is most ticks. Measured, that cost **28% of
  the food delivered**. The smell has to fall through the middle
  gradually, so the tick that crosses a level always has a reading just
  above it, and one tick of memory cannot express "was properly on a
  trail" at all. What works is a decaying maximum: the ant remembers the
  strongest trail it has smelled for about half a second, and U-turns only
  on leaving something it was committed to.

  **Off by default, and that is a result rather than a hedge.** It works:
  an ant walked off the end of a trail stays with it **three times
  longer**, summed over six seeds, and on one of them never leaves at
  all. It does not pay: over four seeds it is neutral on the double
  bridge (2364 units against 2368) and costs about **4%** in the open
  foraging arena (2333 against 2435, population 682 against 708), in the
  same direction in every seed. Holding ants on a known trail and letting
  them wander off it are one trade seen from two sides, and this model is
  already grippy enough at the trail-following end that the extra hold
  costs more exploration than it returns. `*trail-lost-threshold*` turns
  it on; the numbers are recorded so the choice can be argued with
  instead of rediscovered.
- **Search spirals.** An ant returning on a home vector that does not find
  the nest switches to an expanding spiral/loop search — the documented
  systematic search of a homing ant that has arrived at the wrong place.

### 3.3 Pheromones — the field, and the nonlinearity that matters

Pheromones are **scalar fields on a grid**, one field per chemical, each
with its own decay constant and deposition rule.

> **Trails are never authored.** A scenario configures a field's τ,
> diffusion and ceiling — it never contains a trail. Every field starts at
> zero and every milligram of pheromone in a run was deposited by an ant
> that walked there. There is no path data in the scenario format and no
> way to add any; a trail that appears is a claim the model is making, and
> seeding one would make every result meaningless.

**Fields, in the order they should be built** (M1 builds only the first):

1. **Trail (recruitment) pheromone** — attractive, deposited mainly on the
   *return* trip by an ant carrying food. This is the core positive
   feedback.
2. **Nest / home-range marking** — a colony-specific area mark around the
   nest and its home range. Gives ants a "near home" signal that is not the
   trail, and gives multi-colony scenarios a territorial flavour.
3. **"No-entry" pheromone** — a *repellent* mark applied to branches that
   led nowhere. Documented in pharaoh ants (Robinson et al. 2005) and a
   genuinely different mechanism from "just let the attractant decay". It
   makes the colony visibly prune dead ends, which is lovely to watch.
4. **Alarm pheromone** — a fast-diffusing, fast-decaying field released on
   disturbance, triggering aggregation then dispersal. This is the
   interaction hook: poke the nest, watch it erupt.

**Dynamics per field, each tick of the pheromone clock (1 Hz, not 20 Hz):**

```
C ← C · exp(−Δt/τ)            evaporation — the essential negative feedback
C ← C + D·∇²C                 optional small diffusion (alarm needs it, trail barely)
C ← C + deposits              accumulated from ants since the last pheromone tick
C ← min(C, C_max)             saturation — a real trail is not unboundedly strong
```

Evaporation is not a detail. **It is the mechanism that lets a colony
forget.** Without it, a trail to an exhausted food source persists forever
and the colony never re-explores. Trail half-life for *L. niger* is on the
order of tens of minutes; τ is a calibration parameter (§10).

**The choice function is the heart of the model.** When an ant samples
pheromone concentrations ahead — left, centre, right, via its antennae — it
does not pick the maximum. It picks probabilistically with a **nonlinear**
response, in the form Deneubourg established for the Argentine ant:

```
P(i) = (k + C_i)^n / Σ_j (k + C_j)^n          n ≈ 2,  k ≈ 20
```

`n > 1` is what makes the whole thing work. It means a small concentration
difference produces a *large* probability difference, which is exactly the
amplification that turns a random fluctuation into a committed trail. `k`
sets how much pheromone must be present before the ants care at all — below
it, the choice is near-uniform and the ants explore.

Set `n = 1` and the colony never chooses; it splits evenly between paths
forever. That is a good sanity test to keep.

**Deposition is modulated, not constant.** Beckers, Deneubourg & Goss
showed that *L. niger* lays trail as a function of food quality: richer
sucrose ⇒ more frequent and larger deposits, and **below a threshold
concentration the ants stop laying trail altogether** while still feeding.
That threshold is a beautiful emergent switch — poor food gets eaten but
never recruited to — and it is the reason food sources in this sim carry a
*quality* as well as an *amount*.

So deposition rate is a function of: food quality, crop fullness, distance
travelled since last deposit, and whether the ant is homebound.

**Deposition is by packet, not by tick.** An ant does not paint a
continuous stripe; it touches its gaster down at intervals, and each touch
leaves a spot that spreads. So a laden ant lays a **packet** every
`*trail-packet-spacing*` of *distance walked* — about 2 cm, a few body
lengths — and each packet is splatted into the field with an exponential
radial falloff, `exp(−d/l)`, cut off at `*trail-packet-radius*`.

Both halves of that are load-bearing, and M1 had neither:

- **By distance, not per tick.** A laden ant walks slower than an unladen
  one, so a per-tick deposit lays a *heavier* line for the same journey —
  trail strength would encode walking speed rather than traffic.
  The distance counted is the step the ant **attempts**, read before
  collision resolution pushes it back — the opposite choice from path
  integration, which uses actual net displacement, and both are right.
  Path integration is about where the ant *is*; deposition is about
  walking effort, and an ant shoving against a crowd is still walking.
  The consequence is visible at a bottleneck: queued laden ants keep
  marking while barely advancing, so a congested spot is laid down more
  heavily than open trail, and that mark recruits more ants into the
  queue. Congestion and recruitment know nothing about each other; the
  geometry closes the loop.
- **As a spreading packet, not a single cell.** A one-cell mark is
  narrower than the span the antennae sample, so an ant could straddle its
  own trail with a sensor either side of it and read zero on both. The
  packet is deliberately wider than `*sensor-spread*` at the sensing
  offset.

A packet is **normalised over the cells that actually receive it**, so it
carries the same total wherever it lands — in open ground, against the
arena edge, or beside a wall, where blocked cells are excluded *before*
normalising rather than zeroed after. Without that, trails would thin
exactly where geometry funnels the traffic that makes them.

**Evaporation runs compressed, and says so.** τ for *L. niger* is a
half-life of tens of minutes, and that is the value in the parameter
table. But nothing else in the model runs on that timescale: a watcher
sees minutes, over which a 21-minute half-life is a constant. A field that
never visibly fades reads as a painted map rather than as a decaying
memory, which misrepresents the one mechanism this section exists to
describe.

So `*trail-decay-scale*` divides τ — 30× by default — and is the single
honest departure from the literature in the parameter set, kept as its own
number so the real value stays readable and setting it to 1 turns the
compression off.

**Deposition is deliberately not scaled to match**, and the reasoning is
worth recording because the obvious move is the wrong one. Steady-state
concentration is `deposit-rate × τ`, so multiplying deposition by whatever
divides τ looks like it preserves everything. It does not: the same
multiplier makes a *single* ant's fresh mark that much louder, and at 30×
it put one pass at 43 units against a `k` of 20 — one ant could commit the
colony by walking past once, which is exactly the regime this section says
must not exist. Under a compressed τ the two cannot both hold; a steady
state sustained against 30× faster decay *is* 30× louder per deposit. Of
the two, the science wins.

No compensation turns out to be needed anyway. A packet spreads over
roughly thirty cells where a per-tick deposit marked one, and that
division very nearly cancels the compression by itself.

**The ceiling has to stay out of the way.** `C_max` is a saturation
ceiling — a real trail is not unboundedly strong — but wherever it binds
it destroys information *after* deposition: a clipped cell throws away the
exponential shape it was given, both antennae read the ceiling, their
difference is exactly zero, and the choice function has nothing to work
with precisely where the trail is strongest. Measured on the gallery
scenario with the ceiling lifted, a working route peaks near 300 and the
busiest cells at the nest entrance reach about 890 — against the original
cap of 100, nearly every cell that mattered was pinned, and the trail was
a flat slab both to look at and to steer by. The cap now sits well above
ordinary traffic, so saturation is the exception it is meant to be.

### 3.4 Navigation — three systems, not one

An ant is not a pheromone gradient-follower. It runs at least three
navigation systems in parallel and weights them by confidence:

1. **Path integration (the home vector).** The ant continuously integrates
   its own displacement into a running vector pointing back at the nest.
   This is the desert-ant mechanism, studied to death in *Cataglyphis*, and
   present in most ants. It means a forager that finds food in virgin
   territory with no trail *can still get home* — and then lay the first
   trail on the way. Without PI, the first trail can never exist, and the
   whole recruitment cascade has no seed.
   - PI accumulates error. Model it: add a small proportional noise per
     step, so long trips come home imprecisely and trigger a search spiral.
   - **A vector cannot route.** The home vector points *through* whatever
     stands between the ant and the nest, and for a long time the ant
     followed it there — which is the wall-following failure §3.2
     describes, and it was the single most expensive bug in the model. The
     bearing is now vetoed by the antennae like any other direction: if the
     nest lies through terrain the ant homes on the nearest walkable
     direction instead (`*homing-scan-steps*`). That walks an ant along an
     obstacle and off its end, and it is deliberately not more than that.
     The ant chooses a direction from where it stands with no memory of
     where it has been, so a concavity that needs a long detour is still a
     trap: it walks out, the bearing comes clear, it turns back into the
     pocket. That case needs the route memory below, and the honest
     statement is that the model does not have it yet.
2. **Trail following.** §3.3. Used when trail concentration exceeds the
   detection threshold.
3. **Landmark / route memory.** A learned association between a remembered
   view and a direction. This is the *Formica* mode; the first version
   keeps the stub — a per-ant memory of the last successful food bearing —
   and expands later.

   **Built, as the stub.** Each ant carries one bearing, and sets off from
   the nest along it. It is read straight off the ant's own path
   integrator at the moment it leaves a source: the home vector points
   from the ant to the nest, so its reverse is the nest→food bearing *as
   that ant believes it*. Nothing global is consulted, and no new sense is
   added — this is a reading of state the ant already maintains.

   Three details are load-bearing:

   - **Only a paying trip overwrites it.** An ant that comes home empty
     keeps what it had, so a failed excursion cannot replace a good route
     with a bad one.
   - **A newborn's bearing is random**, which is what makes the naive ants
     the colony's explorers. Together with `*nest-exit-scatter*` (≈29°),
     that is the whole of what stops fidelity from closing the colony's
     eyes to a source appearing somewhere new.
   - **It is taken at the source, not at the nest door.** The first
     attempt used the bearing at which the ant crossed the arrival radius,
     which sounds equivalent and is not: the entrance is packed with
     resting ants, so an arriving forager slides around the cluster and
     comes in tangentially. Measured, that put departures at a peak of
     about 1.5 rad off the source — *perpendicular* to it — because the
     crowd, not the route, was setting the angle.

   Before any of this existed, departure set no heading at all. That is
   not a neutral omission: a returning ant steers *at* the nest, so the
   heading it carries in points inward, and keeping it walked the ant out
   through the entrance and straight on. Measured over 613 departures on
   an established trail, **65% left within 30° of exactly opposite the
   source and not one left towards it**. With the memory in place, 34%
   leave within 15° of it and 2.4% away from it.

4. **Social information — designed, not built.** The three systems above
   are all *private*: an ant navigates on what it has measured itself. Real
   foragers do not. They meet each other on trails and exchange information
   by antennation and trophallaxis, and the encounter itself carries
   navigational content that no private sense provides.

   The content is directional and it is symmetric. A laden ant on a road
   that keeps producing *outbound* nestmates coming the other way has
   strong evidence it is heading toward the nest and on a road worth being
   on — outbound traffic flows away from home, so meeting it head-on means
   home is ahead. The same encounter runs the other way: an outbound ant
   that meets a laden sister learns that there is food behind her, which
   is a far better signal than the pheromone she has been laying, because
   it is current rather than an average over the last several minutes.

   Two things make this worth recording rather than filing under
   embellishment.

   - **Dead reckoning should be the fallback, not the primary.** The home
     vector is what an ant falls back on when it is *alone* — which is the
     situation of the first forager and almost nobody else. A model in
     which every ant navigates as though it were the first forager gets
     the common case wrong, and §3.2's wall-following failure is what that
     looks like from the window: a laden ant driving at a bearing through
     an obstacle because a straight line is genuinely all it has.
   - **It closes a feedback loop the model is missing.** Traced through a
     collapse, the failure is not that ants cannot get home; it is 553 ants
     outbound with exactly one of them at the food. The trail decays because
     too few return laden, and too few return laden because the trail
     decayed — and nothing in the model lets a successful forager tell an
     unsuccessful one anything at all, except by way of a field with a
     time constant far longer than the event. Encounter-based recruitment
     is the fast channel that positive feedback is missing.

   Deliberately not built yet. It needs the broad phase to report ant-ant
   *encounters* rather than only overlaps, and a rule for what is
   exchanged, and both of those are choices worth making on their own
   rather than in the middle of fixing something else.

Weighting these is where personality comes from. An ant with a strong home
vector and a weak trail ignores the trail. This is observed and it is what
prevents a colony from being trivially hijacked by a single strong trail.

**Shading ants by age — wanted, not built.** The body instance packs one
float as `kind + state`, so that channel is entirely spent on behaviour and
age has nowhere to go. Doing it properly means a second attribute in the
instance buffer, with hue carrying state and lightness carrying age, so
both read at once; the alternative — a toggle that swaps the whole
colouring over to age — is cheaper but shows one or the other. Worth
doing once the population actually *has* an age structure to look at,
which is new as of the brood rules in §3.10. The callow tint is the
special case of it that pays for itself immediately: a nest that is mostly
pink has just bred hard and cannot forage on it yet.

### 3.5 Internal state and the foraging cycle

Per-ant state, all of it in struct-of-arrays:

| field | type | meaning |
|---|---|---|
| `x, y` | f32 | position, metres |
| `heading` | f32 | radians |
| `speed` | f32 | m/s, modulated by state and energy |
| `state` | u8 | behavioural mode, below |
| `crop` | f32 | food carried in the social stomach, 0…1 |
| `energy` | f32 | personal reserve, 0…1 — **the return-urge driver** |
| `age` | u32 | ticks alive; drives polyethism and mortality |
| `hv_x, hv_y` | f32 | home vector (path integration) |
| `thr_forage`, `thr_nurse`, … | f32 | response thresholds, §3.6 |
| `nest` | u8 | colony membership |
| `gait` | f32 | stride phase, for rendering (§5.2) |
| `id` | u32 | RNG key, stable for life |

**Behavioural modes**, as a state machine — four live states and `DEAD`:

```
   IN-NEST ──(leaves)──► OUTBOUND ──(food reached)──► AT-FOOD
      ▲                     │                            │
      │                (energy low)                 (crop full /
      │                     │                        food poor)
      │                     ▼                            │
      └───(unload)──── RETURNING ◄───────────────────────┘

   any state ──(energy → 0, or age)──► DEAD
```

**There is deliberately no separate `TRAIL-FOLLOWING` state**, and that is
a simplification that makes the model *more* correct rather than less. An
outbound ant always runs the same rule: sample three headings, weight them
by the choice function, pick. Where there is no pheromone, every weight is
`k^n` and the rule degenerates *exactly* into the correlated random walk of
§3.2. Exploring and trail-following are therefore not two behaviours an ant
switches between — they are the same behaviour in two environments, which
is what the Deneubourg formulation actually says. One state, one rule, no
switching logic to get wrong.

`SEARCHING` — the failed-homing spiral — is a fifth state that M1 does not
need (§3.9); until then a returning ant simply keeps its home vector and
its noise, and finds the nest or does not.

Transitions are driven by continuous quantities, not timers:

- **Energy** drains per tick, faster while walking. As it falls, the return
  urge rises — modelled as a weight on the home-vector direction that grows
  as energy drops, so a tired ant curves homeward rather than flipping a
  switch. At zero, the ant dies. This is exactly the behaviour asked for,
  and it is grounded: a forager's reserve is finite and it must return to be
  fed by trophallaxis.
- **Crop** fills at the food source at a rate set by food quality. Full crop
  ⇒ return. Crop is *social* food, distinct from personal energy — an ant
  can starve while carrying a full crop, which is real, and is the reason
  those two are separate fields rather than one.
- **Trophallaxis** at the nest: the returning ant unloads its crop into the
  nest stock and into nestmates, and takes personal energy back. This is the
  colony's circulatory system and it is what makes the nest a *resource*
  rather than a waypoint.
- **Foraging urgency** rises as the nest's larder runs down, measured as
  stock per living worker. It raises the departure rate and lowers *both*
  energy thresholds — the one an ant needs to set out, and the one at which
  an ant already out gives up and turns back.

That last one is not decoration; leaving it out **deadlocked the colony**.
Setting out required energy, energy came from the stock, and the stock came
from ants setting out. When a source ran dry those three closed into a
ring: every forager came home, dropped under the departure threshold, could
not be fed, and lay in the nest until it died of old age without one of
them ever going out to look. Measured at the time: 499 ants in the nest, 0
outbound, for the rest of the run. A real colony does the opposite — a
hungry colony forages *harder*, and its foragers push deeper into their
reserve before turning back.

A lowered departure bar *alone* would relocate the deadlock rather than fix
it: it would push a starving ant out of the nest and turn it round on the
very next tick. The conclusion drawn from that at the time — that the two
bars are one number — was wrong, and wrong in a way that took a long time
to see, because it is true of the *departure* bar and not of the other one.

### The forager is spent, not saved

An ant leaves when its energy is **above** the bar. So an ant that leaves
at the margin is *at* the bar — and while both bars were one number, it
therefore qualified to give up on its very next tick. A colony under
pressure has most of its workers sitting at exactly that margin, so what
came out was not one ant turning round but the whole workforce oscillating
through the door. Measured on the double bridge at minute 26 of a
collapse:

| minute | population | able to forage | outside | carrying food | delivered |
|---|---|---|---|---|---|
| 20 | 487 | 470 | 424 | 103 | 182 |
| **26** | **587** | **566** | **560** | **3** | **0** |

Five hundred and sixty ants outside the nest, three of them carrying
anything, and nothing delivered that minute. Two candidate explanations
were ruled out by measurement — it is not a shortage of foragers, and it
is not a blocked entrance: laden ants queued outside the unload radius
never exceeded sixteen, and food in transit never exceeded thirty units.
From the window it looks like panic: a colony pouring out and dying anyway
beside a full source.

> **What this does *not* yet establish.** "Outside the nest" counts
> outbound, at-food and returning together, and the difference between
> them is precisely what the diagnosis turns on — an ant that sets out and
> gives up at once is *returning*, not searching. Until those are counted
> separately, the door-oscillation reading is a hypothesis and not a
> result. Two things already argue against it being the whole story: total
> births are flat across every setting of the parameter below (657 / 653 /
> 664 over four seeds), so nothing here changes how much food the colony
> converts into workers.

The two bars are separate quantities regardless, because one number for
both is indefensible on its own terms: an ant leaves when it is *above*
the bar, so with a single number an ant leaving at the margin has already
met the condition for giving up. The give-up bar sits *below* the
departure bar by a margin that widens as the larder empties:

| larder | urgency | departs above | turns back below |
|---|---|---|---|
| full | 0.00 | 0.450 | 0.450 |
| half | 0.50 | 0.281 | 0.141 |
| empty | 1.00 | 0.113 | **0.000** |

At a full larder they coincide and a fed colony behaves exactly as before,
so nothing is thrown away that need not be. As the stock falls the gap
opens, and at an empty larder the forager has no bar at all: it searches
until it dies.

That is the superorganism, stated as arithmetic rather than as sentiment.
Whether to *spend* a forager is the colony's question and the answer
depends on what the colony has left; whether the forager survives is the
forager's, and a colony does not weight the two equally. A nest with an
empty larder and a full complement of rested survivors is dead within the
hour either way, so an ant held back to conserve itself is an ant wasted —
the expected return on spending it is strictly greater. Forager
risk-taking rising with colony need is documented across many species, and
foraging is the last caste an ant belongs to rather than a stage it
survives. What the model contributes is that it is also the arithmetic.

Note what an ant is *not* given here. No ant reads the stock **in the
field**. Urgency is the one colony-wide quantity in the model, and a
forager carries the number it learnt at the door rather than consulting
it as it walks.

**That is still one compromise short, and the compromise is visible in
this section's own prose.** The sentence above used to claim an ant
learns the larder's state "by asking for food while it rests and being
given none" — which is the right model and is not what the code did. The
departure rate and the departure bar both read `colony-forage-urgency`
directly, so an ant in the nest *was* reading stock-per-worker; the
justification was that it is standing on the nest, which is a weaker
argument than the one the docstring was making.

The honest version is the one the prose describes: an ant that is hungry,
resting, and **not served** for some number of ticks has learnt that the
larder is thin, and that is the only thing it needs to know. It grows
keener to leave. An ant that is served promptly learns the opposite. No
aggregate is read by anybody, and the colony's state reaches the
individual through the one channel a real ant has — whether it got fed.

Two things follow that are worth stating:

- **It only became implementable with meals.** Under the communal sip
  every resting ant received `*nest-feed-rate*` every tick, so "was I
  fed?" was always *yes* and carried no information at all. Bounded
  hungriest-first service is what turns being unfed into an event.
- **An energetic ant should not be waiting in the nest to begin with.**
  Whether to set out is a question about the ant's own reserve and its
  own recent experience of being fed — not about a stock level. A full
  ant with no evidence of plenty has no reason to sit still.

Designed, not yet built; the per-ant state it needs is one counter.

The urgency term is the one place the model reads the stock as a
colony-wide quantity, and it is worth being precise about why that is not
telepathy. An ant is fed from the stock while it rests; **being given
nothing is a local fact about its own body**, and that is the signal the
term stands in for. Nothing here tells an ant anything about food it has
not visited, and none of it lets a colony detect a source it has not found.

Extinction remains a legitimate outcome (§3.10). What changed is *how* a
colony dies: in the field with the door open, rather than in bed with it
shut.

### 3.6 Task allocation, age, and the lazy half of the colony

Two mechanisms, both standard, both producing behaviour that reads as
personality:

**Response thresholds** (Bonabeau/Theraulaz/Deneubourg). Each ant has a
threshold θ per task. It engages when the task's stimulus S exceeds θ, with
probability S²/(S² + θ²). Thresholds adapt: performing a task lowers its
threshold, not performing it raises it. From identical ants with slightly
different thresholds, **specialization emerges** — some ants become foragers,
others nurses, and the colony reallocates automatically when you remove
half the foragers. No central control anywhere.

**Age polyethism.** Young workers work inside (brood care, nest
maintenance); older workers move outward and become foragers. Foraging is
the most dangerous task and is performed by the ants with the least
remaining life — the colony is spending its most expendable members. Model
as an age-dependent bias on the task thresholds.

**Inactivity is real.** A large fraction of workers in a real colony are
doing nothing at any given moment, and "inactive" behaves like a genuine
specialization rather than sampling error. The sim should show this rather
than hide it: a nest with visibly idle ants is more correct, not less.

### 3.7 Food sources and obstacles

**Food** carries two independent quantities:

- **amount** — depletes on consumption; at zero the source is gone and the
  trail to it dies by evaporation alone, with no special case anywhere.
- **quality** — sets crop fill rate *and* trail deposition rate (§3.3), so a
  rich source out-recruits a poor one even when both are equidistant. This
  is the mechanism behind collective source selection.
- optional **renewal rate** — aphid honeydew regenerates; a seed pile does
  not. One parameter covers both.

**Obstacles are polygons.** They are static, authored, and often want to be
straight, long or awkwardly shaped — a wall, a leaf, the rim of a dish —
and a polygon says all of that exactly, where a chain of discs only
approximates it and costs more to test. They are kept in three
representations: the polygon for rendering, its edge list for collision
(§3.11), and a rasterized blocked-cell mask for masking pheromone
diffusion and for cheap broad-phase rejection.

Food is worth one note here: **a food source is a blocking body, not a
marker you walk through.** Ants must physically reach its edge, which means
they crowd and queue at a rich source. Crowding is a real constraint on
foraging rate, and getting it for free from the collision rule is better
than modelling it.

### 3.8 What must emerge — the acceptance list

These are not features. They are consequences, and each one is a test:

| phenomenon | source experiment | what the test asserts |
|---|---|---|
| **Symmetry breaking** | Deneubourg binary bridge, two equal paths | ≥80% of traffic on one arm within N minutes; which arm varies with seed |
| **Shortest path selection** | Goss double bridge, unequal arms | the short arm wins, reliably, across seeds |
| **No selection without nonlinearity** | set n = 1 | traffic stays ~50/50 — proves the choice function is doing the work |
| **Quality-driven selection** | Beckers, two sources differing in quality | the richer source wins even at equal distance |
| **No trail below quality threshold** | Beckers | poor food is exploited but not recruited to; no trail forms |
| **Trail death** | deplete the source | trail decays to background on the evaporation timescale, colony re-explores |
| **Task reallocation** | remove 50% of foragers | forager count recovers from the nurse pool, without any global controller |
| **Homing without trail** | single ant, virgin arena | path integration returns it to the nest within its error radius |
| **Colony extinction** | nest placed out of foraging range | stock falls, births stop, population decays to zero — starvation is a legitimate run outcome, not a bug (§3.10) |
| **Bodies never interpenetrate** | dense crowd at one small source | no two blocking bodies overlap after the relaxation pass, at any density (§3.11) |
| **Competition** *(post-M1)* | two colonies, one contested source | the nearer colony wins the source; raising ε visibly degrades both colonies' trail fidelity (§3.12) |

That table is the project's definition of "working".

**Status (M4).** Every in-scope row now passes, and the competition row
with them. M4 closed the three that had been open since M1 — quality-driven
selection, no trail below the quality threshold, and task reallocation —
and added apparatus for each in `src/world/trials.lisp`, alongside the
bridges.

- **Quality-driven selection.** Eight runs, mirrored left and right so a
  *side* preference cannot be mistaken for a quality one — the model has
  per-ant handedness in it, so that was a live alternative. All eight went
  to the richer source, mean 0.72. Asserted as an aggregate, because the
  equal-quality control over eight seeds ran 0.387 to 0.911: a single seed
  breaks symmetry here exactly as it does on the binary bridge, so a
  per-replicate bar would assert the absence of a phenomenon the model is
  supposed to have.
- **No trail below the quality threshold.** Sharp. Below 0.30 the colony
  takes ~800 units and the field holds *exactly* zero; above it a trail
  forms and the visit count triples. Both halves at once, which is the row.
- **Task reallocation.** The share of the colony out of doors goes 0.844
  before a 50% cull, 0.731 after, and back to 0.844 within 75 simulated
  seconds. A *share* and not a count — a count would recover on growth
  alone and say nothing about allocation.
- **Competition.** The nearer colony took the contested source in all six
  replicates, mean 0.584.

**ε needed its claim restated, and the restatement is a result.** The
first apparatus put two nests either side of one pile, where each colony's
field lies almost entirely where the other's does not — fidelity was flat
in ε from 0 to 1 for want of anything to confuse. On crossing routes,
raising ε makes each colony's field *more* concentrated, 0.496 to 0.601,
while both colonies harvest less. That is a merged trail network: two
colonies reading each other's marks converge on one shared set of roads,
thinner than two separate ones and leading half of each colony to the
other's food. So fidelity here has to mean *correctness* — the share of a
colony's mark lying on the way to its own source — and not thinness. A
little eavesdropping helps: route fidelity peaks at ε = 0.3, which is an
argument for the shipped ε being small rather than zero.

**A bug the apparatus found before any behaviour did.** Food amount was
single precision, and a source is the one accumulator in the model whose
magnitude and increment are six orders apart: a 0.02 take on a 500 000-unit
pile is under half an ulp, so the subtraction rounded back to where it
started and a large source could be eaten from for ever without going
down. Amounts are double now.

**Historical status (M1–M3).** Seven of the ten in-scope rows passed. The two that are
published *experiments* rather than properties — symmetry breaking and
shortest-path selection — are implemented as such, on the apparatus in
`src/world/bridge.lisp`, and run by `make acceptance`; measured across
eight seeds, the binary bridge commits at ≥93% with the winning arm
varying by seed, and the double bridge picks the short arm 8 times out of
8 at a length ratio of 1.73. Trail death, homing without a trail, colony
extinction and non-interpenetration are in the fast suite.

Two of the seven carry a caveat, recorded here rather than quietly
enjoyed: the `n = 1` control is asserted on the choice function's
probabilities rather than on bridge traffic, and non-interpenetration on
a synthetic crowd rather than a scrum at a small source. Both should
graduate to their apparatus.

Those three — quality-driven selection, no trail below the quality
threshold, and task reallocation — were closed at M4, above.

### 3.9 The M1 cut — what actually gets built first

Sections 3.1–3.8 describe the model. **They do not describe M1.** Left
unchecked the science above is a multi-year project, so M1 takes the
smallest subset that can still produce §3.8, and each item in that subset
is a defensible abstraction rather than a stub.

The test of a good cut is that nothing removed is *load-bearing for the
acceptance list*. Everything below passes that test.

| mechanism | M1 | the simplification, and why it is still science |
|---|---|---|
| Correlated random walk | **in** | Gaussian turn instead of wrapped Cauchy. Same locally-straight, globally-diffusive path; the tail shape is a refinement, not a mechanism. |
| Trail pheromone field | **in** | One field. Decay + deposit + ceiling. No diffusion — real trail pheromone barely diffuses on the timescale that matters. |
| Deneubourg choice function | **in** | Unchanged. This is the one thing that must be exactly right, because §3.8 is a test *of* it. |
| Path integration | **in** | Home vector with proportional noise. The mechanism that seeds the first trail; without it nothing else happens. |
| Foraging state machine | **in** | Four states (§3.5). No `TRAIL-FOLLOWING`, no `SEARCHING`. |
| Energy + crop | **in** | Two scalars, linear drain and fill. Return urge as a weight on the home vector. |
| Food amount + quality | **in** | Depletion and quality-modulated deposition — both are load-bearing for two acceptance rows. |
| Obstacles | **in** | Polygons, with a rasterized mask for broad-phase and pheromone blocking (§3.7). |
| Disc bodies + non-overlap | **in** | §3.11. One rule, Jacobi resolution. Cheaper than the alternatives *and* the thing that makes crowding emerge. |
| Colony growth and death | **in** | §3.10 — a birth rate, not a brood model. Extinction falls out of the same line. |
| Corpses as bodies | **in** | Dying leaves a blocking disc. Passive — it costs one body kind and nothing else, and it makes the missing behaviour visible. |
| Per-colony trail fields + ε | **in** | §3.12. M1 runs one colony, so ε never fires — but the indirection is free now and unaddable later. |
| — | — | — |
| No-entry field | **built, M4, inert** | A second field per colony, read as a divisor 1/(1 + w·R) on the finished Deneubourg weight — not as a term inside it, which can drive the base negative. Correct, tested, and it does nothing at shipped parameters: the only trigger available marks where an ant *gave up*, and give-ups scatter, so the field peaks at 0.01 against a cap of 20. See `*repel-weight*`. |
| Alarm and nest-marking fields | *later* | The other two. Neither is needed for §3.8, and each is the same self-contained addition the no-entry field turned out to be. |
| Response thresholds | **built, M4, off** | Bonabeau's fixed-threshold model: every worker carries its own bar, drawn on its id, and answers one colony-wide stimulus through R(S) = S^n/(S^n + θ^n). Nothing counts foragers. Off because the stimulus is bimodal — a colony sits at urgency 0.000, or at 1.000 within minutes of its larder failing, and there is no graded middle to slice. See `*response-threshold-lo*`. |
| Age polyethism | **built, M2.1, off** | `*forager-maturity-ticks*`. Measured at M4: turning it on damps task reallocation exactly as it should — the share out of doors recovers to 0.79–0.90 of pre-cull instead of 0.97–1.02, and harvest falls about 8% — because callow workers genuinely cannot be conscripted. Correct, and it is why the §3.8 row passes cleanly with it off. |
| Trophallaxis between ants | **built, M3** | The pairwise coupling, and it really was the only one — but it rides on the encounter event rather than needing machinery of its own, which is why it arrived with M3 rather than M4. The tick stays order-independent because donors accumulate into a buffer instead of writing to each other. Changes sign with range; see `*trophallaxis-rate*`. |
| Landmark / route memory | **built, M4** | The ant remembers its own outward track as a short list of points and falls back to it **only when the bearing home is blocked** — a route is what you use when the vector cannot be walked, not a thing to retrace. On the word scenario, whose whole geometry is concavities, harvest goes 888 to 1264 and corpses 140 to 119; on an arena with one small wall it changes nothing, which is the right shape of result. §3.8 untouched. The first mechanism this milestone that both pays and survives the bridge. |
| Thigmotaxis | **built, M2.1** | Not an addition but a *correction*: the model had wall-following nobody wrote, and it was starving colonies. See §3.2. |
| U-turns | **built, M2.1, off** | Works — trail residence ×3 — and does not pay: neutral on the bridge, −4% foraging. §3.2. |
| Search spirals | **built, M4, inert** | Wehner's systematic search: turn rate falling as 1/t, which is what traces evenly-spaced loops. It fires and works — raise `*pi-noise*` to 0.5 and one seed's homing goes from 5765 ticks to 304 — and on a colony it changes the harvest by nothing at all, 529 against 529. Path integration here is accurate enough that the failure it exists to fix does not occur. |
| Necrophoresis | **built, M4** | Deneubourg's collective sorting, plus two rules his does not have: a floor under the drop probability, or the first corpse lifted in a clean arena is carried for ever, and a minimum distance from the nest, because his rules are direction-blind and would build a midden across the front door. Clumping roughly doubles and the nest goes to zero. Its own §3.8 row. |
| Multiple colonies | **built, M4** | The data model supported them from day one (§3.12) and it held: two colonies needed no change to the tick. What M4 added is the apparatus to test them, an honest per-colony harvest counter, and tribe colouring — the gaster keeps behaviour, the head and mesosoma carry the tribe. |

The rule for adding anything back: **it must be addable without changing
the tick's shape.** Every deferred item above is either a new field on an
existing grid, a new scalar on an existing ant, or a new state on an
existing machine. None requires rewriting M1.

### 3.10 Colony growth — a population, not a headcount

A run **starts with a configured population and grows from there.** The
starting count is a free parameter — a couple of founders, or a mature
colony of a few thousand, whichever the scenario wants. What changes is
that it is a *starting* count rather than *the* count: births and deaths
run from tick one, so the population is a state variable, not a setting.

That coupling is the interesting part — the trail network thickens because
there are more ants, and there are more ants because the trail network
works. Seeding a colony at its mature size just means starting near
equilibrium instead of climbing to it; both are legitimate, and which one
a scenario wants depends on whether the growth curve is the subject.

- **Capacity** is a configured upper bound on the ant table — a memory
  budget, not a target. The SoA table is allocated once at capacity (§4.2)
  and a liveness mask says which slots are alive, so growth is free: birth
  claims a slot from the free list, death returns it. This is exactly why
  the table was fixed-capacity to begin with.
- **Birth rate** was a function of nest food stock: the colony converted a
  fixed share of what it held into new workers each tick, clamped at
  capacity. A colony that forages well grows; one that cannot feed itself
  shrinks. That coupling is the whole point and it is one line of
  arithmetic — and one line of arithmetic with no feedback term in it,
  which is where the trouble was.

  **A growth rule with no feedback has a fixed point, and this one's was
  zero reserve.** Every surplus became mouths, the mouths consumed the
  next surplus, and the colony climbed until its upkeep matched everything
  its foragers could carry. Traced over forty minutes on the double
  bridge: population 169 → 745, larder 358 → 0, both monotonic — with
  delivery averaging 120 units a minute throughout. The colony was never
  failing to fetch food. It was spending all of it on workers to fetch
  more, so it held no buffer, and a colony with no buffer cannot absorb
  the jams and trail collapses this simulation produces constantly. Every
  "colony starves beside a full source" run traces back here.

  Brood now comes out of the **surplus** over a reserve of larder per
  living worker, measured in the same units as the foraging urgency of
  §3.5 — so one quantity carries one meaning throughout: above the line
  the colony breeds, below it the colony forages harder.

  A reserve expressed as a *share of the stock* cannot do this, which is
  worth stating because it is the obvious first answer. It scales away
  with the thing it protects: keeping back half and breeding from a tenth
  of the rest breeds a twentieth instead of a tenth and reaches the same
  fixed point more slowly. Only a reserve measured against the number of
  mouths has an equilibrium.
- **One queen, and she is not infinitely fast.** Laying is bounded per
  tick whatever the larder holds. On its own this was the strongest single
  factor screened — +24% food delivered, a minimum larder of 307 against
  zero, deaths from 23 a run to 1 — though the honest version of that
  number is that a *different* pairing measured better still, and the
  queen ships for a reason other than its score. See below.

  A colony that can convert a windfall into workers in the minute it
  arrives has no characteristic timescale, so it overshoots every
  fluctuation and starves on the far side of it.

**Why these two and not the pair that measured best.** Breeding from a
surplus over a reserve of larder per living worker was the best
configuration tested: 4929 units against 4778 over five seeds, with a
hundred more workers alive at the end. It is not what ships.

It requires the colony to compute *stock per living worker* and decide
against it. That is a colony-wide aggregate, and it is exactly what this
model refuses everywhere else — §3.5 is explicit that foraging urgency is
the only quantity read colony-wide, and that an individual learns it
locally and honestly, by asking for food while it rests and being given
none. A brood rule that reads a second aggregate spends that principle,
and it spends it for 3%.

A bounded lay rate and a development delay ask nobody to compute
anything. One animal can lay only so fast; an egg takes as long as it
takes. The regulation *falls out of* two physical facts instead of being
computed from a measurement the colony has no way to make.

Results decide between mechanisms that are equally defensible. They do
not decide whether a mechanism is defensible, and a model that lets them
is one that will eventually be right about numbers and wrong about ants.
- **Death** comes from energy reaching zero and from age, with a per-tick
  hazard that rises with age. Foragers die away from home; that is what
  foragers do.
- **Brood stages** — eggs laid into a pipeline that takes time to emerge,
  and callow workers that do not forage until they have aged.

  This section previously argued the opposite: that a single `stock →
  workers` rate was the sound simple abstraction, and that development
  time "adds a lag, and the lag is the only thing it adds until nursing
  exists to interact with it." **Measured, that is wrong.** The lag alone
  is worth +17% food delivered and takes the minimum larder from zero to
  177, with no nursing anywhere in the model. The reasoning failed
  because it treated a lag as a detail of the mechanism rather than as
  what it is — a feedback term. A controller with no delay tracks its
  input exactly and therefore has no reason to hold a reserve; give it a
  delay and it must.

  Maturity does something the other two cannot: it separates *emerging*
  from *joining the foraging pool*, so a colony that has just bred hard
  does not increase its foraging pressure at the same instant. That is
  temporal polyethism, among the best-attested facts about ant societies,
  and it is also why §3.5 can treat a forager as expendable — foraging is
  the last job an ant holds.

  Together the three give the population an **age structure**, which this
  model has never had: laid, developing, callow, working. The renderer
  shades it (§5.1).

The visible consequence is that "400 ants" becomes where a scenario
*starts*, never where it stays. How many ants a run ends with is a result.

**A colony can also shrink to nothing.** If stock runs out, births stop
while deaths do not, and the nest depopulates and dies. This needs no
special case — it is the growth rule run with the sign reversed — but it
does need to be *stated*, because it is the first genuinely unforgiving
outcome in the model and it changes what a scenario means. A nest placed
too far from food does not forage inefficiently; it starves. Extinction is
a legitimate result of a run, and §3.8 tests for it.

### 3.11 Bodies — a disc for every ant, and one non-overlap rule

**An ant is a disc.** Not for rendering — §5.2 draws the full articulated
vector model — but for physics. A real ant is a head, a mesosoma, a gaster
and six splayed legs, and colliding that shape against a few thousand
copies of itself every tick is a problem with no payoff: at the scale
anything is decided, an ant is a blob that takes up room. One position, one
radius, done. **The visual model and the collision model are deliberately
different, and only the cheap one runs in the tick loop.**

The same disc serves corpses, food sources and any other movable or
roundish body. Obstacles stay polygons (§3.7), because static terrain wants
to be exact and only has to be tested against, never resolved between.

A box would work too, and is the obvious alternative — but a disc earns its
place for one technical reason and one aesthetic one. **Technically, an ant
is always turning**, and a disc is the only shape whose collision test does
not care: an axis-aligned box has to be re-fitted every time the heading
changes (and is badly wrong at 45°), and an oriented box needs a separating-axis
test and a contact normal that flips between edges and corners. A disc's
overlap is a subtraction and its normal is the centre difference, at any
heading, for free. **Aesthetically**, discs also simply look better in
motion: contacts resolve along the line of centres, so crowded ants jostle
and slide past each other smoothly, where boxes catch on their corners and
produce a visible grid-lock jitter that reads as broken.

**Traffic rules — designed, not built.** The one rule below is symmetric:
two ants meeting head-on push each other apart along the line of centres,
each takes half the correction, and neither has any notion of which way it
would rather go. Real ants meeting head-on do not do that. Under crowding
*Lasius niger* organises its trails into **lanes** — outbound and inbound
traffic separating into distinct streams, with a documented throughput
benefit (Dussutour, Fourcassié, Helbing & Deneubourg, *Nature* 2004, on
this exact species).

What the absence of that produces is visible at any pinch point: two
streams meet at a corner, each blocks the other, and the pile does not
resolve because nothing in the rule prefers a side. That would be a
cosmetic complaint except for what it feeds:

- Deposition counts the step an ant **attempted**, not the ground it
  covered (§3.3), so an ant stalled in a jam keeps marking at full rate.
- The mark recruits more ants into the jam.
- Which is a positive feedback loop with no term in it that measures
  progress.

That loop is almost certainly what makes §3.8's density window bite: past
about 900 ants on the double bridge the *long* arm starts winning, because
congestion has become a stronger route-selector than pheromone. The bulb
at a corner is the mechanism caught in the act.

Two candidate fixes, and they are not equivalent:

1. **Lane formation** — give ants a side preference on encounter, so
   opposing streams separate instead of colliding. Faithful, documented in
   the right species, and the more interesting of the two, because lanes
   are an emergent property worth watching rather than a damping term.
2. **Deposit by actual displacement** rather than attempted, so a stalled
   ant stops reinforcing the jam it is stuck in. One line, and it kills
   the feedback directly — but it also erases the "traffic jam that feeds
   itself" finding, which is real behaviour and worth keeping.

Worth measuring separately before either ships, and worth noting that (2)
would change a published figure in the README while (1) would not.

The rule is simply:

> **No two blocking bodies may overlap** — disc against disc, and no disc
> inside a polygon.

That single constraint is doing a surprising amount of work. It gives ants
collision with each other, collision with terrain, crowding and queueing at
food, physical congestion on a busy trail, and corpses that genuinely get
in the way — all from one mechanism with one code path, rather than four
subsystems that interact badly at the seams.

Two tests, both trivial:

- **disc vs disc** — compare centre distance against the radius sum; the
  overlap and its direction fall straight out.
- **disc vs polygon** — closest point on the polygon's edges, then push out
  along the normal. Cheap, exact, and no different in spirit from the first.

**Resolution must be Jacobi, not Gauss-Seidel.** The obvious
implementation — walk the pairs and push each apart as you find it —
is order-dependent, which would break determinism (§4.4) and make threaded
runs differ from single-threaded ones. So overlaps instead accumulate a
correction *vector per body* into a preallocated buffer, and the buffer is
applied after the sweep. Every body sees the same world, corrections
commute, and two or three relaxation iterations per tick settle a dense
crowd. This is the same trick as the pheromone deposit buffer (§4.2), for
the same reason, and it is not a coincidence: **anything an ant does to
shared state gets written to a buffer and folded in, never applied in
place.**

Pair candidates come from the spatial hash (§4.2), so the sweep is linear
in bodies rather than quadratic.

**A contact is a channel — much later.** The relaxation pass already knows,
every tick, exactly which ants are touching which. That list is the natural
substrate for everything ants do to each other *by touch*: trophallaxis,
antennation, tactile recruitment signals, nestmate recognition, alarm
transmitted by contact rather than by air. All of it is real, all of it is
contact-mediated in the literature, and none of it needs new spatial
machinery — it needs a rule applied to a list the physics is computing
anyway.

This is a **long way out — after M6**, and it is noted here only because it
argues for keeping the contact list rather than discarding it once
positions are corrected. Cheap to retain, expensive to reconstruct later.

**What blocks what**

| body | shape | moves | blocks | note |
|---|---|---|---|---|
| ant | disc | yes | yes | radius ≈ half a body length |
| corpse | disc | pushable | yes | inert; clutters, and can occlude a trail |
| food source | disc | no | yes | ants reach its edge and queue — crowding for free |
| obstacle | **polygon** | no | yes | static, exact, authored |
| nest entrance | disc | no | **no** | a trigger, not a wall — ants must get in |

The nest entrance is the deliberate exception. Making it blocking would
seal the colony in; making it a narrow gap between two blocking discs is a
tempting refinement — real nest entrances create measurable traffic jams —
but that is a later scenario, not an M1 mechanism.

**Corpses stay.** An ant that dies becomes a corpse body at the spot it
died, and it stays there. Nothing removes it, because removal is a
*behaviour* the colony does not have yet — real ants perform necrophoresis,
carrying corpses to refuse middens, and it is one of the best-documented
stereotyped behaviours there is (Wilson's oleic-acid experiment: daub a
live ant with the corpse cue and its nestmates carry it out anyway, while
it struggles). Until that behaviour exists, corpses accumulate, clutter the
approaches to a busy nest, and physically deform trail routes. That is not
a bug to hide — it is a visible, honest statement of what the colony cannot
yet do, and it makes adding necrophoresis later a change with a visible
payoff rather than invisible bookkeeping.

### 3.12 More than one colony — competition and trail corruption

The ant record already carries a colony id (§3.5), so multiple colonies
cost the model almost nothing structurally — but one decision has to be
made now, because it is not retrofittable.

**Trail fields are per colony, not global.** Each colony deposits into its
own field. An ant weights its own colony's field fully and every foreign
field by an **eavesdropping coefficient** ε ∈ [0,1]:

```
C_effective(cell) = C_own(cell) + ε · Σ C_foreign(cell)
```

- ε = 0 — colonies are blind to each other and merely compete for food.
- ε small — the realistic setting. Interspecific and intercolony trail
  eavesdropping is documented; ants do read foreign trails, imperfectly.
- ε = 1 — one shared field, and the colonies' trails genuinely corrupt one
  another: a strong foreign trail pulls your foragers toward a source
  someone else is already draining.

**Settled: ε is small — default 0.1, and the interesting range is roughly
0.05–0.2.** Two reasons, and the second is the one that decides it.

The biology is the weaker argument on its own: eavesdropping is real but
it is not nestmate-grade information. A foreign trail is a *cue* an ant
can exploit, not a *signal* addressed to it, and colony-specific blends
mean a foreign trail is both chemically distinguishable and behaviourally
discounted. "Some attention, much less than to your own" is ε ≈ 0.1, not
ε ≈ 0.5.

The decisive reason is what ε does to the choice function. §3.3's
nonlinearity means the model amplifies concentration differences — that
amplification is the entire mechanism behind symmetry breaking. Feeding a
foreign field in at anything but a small weight lets a neighbour's trail
dominate the `(k + C)ⁿ` weights outright, and the two colonies collapse
into one system sharing a de facto global field. What is wanted is
*perturbation*: enough foreign signal to occasionally divert a forager or
tip a marginal branch decision, not enough to steer the colony. ε small
is what makes competition a source of noise and drift rather than a
takeover, and it keeps each colony's own symmetry breaking legible.

So ε is a small nudge by design, and ε = 1 stays available as the
deliberately pathological setting — useful precisely because it should
visibly break the thing that works at 0.1.

A single coefficient spans the whole range from independence to mutual
interference, which is the cheapest possible way to make competition
interesting. Memory is one field per colony — 640 kB at 400², so a handful
of colonies is nothing.

Competition then has three channels, none of them special-cased: the food
itself depletes and is shared; the trail fields interfere through ε; and
the bodies physically block each other at a contested source (§3.11).
Fighting is *not* in the model and will not be until there is a reason for
it beyond spectacle.

**M1 runs one colony.** All of the above is a design constraint on the data
model, not M1 scope — the point of settling it now is that per-colony
fields and a colony id cost nothing on day one and cannot be added later
without touching every line that reads a pheromone.

## 4. Architecture

### 4.1 Systems

Mirrors waldameisen's split, for the same reason: the numeric core stays
dependency-free and therefore fast, portable and CI-friendly, while
everything that needs a foreign library lives behind its own system.

```
antsim.asd
  antsim               core sim. deps: none (sb-thread only)
  antsim/scenario      JSON loading.  deps: com.inuoe.jzon
  antsim/render        GL 2D renderer. deps: cffi, cl-opengl
  antsim/live          windowed view + interaction.  deps: cl-glfw3   [later]
  antsim/test          FiveAM core suite
  antsim/render-test   FiveAM render suite (GL tests skip without a driver)

antsim-gl-preload.asd
  antsim-gl-preload    the libGL preload, pulled in via :defsystem-depends-on
```

The preload **must** be a separate primary system pulled in with
`:defsystem-depends-on`, because that is the only ASDF hook that runs
before ordinary dependencies — and it has to run before `cl-opengl` binds a
libGL. This is not stylistic; see §5.4.

```
src/package.lisp        the ANTSIM package (nickname ANT)
src/util.lisp           specialized array types + constructors   [from wa]
src/rng.lisp            counter-based RNG, (id, tick, stream, seed)
src/pool.lisp           persistent worker pool                   [from wa]
src/world/grid.lisp     pheromone fields, decay, diffusion, deposit buffers
src/world/geom.lisp     polygons, rasterization, collision, spatial hash
src/world/scene.lisp    nests, food sources, obstacles
src/ant/state.lisp      the SoA ant table, allocation, birth/death
src/ant/sense.lisp      antennal sampling, choice function
src/ant/navigate.lisp   path integration, trail following, search
src/ant/behave.lisp     the state machine, thresholds, energy, crop
src/ant/step.lisp       the per-tick integrator — the hot loop
src/sim.lisp            multi-rate clocks, the top-level tick
src/scenario/json.lisp  scenario load/validate
src/render/preload.lisp driver libGL, before cl-opengl            [from wa]
src/render/png.lisp     dependency-free PNG writer                [from wa]
src/render/egl.lisp     headless GL 4.5 core context              [from wa]
src/render/offscreen.lisp FBO target, shader compile/link, capture
src/render/smoke.lisp   the M0 acceptance frame — deleted at M2
src/render/shaders.lisp GLSL: field, geometry, instanced ants
src/render/antmesh.lisp the 2D ant vector model + gait rig
src/render/view.lisp    ortho camera, layers, the frame
src/render/capture.lisp headless frame → PNG, contact sheets
tests/                  FiveAM suites, incl. the §3.8 acceptance tests
scenarios/*.json        the scenes, including the bridge experiments
```

### 4.2 Data model

**Struct-of-arrays throughout, allocated once.** Ants are a fixed-capacity
table with a free list; birth and death flip a liveness bitmask rather than
resizing anything (§3.10 — this is precisely why the table is
fixed-capacity). Pheromones are `(simple-array single-float (*))` per field
*per colony*, indexed `y*w + x`. No consing in the tick loop, ever.

**Bodies** are a second SoA table — `x`, `y`, `r`, `kind`, `flags` — that
ants index into rather than duplicate, so collision (§3.11) sweeps one
contiguous array covering ants, corpses and food alike. A corpse is a body
whose ant slot has been freed.

**Every write to shared state goes through a buffer.** There are two, and
they exist for the same reason:

| buffer | written by | folded in on |
|---|---|---|
| pheromone deposit, per field | any ant laying trail | the pheromone clock |
| position correction, per body | any overlapping pair | the end of each relaxation iteration |

Both make the ant loop **order-independent** — two ants depositing in the
same cell, or two pairs correcting the same body, commute — and
order-independence is exactly what makes threaded runs bit-exact (§4.4).
Applying either in place would be faster and would silently destroy
determinism.

**Spatial hash** over a coarse grid (say 5 cm cells) serves both proximity
queries and collision broad-phase. Rebuilt each tick by counting sort into
preallocated arrays.

### 4.3 Multi-rate clocks

Different processes have different natural timescales, and running them all
at 20 Hz is waste. waldameisen does this with its 900 s soil clock; same
idea:

| clock | rate | drives |
|---|---|---|
| motion | 20 Hz | ant movement, sensing, collision, deposits |
| pheromone | 1 Hz | evaporation, diffusion, deposit fold-in |
| colony | 1/min | demographics, age, task threshold adaptation, food renewal |
| render | 30–60 Hz | decoupled from sim; interpolates ant positions |

Plus a **time compression** factor, because a foraging trip is minutes but
colony dynamics are days. The sim must be able to run at 1×, at 100×, and
headless-as-fast-as-possible.

### 4.4 Determinism

Identical to waldameisen's rule, and non-negotiable:

- `rnd01(id, tick)` — a pure function of the ant's stable id and the tick
  number. No shared RNG state, no order dependence, thread-safe by
  construction. An ant's random stream is identical no matter which worker
  thread stepped it.
- `*random-state*` is **banned** from simulation code. A test greps for it.
- Fixed contiguous range partitioning in the worker pool, so the thread
  count never changes the result.
- A test steps two identical sims and requires byte-identical state.

### 4.5 Threading

The ant step partitions cleanly over the pool because deposits go to a
separate buffer and reads of the pheromone field are from the *previous*
pheromone tick. Ant–ant interactions (trophallaxis, collision) are the only
coupling; handle them by making them symmetric and resolving them in a
second, single-threaded pass over a preallocated contact list — cheap,
because contacts are rare.

### 4.6 Building and running

SBCL 2.6.4 with Quicklisp. The Makefile exports `CL_SOURCE_REGISTRY`
pointing at the checkout, so nothing needs to be symlinked into
`~/quicklisp/local-projects` — a clone builds where it stands.

```
make test              core suite: RNG, pool, util.  no GPU, no graphics
make test-render       renderer suite on the GPU (guix shell nvda@580)
make test-render-mesa  the same suite in software on llvmpipe — no GPU
make test-render-ci    alias for test-render-mesa
make test-render-bare  no wrapper; GL tests skip if the host has no GL
make smoke             M0 end to end: headless frame → out/m0-smoke.png
make smoke-mesa        the same frame in software, for comparing stacks
make repl              a REPL with antsim loaded
make page              regenerate docs/index.html from docs/concept.html
```

GPU targets wrap the command in `guix shell nvda@580 --`, which is how the
driver gets onto the loader path. A host that already carries the driver in
its system profile does not need the wrapper — but the wrapper is what makes
the result reproducible across hosts, and §5.4 is what happens when the
wrong libGL wins.

If a render comes back black, run `nvidia-smi` *inside* that shell before
suspecting the renderer.

**A test environment does not need a GPU, and should not skip.** Mesa's
llvmpipe provides a genuine 4.5 core context in software (measured: `4.5
(Core Profile) Mesa 26.0.2`, GLSL 4.50), so `make test-render-mesa` runs
the whole render suite — 36 checks, nothing skipped — on a machine with no
graphics hardware at all. It is much slower, which is irrelevant for a
handful of small frames. Skipping is therefore a signal that the
environment is *misconfigured*, not that the machine is modest, and the
suite prints which GL stack it actually used so a log can be read later.

The software path found a bug the GPU path could not: SBCL unmasks
floating-point traps, llvmpipe's JIT raises invalid and divide-by-zero as
a matter of course, and the process died on SIGFPE mid-draw. NVIDIA never
trips them. `with-headless-gl` now masks traps for the extent of GL work
and leaves the simulation's own traps alone — the sim *wants* to hear
about a NaN.

Render tests keep their frames in `out/tests/` rather than deleting them.
When a render test fails the first question is what it looked like, and an
unlinked temporary file cannot answer it.

## 5. Rendering

### 5.1 The pipeline

Top-down orthographic. Layers, back to front:

1. **Ground** — subtle texture, so motion has a reference frame.
2. **Pheromone fields** — the sim grid uploaded as a texture (R32F per
   field, or one RGBA32F with four fields packed) and colour-mapped in the
   fragment shader. Trail warm, no-entry cool, alarm hot and transient.
   *This is the most beautiful thing on screen and it should be treated as
   such* — a living, breathing gradient that thickens into a road and then
   evaporates.
3. **Obstacles** — filled polygons with a soft outline.
4. **Food sources** — radius scales with the amount present, so depletion is
   visible without a number; colour or saturation encodes quality.

   The radius is derived from a **density**, `area = amount / density`, and
   not from a fraction of the starting amount. That distinction is the
   difference between a picture that answers *how much is there* and one
   that answers *how much of it is left*: with a fraction, a source holding
   500 000 units and one holding 2 500 are drawn identically at full, and
   two sources in one scene cannot be compared at all. A scenario that gives
   only a radius gets a density derived from it, so nothing that predates
   this behaves differently.

   The same radius is the **collision** circle, so a dwindling pile has a
   shorter edge and physically feeds fewer ants at once (§3.11).
5. **Nests** — entrance, home-range halo from the marking field.
6. **Ants** — instanced, §5.2.
7. **Overlay** — optional: home vectors, trail-choice probabilities, a
   selected ant's state readout, counters. Toggleable, off by default.

### 5.2 The ant — a real 2D vector model, animated

This is the part with no precedent in waldameisen (whose ants are two
triangles with an elliptical mask, deliberately, because at a 1.3 m mound
scale an ant is two pixels). Here ants are the subject, so they get built
properly.

**Geometry.** Top-down ant anatomy, as a triangulated mesh built once at
load and instanced:

```
        antennae (2, animated sweep)
           \  /
          ╭─────╮        head + mandibles
          ╰──┬──╯
         ╭───┴───╮       mesosoma — the 6 legs attach here
      ╱  ╰───┬───╯  ╲    3 pairs, alternating tripod
     ╱       │       ╲
            ( )           petiole node
          ╭─────╮
          │     │       gaster
          ╰─────╯
```

Three body segments (head, mesosoma, gaster) joined by a petiole, six
two-segment legs, two antennae. A few dozen triangles.

**Gait — alternating tripod.** Legs L1/R2/L3 swing while R1/L2/R3 stance,
then swap. The stride phase φ advances with **distance travelled**, not
with time — this is the difference between an ant that walks and an ant
that moonwalks while sliding. During stance a foot is *planted in world
space*, so the leg visibly sweeps backward relative to the body; during
swing it snaps forward. In a top-down view that contrast is the entire
walking cue, and it is cheap.

**Implementation: articulate in the vertex shader.** Per-instance data is
`(x, y, heading, gait_phase, scale, state, tint)` in the persistent-mapped
SSBO — the same buffer path already proven in waldameisen. The mesh carries
per-vertex attributes for *which limb* a vertex belongs to and its
parameter along that limb; the vertex shader derives the foot target from
φ, solves the trivial 2-link 2D IK, and places the vertex. No per-ant CPU
work, no buffer rewrite for animation.

*Fallback if the VS math gets unwieldy:* bake ~16 gait poses into a small
UBO and lerp between them. Cheaper, easier to art-direct, loses the
world-planted foot. Decide during the M3 spike.

**As built (M3): the fallback was not needed.** The two-link solve is
eight lines of GLSL and the whole vertex program is under two hundred,
so the planted foot is kept. Two decisions the spike settled that this
section had not anticipated:

- **The skeleton is generated into the shader, not written twice.** The
  leg attachments, link lengths, bend directions and tripod assignment
  live once, in the file that builds the mesh, and the vertex program's
  `const` tables are formatted from them at load. A mesh and an
  articulation that disagree about where a hip is produce a leg that
  detaches from the body at some phases and not others, which is a bug
  that looks like a rendering glitch and is actually a data-duplication
  bug.
- **The instance record is two `vec4`s, not the seven fields listed
  above.** `(x, y, heading, phase)` and `(radius, state, load, flick)` —
  `flick` being how recently this ant put its gaster down, which is read
  off the distance-since-last-packet the deposit rule already keeps
  rather than recorded as an event. Nothing new is stored, and the
  drawing cannot disagree with the mechanism about when a deposit
  happened.

**Level of detail is three tiers, not two.** The third is the M2 disc,
kept rather than replaced: below about four pixels of radius an ant goes
back to being the analytically antialiased circle of §3.11, because at
that size legs are noise and a circle antialiases better than ninety
triangles. The middle tier — body segments, no appendages — is a
*range* of the full mesh's index buffer rather than a second mesh, so
the simplified ant cannot drift away from the detailed one.

**The vector ant is what made the target multisampled.** Every earlier
primitive antialiased itself, so nothing had ever asked the framebuffer
for coverage; a leg drawn a pixel and a quarter wide cannot, and six
staircases per ant crawling over a still frame read as a shimmer rather
than as a gait. It fixed the obstacle edges at the same time (§5.1).

**Level of detail.** Zoomed out, an ant is a few pixels and the legs are
noise. Two meshes — full and simplified body-only — selected by
pixels-per-ant. The simple mesh is essentially waldameisen's approach, so
this is a solved problem at both ends.

**Legibility touches, all of them real behaviour:**

- **Antennae** sweep sinusoidally *and* bend toward the local pheromone
  gradient. Real ants sample the trail by sweeping antennae across it; you
  can see an ant's antennae find a trail before its body turns.
- **Carried payload** drawn at the mandibles when the crop is loaded, sized
  by load.
- **Gaster tip** flicks down at the moment of a trail deposit — a visible
  event marking an invisible mechanism.
- **State tint**, subtle: exploring, following, laden, returning, tired.
- **Speed** modulated by energy, so a colony visibly slows when it is hungry.

### 5.3 Colour

The palette must survive the pheromone layer being the brightest thing on
screen. Dark ground, warm high-value trail, ants dark and high-contrast
against both. The waldameisen lesson applies: a *diverging* map keyed on a
meaningful midpoint reads without a legend, whereas a sequential ramp needs
one. Here the meaningful midpoint is the trail-following detection
threshold `k` — below it the ants ignore the pheromone, above it they
commit — so that is where the colour map should turn.

### 5.4 Headless, and the libGL trap

**Headless is the test path.** Every render is capturable to PNG without a
window, which is what makes visual regressions testable and what lets the
results be inspected as images rather than described.

Carried over verbatim from waldameisen, including the hard-won part:

> cl-opengl asks the loader for `libGL.so.1`. On a machine with both Mesa
> and NVIDIA, it may get Mesa's — while the EGL context came up on the
> NVIDIA vendor. **Nothing errors.** Entry points resolve, buffer and
> framebuffer names are handed out, and every pixel comes back black,
> because the dispatch layer has no current context. `(gl:get-string
> :version)` returning `NIL` is the tell.

Hence `preload.lisp`, loaded via `:defsystem-depends-on` so it runs before
`cl-opengl`, and hence the `guix shell nvda@580 --` wrapper on every GPU
Makefile target. **If frames come back black, check `(gl:get-string
:version)` first.**

CI has no GPU, so GL tests must *skip*, not fail — and a green CI run
therefore does not mean the renderer was verified. Only `make test-render`
on this machine does.

### 5.5 The live window, and why the camera comes early

Headless covers tests and image output but not "watch it run", which is
most of the point of a playful sim. **`antsim/live` therefore lands with
the renderer at M2, not at the end** — because a free camera is what keeps
every question about scale open.

That is the real argument for it. Without pan and zoom, the arena size,
the ant count and the render scale are all locked together, and every one
of them has to be guessed correctly up front. With them, the same run is
legible at any scale: zoom in and a single ant is a vector model with a
gait; zoom out and the same colony is a trail network. Nothing about the
world has to be decided in advance to see it.

**Controls**

| input | action |
|---|---|
| mouse wheel | zoom, anchored at the cursor — the world point under the pointer stays under it |
| right-drag | pan |
| `space` / `+` / `-` | pause, and time compression up/down |
| left-click an ant | inspect: state, energy, crop, age, home vector, and whether it has the reserve to set out — the ant is marked on the map by a pulsing pink reticle |
| `home` | frame the whole world |
| `h` / `?` | hide or show the key legend |
| `q` / `escape` | quit |

The window **lists its own keys**, bottom-right, and opens at 4× rather
than real time. Both are the same judgement: the controls are not
guessable, and the quantities worth watching — a trail forming, a source
running down, a colony growing — move over minutes to an hour, so real
time shows a new watcher several minutes of ants wandering in silence.

`+` and `-` are read from the **character** callback rather than the key
callback, because GLFW reports keys by their physical position on a US
layout. On a German QWERTZ the `+` key sits where US has `]`, arrives as
`:RIGHT-BRACKET`, and a handler written for `:EQUAL` never fires — which
is exactly what happened. The character callback is layout-aware by
definition and needs no table of national layouts.

Cursor-anchored zoom is worth calling out because the obvious
implementation — scale about the screen centre — feels wrong immediately
and is the same two lines of arithmetic to do properly.

**Backend: cl-glfw3** — minimal, suited to one GL window, and its input
model is a direct fit for the above. Alternatives considered: `sdl2`
(heavier, more capable, more moving parts) and a frame sequence piped to
`ffmpeg` (no new dependency, fine for sharing results, useless for
interaction).

The renderer stays surface-agnostic regardless: the camera is an ortho
transform and a viewport, and the headless path is the same renderer with
an FBO instead of a window. The live window is a second consumer of the
frame, never a fork of it — which is what keeps the tested path and the
watched path the same path.

## 6. The scenario file

JSON, as asked. Loaded by `antsim/scenario` (which owns the JSON
dependency) into plain structs, so the core never sees a parser.

```json
{
  "name": "goss-double-bridge",
  "world":  { "width": 1.2, "height": 0.8, "cell": 0.005 },
  "clock":  { "motion_hz": 20, "pheromone_hz": 1, "colony_per_min": 1 },
  "species": "lasius-niger",

  "pheromones": {
    "trail":   { "tau_s": 1800, "diffusion": 0.0,  "max": 100.0 },
    "no_entry":{ "tau_s": 900,  "diffusion": 0.0,  "max": 50.0  },
    "alarm":   { "tau_s": 30,   "diffusion": 0.02, "max": 20.0  }
  },

  "choice": { "n": 2.0, "k": 20.0, "eavesdrop": 0.1 },

  "bodies": { "ant_radius": 0.0025, "relax_iterations": 3 },

  "colonies": [
    { "id": "home",
      "nest":     { "x": 0.10, "y": 0.40, "r": 0.03 },
      "capacity": 4000,
      "start":    400,
      "stock":    0.5,
      "brood_per_stock": 0.8,
      "max_age_s":       86400 }
  ],

  "food": [
    { "x": 1.10, "y": 0.40, "r": 0.02,
      "amount": 500.0, "quality": 1.0, "renew_per_min": 0.0 }
  ],

  "obstacles": [
    { "polygon": [[0.4,0.30],[0.8,0.30],[0.8,0.34],[0.4,0.34]] },
    { "polygon": [[0.4,0.46],[0.8,0.46],[0.8,0.50],[0.4,0.50]] }
  ],

  "seed": 12345,
  "duration_s": 3600
}
```

Note what is **not** in there, and cannot be: **no ant positions and no
pheromone.** `start` seeds a count at the nest, not a layout, and there is
no key anywhere that puts trail on the grid (§3.3). `capacity` is a memory
bound; `start` is an initial condition; the population between them is a
result. Colonies are a list from the outset even though M1 runs one, so
that competition (§3.12) is a scenario change rather than a format change.

Everything a scenario does not specify falls back to the species parameter
set, and everything the species set does not specify falls back to a
documented default. Validation is strict and errors name the offending
path — a silently-defaulted typo in a scenario is a bug that costs an
afternoon.

The bridge experiments ship as scenarios, which means the acceptance tests
of §3.8 are *literally the published experiments run as data files*.

### 6.1 Obstacle primitives, and the `bridge`

An obstacle is one of `polygon`, `rect`, or `bridge`.

```json
{ "bridge": { "y_lo": 0.20, "y_hi": 0.40, "corridor_width": 0.06,
              "arms": [ { "bottom": 0.28, "top": 0.28 },
                        { "bottom": 0.36, "top": 0.60 } ] } }
```

A bridge is a band from `y_lo` to `y_hi` that is solid everywhere except
for one corridor per arm. Each arm gives its centre line where it leaves
the lower chamber and where it enters the upper one; an arm whose `bottom`
and `top` differ is slanted, and therefore longer, **without the fork
moving** — which is exactly what the unequal-arm experiment needs. The one
above is Goss's double bridge.

It is a primitive rather than three polygons for a reason that is not
convenience. The solid parts are the *complement* of the corridors, and
their coordinates are all derived from four numbers; written out by hand
they are unreadable and easy to get wrong in the single way that matters —
an extra way through the band that nobody notices. The ants find it, the
traffic splits three ways, and the science gets blamed for a hole in the
wall. That is not hypothetical: the first version of the apparatus had a
different geometric mistake and produced a flat 51/49 result that looked
exactly like the choice function failing.

The primitive expands by calling the same `add-bridge!` the Lisp
constructors use, and a test asserts that the shipped files and the Lisp
constructors produce identical geometry, vertex for vertex. A bridge that
meant one thing in JSON and another in an acceptance run would make the
published result and the thing anyone can look at two different
experiments with the same name.

### 6.2 Strictness

An unknown key is an error, a key of the wrong type is an error, and the
message names the full path — `world.heigth`, not "invalid scenario".

Keys that §6 documents but the loader does not implement yet are reported
*differently* from typos, because the two need different answers: a typo
is a mistake in the file, and a deferred key is a mistake in the author's
expectations of the program. Telling them apart is most of what makes an
error message worth reading.

Deferred so far: `clock`, `species`, `bodies`, and the per-colony
`brood_per_stock` / `max_age_s`, all of which are global parameters at
M1's cut.

### 6.3 The `ant` block, and why arena size needs one

The override surface is uneven on purpose — it grew where an experiment
needed it — but one gap turned out to be structural rather than
incidental, and it is worth stating as a rule.

**Arena size is the one thing a scene can change that the ant's own
calibration cannot absorb.** A forager carries a fixed tank:
`*energy-drain-walking*` is a free parameter set so an ant empties after
about seven minutes of walking, roughly eight metres of path, and that
was chosen against the 1–2 m arena of §3.1. Put the food three metres
from the nest and no ant reaches it — measured, the colony ate 8 units in
half an hour and fell from 2000 workers to 26.

Nothing about that is a bug. It is what a fixed tank means. But it does
mean **range belongs to the scene as much as to the animal**, so a
scenario spanning metres has to be able to say so, and `ant` is the block
that lets it:

```json
"ant": { "energy_drain_walking": 0.000024, "energy_drain_resting": 0.000004 }
```

Two things keep this from being a licence to tune. The default does not
move, so nothing outside a file that sets it is affected. And the
direction of the change is the defensible one: a real *Lasius* forager
ranges far beyond eight metres and trunk trails run to tens of them, so
the large arena's value is the more realistic one and the shipped default
is the compromise a small arena allows.

`scenarios/antsim-large.json` is the worked example — the same word, the
same font, five times over in every length, with the range scaled by
exactly the same factor so that a journey costs the same fraction of a
tank in both files. A test asserts that ratio, because the failure it
guards against is silent: get it wrong and both scenarios still run, they
simply stop being the same experiment at two sizes.

## 7. Milestones

Deliberately shaped like waldameisen's: each milestone ends in something
verifiable, and the risky spikes come early.

Milestones are also the branching unit: `main` holds the stable line, each
milestone is developed on `milestone/mN` and merges to `main` when its
acceptance criteria pass, and nothing is committed to `main` directly. The
original planning branch `concept` is archived.

**M0 — the stack stands up. ✅ done.** ASDF systems, package,
`util`/`rng`/`pool` carried over, FiveAM wired, Makefile with the guix GPU
targets. A headless context comes up and writes a non-black PNG. *Proves
the toolchain before any design is committed to it.*

Verified: core suite 40 141 checks green with no GPU; render suite 36
checks green on **both** backends — GL 4.5.0 core / NVIDIA 580.159.04 /
RTX 3070, and Mesa 26.0.2 llvmpipe in software — drawing a real GLSL 450
frame into an FBO and encoding it, with nothing skipped on either.
`make smoke` writes `out/m0-smoke.png`.

Two things came out of building it rather than planning it. The RNG grew a
`seed` argument, because §3.8's symmetry-breaking result is a claim about a
*distribution over runs* and needs independent replicates of one scenario —
and it is an argument rather than a special variable because a `let`-bound
special is thread-local in SBCL, so workers would silently keep the global
value and every replicate would come out identical. And the mixer had a
fixed point: `hash32(0) = 0`, so ant 0 on tick 0 drew exactly `0.0`. Both
are pinned by tests now.

A third came out of running the suite in software: SBCL's unmasked
floating-point traps killed the process on SIGFPE inside llvmpipe's
rasteriser. The GPU path never trips them, so only the Mesa run could
have found it — which is an argument for the software target beyond
"CI has no GPU".

**M1 — the core simulation, no renderer.** Exactly the §3.9 cut and nothing
past it: the ant and body tables, CRW movement, disc collision with Jacobi
relaxation, one trail field per colony with decay and deposit fold-in, the
choice function, path integration, the four-state machine, food depletion,
colony growth and death. *Ends when the §3.8 acceptance tests pass* —
symmetry breaking and shortest-path selection, verified numerically with no
picture involved. This is the milestone that decides whether the science is
right, and it deliberately does not depend on a single line of GL.

**M2 — the renderer, and the window.** Ortho camera, pheromone field
texture, obstacle polygons, food, nests, ants as simple discs. Headless PNG
gallery of the M1 scenarios *and* `antsim/live` on GLFW with
cursor-anchored wheel zoom, right-drag pan, pause and time compression
(§5.5). The window comes in here rather than at the end because it is what
keeps arena size, ant count and render scale from having to be guessed
correctly up front. *First time you can watch a trail form, at whatever
scale you like.*

**M2.1 — what watching it found.** Not a planned milestone; an interleaved
one, and its whole content is corrections that only became visible once
there was a window to see them in.

- **The colony could starve with the door shut.** Departure needed energy,
  energy needed stock, stock needed departures — a three-way deadlock that
  froze 499 ants in the nest with 0 outbound for the rest of the run.
  Fixed with foraging urgency (§3.5), which raises the departure rate and
  lowers both energy thresholds as the larder empties.
- **Pheromone deposition became packets** laid by distance rather than
  marks laid per tick (§3.3) — which is what §3.3 specified in the first
  place and M1 had simplified away.
- **Evaporation became visible**, via an explicit `*trail-decay-scale*`
  and a display ramp that spans the field's actual range instead of
  saturating at 12% of it (§3.3, §5.3).
- **The saturation ceiling was nine times too low.** A working route
  peaks near 300 against a cap of 100, so every cell that mattered
  pinned to the same value — flattening the exponential deposits back
  out, and leaving both antennae reading an identical number on the
  strongest part of the trail (§3.3).
- **Exhausted ants are drawn red.** A nest quietly filling with spent ants
  had been indistinguishable from a nest full of ants declining to leave,
  and it was read as exactly that — by a human watching, which is the
  point.
- **Departure set no heading at all**, so an ant left the nest pointing
  the way it came in — *inward* — and walked out the far side. 65% of
  departures set off within 30° of exactly opposite the source they had
  just returned from. Fixed with the route-memory stub §3.4 had always
  called for.

Fixing that last one turned up a bug of a different kind, worth recording
because it is the one way a counter-based RNG can still surprise you. The
exit scatter was drawn from the same stream as the decision to leave — and
a departure only happens when *that* draw comes out under
`*leave-probability*` ≈ 0.005. `rnd-normal` is Box-Muller, so it feeds
that same `u₁` into `√(−2 ln u₁)`: conditioning on `u₁ < 0.005` forces the
magnitude above 3.2σ every single time, and every ant left on a wild angle
deterministically. The draws look independent and are not. **One stream,
one question.**

A second round followed, and it went further than corrections:

- **Ants could not feel walls.** The collision pass removes only the
  component *into* a surface, so a blind ant slid along it and marked it
  while sliding, and the mark recruited others onto the same wall. The
  antennae now veto a direction that is inside terrain — and, separately
  and more importantly, veto the *home bearing* too, since a laden ant is
  steered by the bearing and not by the choice function (§3.2, §3.4).
  Four times the food delivered, and deaths from 126 a run to 0.5.
- **The colony had no regulation of any kind.** It converted a share of
  its larder into workers every minute regardless, so the fixed point of
  its own growth rule was zero reserve — and a colony with no reserve
  cannot absorb the jams and trail collapses this simulation produces
  constantly. Brood now goes through one queen at a bounded rate into a
  pipeline that takes time to emerge (§3.10).
- **The population acquired an age structure**, and the renderer shades
  it, because until the brood rules there was nothing to see.
- **The bridge experiments acquired a protocol** — a fixed colony, of a
  size the apparatus actually works at. Past about 900 ants the long arm
  wins: crowding stops being noise and starts being the thing that
  selects (§3.8).

Three of the mechanisms built in this round ship **off**, with their
numbers recorded: U-turns on a lost trail, forager expendability, and
breeding from a per-worker reserve. The last of those measured *best* of
anything tried and is off anyway, because it requires the colony to
compute stock per living worker — a colony-wide aggregate, which is what
this model refuses everywhere else.

The lesson is the same one M2 was justified by, and it keeps holding: the
renderer earns its early place because *the model's failures are shaped
like pictures*. Every one of these was invisible to the aggregate
statistics that were being printed at the time — and two of the round's
best findings came from a human watching the window and saying what
looked wrong, then the measurement agreeing.

The measurements themselves live in
[experiments.md](experiments.md), including the ones that decided against
a change, and the four ways a measurement was got wrong before it was got
right.

**M2.2 — the colony's own metabolism.** Another interleaved one, and like
M2.1 its content is corrections that only became visible from the window.
Where M2.1 was about how an ant *moves*, this is about how a colony feeds
itself.

- **The nest fed everybody a little instead of somebody enough.** Every
  resting ant drew a fixed sip from a common store each tick, so one
  forager's load was spread over five hundred ant-ticks — with several
  hundred ants in the nest, roughly one tick each. Nobody was fuelled by
  it, and since an empty larder lowers the departure bar, ants holding
  almost nothing still qualified to leave and exhausted. `COLONY-FEED!`
  now serves the hungriest resting ants to satiety, a bounded few per
  tick. That is the recipient half of the trophallaxis §3.9 defers, and
  it is the half that decides whether the colony lives.
- **A forager standing on food did not eat.** Energy was only ever
  restored at the nest, so a forager crossed the whole return trip on the
  reserve it set out with, and a long route killed runners no matter how
  rich the source they were standing on — while carrying a full crop,
  which is precisely the absurdity the separate crop and energy fields
  exist to *describe* rather than to cause.
- **`WAITING FOR FOOD` is now a phase.** `IN NEST` was covering two
  unrelated situations: an ant resting between trips, and an ant that
  cannot leave until somebody feeds it. Conflating them is what made a
  nest quietly filling with spent ants read as a nest full of ants
  declining to go out.
- **A scenario that reproduces the failure**,
  `scenarios/antsim-overload.json` — 1400 ants on 40 units of stock,
  where metabolism exceeds income from the first tick and the only
  question left is how the nest shares what little arrives.

That last item is the milestone's real lesson. Every earlier measurement
of the feeding rule started with a small colony that simply grew
healthily, so the rule could not matter either way and dutifully measured
as nothing. **A fix cannot be defended without a reproduction of the
failure it fixes**, and the reproduction is worth more than the fix.

**M3 — the ant model, and how ants meet.** The vector ant, the tripod
gait rig, VS articulation, LOD, antennae, payload, state tint. The one
genuinely novel piece of engineering in the project, and it gets its own
milestone because it deserves the room to be got right. Note the
collision model does not change *shape*: the disc stays, the drawing gets
legs (§3.11).

**The first half is built.** Everything in that list ships, and the way
it ships is the one §5.2 specified rather than the fallback: the legs are
solved in the vertex shader from a stride phase, not lerped between baked
poses, so the stance foot is genuinely planted in world space. Three
findings are worth carrying out of it.

*The stride is not a free parameter.* A planted foot only stays planted
if the drawn sweep of the leg equals the ground the body covered, so the
step length sets the step *rate* too and the two cannot be tuned apart.
That collides with legibility from both sides — the honest rate at 4 mm
is 10-20 Hz, which is a blur, and a longer stride needs longer links
until the ant stops looking like an ant — and `*gait-stride*` is where
those two pressures meet. It is recorded as a parameter with that
reasoning attached rather than as a number in a shader.

*One float of model state, and the model does not read it.* The phase has
to live in the ant table because it is a history — a frame cannot see how
far anything moved — and it is closed over **actual net displacement**,
the same quantity path integration uses and the opposite of the attempted
step that deposition uses (§3.3). Both are right: an ant wedged in a jam
is still walking, gaster still touching down, and its feet are still not
covering ground. Two rules disagreeing about the same tick, on purpose,
is worth a test each.

*The renderer needed multisampling, and nothing before it had.* Every
earlier primitive antialiased itself — the disc analytically, the field
as a texture — so the target had never been asked for coverage. A leg is
a pixel and a quarter wide and a triangle mesh cannot do that trick, so
`*msaa-samples*` is now on for every render in the project. It fixed the
obstacle edges as a side effect, which had had the same staircase for the
same reason since M2 and had simply been lived with.

The level of detail is three tiers rather than §5.2's two, and the extra
one is the M2 disc: below about four pixels an ant goes back to being the
circle it was, which is both the better picture and the guarantee that
every published figure is still drawn by the shader that drew it. The
threshold sits clear of the sizes the documentation actually renders at,
because a figure whose whole look flips when someone renders it eight
pixels wider is not a figure.

It does change what happens when two discs meet, and that is the second
half of this milestone. The non-overlap rule is symmetric — two ants
head-on push each other apart and neither prefers a side — so opposing
streams gridlock at pinch points instead of sorting themselves out.
Because deposition counts the step an ant *attempted*, the stall marks
the ground, the mark recruits more ants into it, and nothing in that loop
measures progress. Measured, it is very likely what makes §3.8's density
window bite: past about 900 ants on the double bridge the *long* arm
starts winning, because congestion has overtaken pheromone as the
route-selector.

Lane formation is the fix worth building rather than the damping term
that would also work. It is documented in this exact species (Dussutour,
Fourcassié, Helbing & Deneubourg, *Nature* 2004), it turns crowding into
organisation rather than merely removing gridlock, and — the reason it
belongs *here* — an ant that chooses a side on encounter is an ant whose
antennae and body orientation start to matter, which is precisely what
the rest of this milestone is building. The two halves are the same
subject approached from opposite ends: what an ant looks like, and what
it does when it meets another one.

The candidates and their costs are in §3.11; the short version is that
lane formation leaves the published figures alone and depositing by
actual displacement would not.

**The second half is built, and it took the exchange with it.** The plan
was to build the *event* — this ant met that ant, at this bearing — and
leave what rides on it to a later milestone. The event was indeed the
expensive part, and the prediction that followed held exactly: once the
broad phase reports encounters, recognition, giving way and trophallaxis
are one function between them and none is more than a handful of lines.
So they are all here.

Four findings, and the first is a correction to the paragraph this
replaces.

*The content of an encounter is not navigational.* The plan said a laden
ant coming the other way is "current evidence that there is food behind
her", and half of that is right in a way that matters. It **is** current
evidence, which is the one thing an average over the last several minutes
cannot be. But "behind her" is a direction, and ants of this genus have
been tested for tactile transfer of direction with a negative result
(Grüter, Czaczkes et al., *Insectes Sociaux* 2017). A model that let a
contact hand over a bearing would be inventing a channel the animal has
been shown not to have. So a contact here carries evidence about *when*
and never about *where*: it buys persistence, a lower give-up threshold,
and nothing else. A test asserts the heading does not move.

*Lanes do not form, and that was the reason for preferring this fix.*
§3.11 expected lane segregation to fall out of an asymmetric yield.
Measured on a 55 cm trail with 600 ants, the mean lateral offset between
the outbound and returning streams is 1.7 mm with the rule and 2.1 mm
without — less than one ant radius, and slightly *worse* with it. The
rule is symmetric in a way the reported behaviour is not: each ant turns
away from where the other actually is, so deflections cancel across a
population, and `ANT-HANDEDNESS` is a deliberate even split. A lane needs
a shared convention or a population-level bias to seed it and there is
neither. What giving way does buy is throughput — fewer head-on stalls —
which is a smaller claim than §3.11 hoped for and the one there is
evidence for.

*Overtaking triggers on being obstructed, not on being faster.*
Comparing free-walking speeds is the wrong question in a stalled column,
where nobody is moving: only the ants quicker on paper try to pass and
the rest shove, which is a queue whose leader presses an obstacle while
everyone behind presses into the ant in front. Its aggregate effect
measures as null and is kept anyway, because an ant pressed against
another's back for seconds is visibly wrong in a way no aggregate catches
and it costs nothing measurable.

*The determinism discipline paid for itself immediately.* Every rule
reads the state the tick began with and writes to a buffer applied
afterwards, exactly as the Jacobi collision buffers and the field deposit
buffer do. An ant that turned in place would be seen already turned by
every higher-numbered neighbour, which makes the outcome depend on table
order — invisible until something is threaded. It has its own test: two
donors and one recipient poised just under the threshold at which it
stops accepting food, where the in-place version feeds it once and the
buffered version twice.

**One bug fixed on the way, and it was large.** A feeding ant does not
hold its own position — the pile is a blocking body with a queue round
it, and its edge retreats as it is eaten — so asking whether the ant was
still *on* the source treated every shove as the food running out and
sent it home with whatever it had. Measured, **48% of all departures from
food were ants that had been pushed off rather than filled up**, mean
load 0.63 of a crop instead of 1.0. Ants now step back onto the pile and
feed from a radius rather than a point.

**What is deliberately not here.** A larger body of navigation work was
built alongside this and lives on the `navigation-experiments` branch
rather than shipping with the milestone: a stall window that lets an ant
notice it is getting nowhere, the no-entry repellent field §3.9
schedules, a per-ant lane preference across the width of a trail, and
four mechanisms aimed at the concavity trap that each measure as costing
a published §3.8 row — short-range food odour, a detour commitment latch,
windowed homing, and a global terrain veto. They are documented with
their measurements there. The concavity trap of §3.4 is **not** fixed,
and one experiment worth recording says why: switching ant-ant contact
off entirely leaves the same ants stuck against the same terrain (171
against 185 over three seeds), so the furball is the appearance of that
failure rather than its cause, and no amount of tuning traffic reaches
it. Escaping a concavity needs route memory, which M4 did not reach.

**M4 — the society, and three mechanisms that had nothing to do.** The
plan was the deferred half of §3.9 in dependency order, on top of JSON
loading and richer scenes. JSON loading turned out to have shipped at M2
— the sentence had gone stale — so the milestone is the §3.9 items and
what testing them found.

*Delivered, and working.* **Multiple colonies**, which needed no change to
the tick at all: §3.12's per-colony indirection held, and the work was
apparatus, an honest per-colony harvest counter, and a way to tell tribes
apart on screen. **Necrophoresis**, on Deneubourg's sorting model, which
roughly doubles clumping and takes the corpses within 6 cm of a nest from
24 to 0. And the three §3.8 rows that had been open since M1 — quality
selection, the quality threshold, and task reallocation — each with its
apparatus in `src/world/trials.lisp`.

*Delivered, and the one that mattered.* **Route memory** closes the
oldest open flaw in the model. §3.4 has recorded since M1 that the home
vector is a *vector and not a path*, so a laden ant drives at whatever
stands between it and the nest and slides along it — a trail bent along
an obstacle edge with corpses on it. The ant now keeps its own outward
track as a short list of points and falls back to it when the bearing
home is blocked. On the word scenario, whose entire geometry is
concavities, harvest goes 888 to 1264; on an arena with one small wall it
changes nothing at all, which is the right shape of result for a fix
aimed at concavities. §3.8 is untouched.

Worth recording how it went wrong first, because the failure was
instructive and the acceptance suite caught it in one run. The obvious
implementation has the ant follow the remembered track the whole way
home, and that means retracing its own meander: 470 ticks to cover 10 cm,
which is not homing. It is also the wrong animal — *Cataglyphis* runs the
vector straight home and does not retrace. A route is what you fall back
on when the vector cannot be walked, and making it conditional on the
bearing being blocked is both the correct biology and much the smaller
change.

*And then it went wrong a second way, which took a scenario M4 did not
have to expose.* The list filled and **stopped recording**, so it held
the points nearest the *nest* — the half the return leg can already do
with a straight bearing — and never saw the approach to the food. On the
40 cm journeys M4 measured this merely wasted the mechanism; on
`two-tribes`, where the west nest is 41 cm from a source behind a wall,
it was worse than nothing, handing an ant standing at the food a waypoint
19 cm backwards and through the wall it needed to avoid. A full list now
halves its resolution and doubles its spacing instead, so a fixed budget
of points spans a journey of any length. Both §3.8 rows *improved* — the
double bridge's worst replicate went 0.719 to 0.962 — so the sentence
above is superseded: §3.8 was untouched by route memory as M4 shipped it,
and is measurably better with it working. The numbers, and the test that
had been asserting the bug, are in
[docs/experiments.md](experiments.md).

*Delivered, correct, and inert.* **Response thresholds**, **the no-entry
field** and **search spirals** are all built, tested, and change nothing
at shipped parameters, for three different measured reasons set out in
§3.9 and on each parameter. They are failure-recovery mechanisms, and the
finding is that this model's ants do not currently fail in the ways they
recover from: the foraging stimulus is bimodal rather than graded, dead
ends produce marks too scattered to agree with one another, and path
integration is accurate enough that a home vector does not run out short
of the nest. None of that is an argument against the mechanisms — each
fires and works when its precondition is met. It is an argument that
their preconditions are what the model is missing, and two of them want
the same thing: a remembered food *location*, where an ant here keeps
only a bearing.

*Found rather than planned.* Food amount was single precision, and a
source is the one accumulator whose magnitude and increment are six orders
apart; a large pile could be eaten from for ever without going down
(§3.8). And ε turned out to need its claim restated rather than merely
tested, which is the more interesting half of the competition row.

**M5 — interaction.** Click an ant to inspect its state, drop food, place
obstacles, poke the nest and watch the alarm field propagate. The window
already exists from M2; this is what you can *do* to a running world.

**M6 — polish.** Colour, time-lapse capture, the *Formica* parameter set as
a contrasting species, a gallery document like `docs/M2-renderer.md`.

**Beyond M6 — the contact layer.** Ant-to-ant touch as a communication
channel: trophallaxis between individuals, antennation, tactile
recruitment, nestmate recognition, contact-borne alarm. The collision pass
already produces the contact list this needs (§3.11), which is the only
reason it is worth naming this far out — the groundwork is a decision made
in M1, the work itself is not scheduled.

**Beyond M6 — the 4.1 backend, and with it macOS.** Not scheduled, and
named here because the question was asked and the answer deserves to be
written down once rather than rediscovered.

There is no macOS build and cannot be one as the renderer stands. Apple
froze OpenGL at **4.1** in 2018 and deprecated it outright; that is the
ceiling on every Mac, Intel and Apple Silicon alike. What §5 actually
requires, counted rather than estimated:

| what | needs | sites |
|---|---|---|
| SSBO binds and uploads (`:shader-storage-buffer`) | GL 4.3 | 15 |
| `layout(std430) buffer` blocks — Ants, Bodies, Items, Glyphs | GL 4.3 | 4 |
| `glBufferStorage` + persistent coherent mapping | GL 4.4 | 3 |
| `#version 450 core` | GL 4.5 | 12 |
| direct state access | GL 4.5 | **0** |

The last row is the interesting one. There is not a single DSA call in the
renderer, so the 4.5 in the context request is very nearly just the shader
declaration: **the true floor is 4.4, not 4.5.** That does not rescue
macOS — 4.4 is still three releases above the ceiling — but it does mean
the distance to 4.1 is smaller than the version numbers suggest, and it is
concentrated in one mechanism rather than spread through the code.

That mechanism is how the renderer feeds the GPU. Ants, bodies, HUD items
and glyphs are all written straight through a persistently-mapped SSBO,
which is *the* design decision of §5.1 and not an incidental use. Porting
it means:

1. **SSBO → texture buffer object** (GL 3.1). The natural substitute for
   "one large array indexed by instance ID". A UBO cannot do it: 64 KB
   does not hold thousands of ants.
2. **Persistent coherent map → `glBufferData`/`glMapBufferRange` with an
   explicit flush** (GL 3.0). Costs a copy per frame, which at these
   buffer sizes is nothing measurable.
3. **GLSL 450 → 410**, mechanical once (1) has landed.
4. **A darwin context request** at 4.1 core forward-compatible, and a
   darwin branch in `preload.lisp` — which today is `#-windows` and would
   run the Linux libEGL search on a Mac and find nothing.

The reason to want this is *not* mainly macOS. A 4.1 path is a floor
reduction on every platform: it widens Linux and Windows to a decade more
hardware, and it would make the software-rasteriser CI run cheaper. macOS
comes along for free once the floor is low enough, which is the right way
round — a port undertaken *for* macOS would be a port with one beneficiary
and an expiry date.

Because there is an expiry date. Apple deprecated OpenGL rather than
merely stopping work on it, so a 4.1 backend on macOS is borrowed time and
the durable answer there is Metal, presumably through MoltenVK. That is a
much larger project than this one and it is not proposed.

Two practical obstacles to record before anybody starts. Testing needs a
real Mac: CI macOS runners may not permit a GL context without a window
server session, and a backend nothing can exercise is a backend that
rots. And distribution needs a signature — an unsigned binary is
quarantined by Gatekeeper, and notarisation means a paid Apple developer
account, which is a recurring cost attached to a platform we cannot
currently render on.

What *is* cheap, and is the honest first step whenever this is picked up:
a macOS CI job that builds the core and runs `make test` and
`make acceptance`. No graphics, no artefact, no claim that antsim runs on
a Mac — just the standing proof that the simulation compiles and the
science reproduces on arm64 Darwin, which is exactly the groundwork the
port would otherwise have to establish first.

## 8. Risks

| risk | severity | mitigation |
|---|---|---|
| VS leg articulation fights back | medium | LOD-simple ants work from M2; the pose-LUT fallback is a known-good plan B |
| Literature constants are in units the model does not use (e.g. `k` in "passages", not concentration) | **high** | calibration pass with documented fits, exactly as waldameisen §2.8; the bridge experiments *are* the calibration target |
| Trail dynamics tuned into a regime that looks right but is not | medium | the n=1 control test — if it still selects a path, the selection is coming from something other than the choice function |
| Multi-rate clocks introduce order dependence | medium | deposit buffers + previous-tick reads make the ant step commutative; the determinism test catches regressions |
| Performance | low | 5 k ants × 160 k cells at 20 Hz is small; waldameisen already instanced 3 k |
| Scope — the science is deep enough to never ship | **high** | The §3.9 cut is the answer: M1 builds a named subset, §3.8's table is the definition of done, and everything else is explicitly scheduled rather than argued about again |
| Non-overlap relaxation does not converge in a dense crowd | medium | Jacobi with a fixed 2–3 iterations is a *soft* constraint — residual overlap is bounded, not zero. If a queue at a rich source jitters or squeezes, raise iterations before changing the scheme; the acceptance row in §3.8 measures it rather than assuming it |
| Corpses accumulate until they choke a nest | **closed, M4** | Necrophoresis, §3.9. Worth recording that the control was not "nothing happens": ant traffic bulldozes corpses whether or not anyone carries them, and that alone shifted half of them off the nest, so only a run with the behaviour switched off was an honest baseline |
| The renderer's GL floor excludes whole platforms | low, accepted | The persistently-mapped SSBO path needs GL 4.4, which puts macOS (capped at 4.1 since 2018, and deprecated) permanently out of reach and rules out older hardware everywhere else. Accepted deliberately: §5.1's design is worth more than the platforms it costs, and the count is reassuring — 15 SSBO sites, 3 buffer-storage sites, and **zero** direct-state-access calls, so the exposure is one mechanism rather than a pervasive assumption. The way out, if it is ever wanted, is a 4.1 backend on texture buffer objects — see *Beyond M6* |
| Failure-recovery mechanisms cannot be evaluated, because the model does not fail that way | medium | Named at M4, when three of them landed inert for three different measured reasons. It is not a defect in any of the three — each is correct and each fires when its precondition is met — but it does mean their value is currently unmeasurable, and that route memory and the parked stall detection are what would make them testable |

## 9. Open decisions

### Settled

1. **Reference species — *Lasius niger*.** Best trail literature, a true
   mass recruiter. *Formica polyctena* becomes a contrasting parameter set
   at M6.
2. **Complexity is capped at the §3.9 cut.** M1 builds that subset and
   nothing past it. Everything deferred is scheduled, not deleted, and each
   deferred item is addable without changing the tick's shape.
3. **Trails are never authored** (§3.3). The scenario format has no way to
   place pheromone, by construction.
4. **The live window lands at M2, with cursor-anchored wheel zoom and
   right-drag pan** (§5.5) — so arena size, ant count and render scale stay
   open questions instead of up-front guesses.
5. **Population is dynamic on top of a configured start** (§3.10).
   `capacity` bounds memory, `start` is an initial condition, and the
   running count is a result — including zero, when a colony starves.
6. **Ants are discs; obstacles are polygons** (§3.11). One non-overlap rule,
   Jacobi resolution so determinism survives.
7. **Trail fields are per colony with an eavesdropping coefficient ε**
   (§3.12). M1 runs one colony; the indirection is free now and
   unaddable later. **ε is small — default 0.1.** A large ε would let a
   neighbour's trail dominate the `(k + C)ⁿ` weights and collapse the
   colonies into one shared field; small ε perturbs without steering,
   which is the behaviour worth having.
8. **Repository** — initialised, pushed to `bonk/antsim`, branch `concept`.

### Still open

1. **Colony scale.** → hundreds of ants in a 1–2 m arena for the M1
   acceptance scenarios, since those reproduce lab experiments at lab
   scale. With pan and zoom in from M2 this is much less of a commitment
   than it was; `capacity` and arena size are per-scenario anyway.
2. **JSON dependency.** → `com.inuoe.jzon`, confined to `antsim/scenario`
   so the core stays dependency-free. Alternative: a hand-rolled reader, to
   keep the whole project dependency-free.
3. **Default branch.** `concept` is currently the only branch on the
   remote; nothing has been set as default yet.

## 10. Sources, and what still needs checking

The mechanisms are well established. **Several specific constants below are
from memory and must be verified against the papers before they are
committed to code** — this project inherits waldameisen's rule that nothing
is silently tuned, and that rule is worth nothing if the "measured" values
were guessed.

**Implemented as runnable experiments.** These two are not background
reading: they are in the suite, as apparatus, with the papers' own
criteria. `make acceptance` runs them; the apparatus is
`src/world/bridge.lisp` and the assertions are `tests/acceptance.lisp`.
Anything cited here that the code depends on should be reachable by
someone who wants to check the claim, so each carries a general-audience
link as well as the citation.

- **Deneubourg, Aron, Goss & Pasteels (1990)**, *The self-organizing
  exploratory pattern of the Argentine ant*, J. Insect Behavior 3:159 — the
  binary bridge, and the nonlinear choice function `(k+C)^n`.
  Background: [Stigmergy](https://en.wikipedia.org/wiki/Stigmergy),
  [Self-organization](https://en.wikipedia.org/wiki/Self-organization).
  → **passes**, ≥93% commitment across 8 seeds, winner varying with seed.
- **Goss, Aron, Deneubourg & Pasteels (1989)**, *Self-organized shortcuts in
  the Argentine ant*, Naturwissenschaften 76:579 — the double bridge and
  shortest-path selection.
  Background: [Ant colony optimization
  algorithms](https://en.wikipedia.org/wiki/Ant_colony_optimization_algorithms),
  which is the double bridge's direct descendant in computer science, and
  [Swarm intelligence](https://en.wikipedia.org/wiki/Swarm_intelligence).
  → **passes**, short arm winning 8 of 8 at a length ratio of 1.73.

**Load-bearing, confident:**
- **Beckers, Deneubourg & Goss (1992, 1993)** on *Lasius niger* trail laying
  — deposition modulated by food quality, and the quality threshold below
  which no trail is laid.
- **Robinson, Jackson, Holcombe & Ratnieks (2005)**, *"No entry" signal in
  ant foraging*, Nature 438:442 — the repellent pheromone.
- **Bonabeau, Theraulaz & Deneubourg** — the response-threshold model of
  division of labour.
- **Hölldobler & Wilson (1990)**, *The Ants* — age polyethism, trophallaxis,
  recruitment taxonomy; the general reference.
- **Müller & Wehner** on *Cataglyphis* path integration; and the systematic
  search spiral of a homing ant that arrives at the wrong place.
  Background: [Path integration](https://en.wikipedia.org/wiki/Path_integration),
  [*Cataglyphis*](https://en.wikipedia.org/wiki/Cataglyphis).
- **Charbonneau & Dornhaus** — inactivity as a genuine specialization, not
  sampling noise.

The species is worth a link too, since every parameter in §3.1 is
supposed to be its: [*Lasius
niger*](https://en.wikipedia.org/wiki/Lasius_niger), and the
[Argentine ant](https://en.wikipedia.org/wiki/Argentine_ant) the two
bridge experiments were actually run on. That difference is a real
caveat, not a footnote: both papers used *Linepithema humile* and this
model is parameterised for *L. niger*. The mechanism is believed to be
the same and the model reproduces both results — which is itself a claim,
and one the acceptance suite is now making on every run.

**Worth checking against, not yet checked:**

- **Dussutour, Fourcassié, Helbing & Deneubourg (2004)**, *Optimal traffic
  organization in ants under crowded conditions*, Nature 428:70 — crowding
  reshaping trail traffic in *L. niger*, on branched bridges among others.

  This is the paper the binary bridge's **metastability** should be read
  against. Watching a long run, a committed arm can lose its commitment
  and regain it, and it appears to happen only once the population is
  large enough for the corridors to jam. The mechanism is coherent and is
  the same one that decides the double bridge: a congested arm takes
  longer to get round, and round-trip time is the only thing the model
  responds to — nothing measures a distance. Congestion lengthens an arm
  exactly as geometry does.

  That is an unscripted, density-dependent prediction falling out of the
  collision rule and the deposition rule together, which is a good sign.
  It is **not** a validated result: nobody has compared the switching rate
  to a real colony's, and `*trail-decay-scale*` compresses τ by 30×, which
  makes the field forget faster than any dish and switching correspondingly
  more likely. The rate is not comparable even if the mechanism is.

  The acceptance row is unaffected either way — it measures the *initial*
  commitment, in a window at 6–12 minutes.

**Known limitations, measured:**

- **No ant ever dies of old age.** `*max-age-ticks*` is 24 simulated
  hours and the longest run is one, so starvation is the only death that
  has ever fired and the model has no age structure at all. Lowering the
  lifespan does not help a colony that has run its stock to zero — such a
  colony is trapped, with too many spent workers drawing upkeep for any
  of them to be fed back over the departure threshold, and culling
  removes foragers as fast as it removes mouths. Measured at 20- and
  60-minute lifespans: the colony dies sooner, not later.

- **The double bridge's arms were not the same width.** Offsetting each
  corridor's boundary horizontally by half the corridor width is only
  correct for a *vertical* arm; a slanted one comes out narrower by
  cos(slant). The long arm was 0.0384 m against the short arm's 0.0600 —
  36% narrower, 7.7 ants abreast against 12 — so it was longer *and* more
  congested, and "the short arm wins" could not distinguish distance from
  crowding. That is precisely the confound the apparatus exists to
  exclude, and the code claimed in its own docstring to have excluded it.

  Fixed by scaling each arm's horizontal offset by its slant. The result
  survives: the short arm still wins 8 of 8, but at **69–83%** of traffic
  rather than 73–96%. The confound was inflating the effect without
  creating it.

**Needs verification before it becomes a constant:**

- **The citations above are from memory and carry no DOIs.** Volume and
  page numbers especially: they are worth checking against the papers
  before anyone cites this project's reading of them. The Wikipedia links
  are orientation for a reader, not sources.

- `n ≈ 2`, `k ≈ 20` — the values I recall from Deneubourg 1990, in units of
  *bridge passages*. The exponent is the robust part; `k` needs both the
  paper and a unit translation into the sim's concentration scale.
- Trail pheromone lifetime τ — "tens of minutes" for *L. niger* is safe;
  the specific half-life is not, and it is one of the most consequential
  parameters in the model.
- Walking speeds, crop capacity, and the sucrose threshold for trail laying
  — all quoted approximately above and all needing a source.
- Whether *Formica polyctena*'s weak trail-following is best modelled as a
  low deposition rate, a low following fidelity, or a shorter τ. Probably
  all three, but that is a claim, not a citation.

A `docs/calibration.md` should hold these, each with the fit it came from
and the date, in the waldameisen style.

---

*Next step: agree §9, then M0.*
