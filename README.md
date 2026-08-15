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
- **U-turns.** An ant that loses a trail it was following performs a
  characteristic U-turn and casts about, rather than continuing. This is
  observed in *L. niger* and is a large part of why trails are stable: the
  ants actively re-find them.
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
2. **Trail following.** §3.3. Used when trail concentration exceeds the
   detection threshold.
3. **Landmark / route memory.** A learned association between a remembered
   view and a direction. This is the *Formica* mode; keep it as a stub in
   the first version (a per-ant memory of the last successful food bearing)
   and expand later.

Weighting these is where personality comes from. An ant with a strong home
vector and a weak trail ignores the trail. This is observed and it is what
prevents a colony from being trivially hijacked by a single strong trail.

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
| No-entry, alarm, nest-marking fields | *later* | Three of the four fields. None is needed for §3.8; each is a self-contained addition to an existing field abstraction. |
| Response thresholds, age polyethism | *later* | M1 has one task. Age still accumulates and still kills — it just does not yet steer behaviour. |
| Trophallaxis between ants | *later* | M1 unloads the crop straight into nest stock. The ant–ant transfer is the only mechanism in the model needing pairwise coupling, and skipping it keeps the M1 tick embarrassingly parallel. |
| Landmark / route memory | *later* | The *Formica* mode; irrelevant to a mass recruiter. |
| U-turns, search spirals, thigmotaxis | *later* | Real, measured, and all three make trails *more* stable — so M1 passing without them is the stronger result. |
| Necrophoresis | *later* | Corpses accumulate in M1 and nothing clears them. A behaviour, not a mechanism — it needs only a new task and a midden. |
| Multiple colonies | *later* | The data model supports them from day one (§3.12); M1 runs one, because nothing in §3.8's core rows needs two. |

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
- **Birth rate** is a function of nest food stock: the colony converts
  stored food into new workers at a rate proportional to what it has,
  scaled by a configured brood efficiency, and clamped at capacity. A
  colony that forages well grows; a colony that cannot feed itself
  shrinks. That coupling is the whole point and it is one line of arithmetic.
- **Death** comes from energy reaching zero and from age, with a per-tick
  hazard that rises with age. Foragers die away from home; that is what
  foragers do.
- **No brood stages** in M1 — no eggs, larvae, pupae, no development time,
  no nurses. A single `stock → workers` rate is the sound simple
  abstraction; brood stages are a refinement that adds a lag, and the lag
  is the only thing they add until nursing exists to interact with it.

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
make test-render       renderer suite, under the guix GPU shell
make test-render-ci    the same without the GPU shell — GL tests skip
make smoke             M0 end to end: headless frame → out/m0-smoke.png
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
4. **Food sources** — radius scales with remaining amount, so depletion is
   visible without a number; colour or saturation encodes quality.
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
| left-click an ant | inspect: state, energy, crop, age, home vector |
| `home` | frame the whole world |

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

  "choice": { "n": 2.0, "k": 20.0, "eavesdrop": 0.0 },

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

## 7. Milestones

Deliberately shaped like waldameisen's: each milestone ends in something
verifiable, and the risky spikes come early.

**M0 — the stack stands up. ✅ done.** ASDF systems, package,
`util`/`rng`/`pool` carried over, FiveAM wired, Makefile with the guix GPU
targets. A headless context comes up and writes a non-black PNG. *Proves
the toolchain before any design is committed to it.*

Verified: core suite 40 141 checks green with no GPU; render suite 35
checks green on GL 4.5.0 core / NVIDIA 580.159.04 / RTX 3070, drawing a
real GLSL 450 frame into an FBO and encoding it. `make smoke` writes
`out/m0-smoke.png`.

Two things came out of building it rather than planning it. The RNG grew a
`seed` argument, because §3.8's symmetry-breaking result is a claim about a
*distribution over runs* and needs independent replicates of one scenario —
and it is an argument rather than a special variable because a `let`-bound
special is thread-local in SBCL, so workers would silently keep the global
value and every replicate would come out identical. And the mixer had a
fixed point: `hash32(0) = 0`, so ant 0 on tick 0 drew exactly `0.0`. Both
are pinned by tests now.

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

**M3 — the ant model.** The vector ant, the tripod gait rig, VS
articulation, LOD, antennae, payload, state tint. The one genuinely novel
piece of engineering in the project, and it gets its own milestone because
it deserves the room to be got right. Note the collision model does not
change: the disc stays, the drawing gets legs (§3.11).

**M4 — scenarios and behaviour depth.** JSON loading, richer scenes, and
then the deferred half of §3.9 in dependency order: response thresholds and
age polyethism, trophallaxis, the no-entry and alarm fields, necrophoresis
and middens, U-turns and search spirals. Multiple colonies and the ε
competition scenario.

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
| Corpses accumulate until they choke a nest | low | Intended, and visible. It is the argument for necrophoresis at M4, not a defect — but a scenario running for simulated weeks needs the midden behaviour before its results mean anything |

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
   unaddable later.
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

**Load-bearing, confident:**

- **Deneubourg, Aron, Goss & Pasteels (1990)**, *The self-organizing
  exploratory pattern of the Argentine ant*, J. Insect Behavior 3:159 — the
  binary bridge, and the nonlinear choice function `(k+C)^n`.
- **Goss, Aron, Deneubourg & Pasteels (1989)**, *Self-organized shortcuts in
  the Argentine ant*, Naturwissenschaften 76:579 — the double bridge and
  shortest-path selection.
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
- **Charbonneau & Dornhaus** — inactivity as a genuine specialization, not
  sampling noise.

**Needs verification before it becomes a constant:**

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
