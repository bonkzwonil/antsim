# antsim — a playful 2D ant colony, built on real science

**Status: concept. No code yet.** This document is the design; it is meant
to be argued with before anything is implemented.

A top-down, GL-rendered simulation of individual ants foraging in a scene
of nests, food sources, obstacles and pheromone fields. Every ant is an
agent with its own state — energy, crop load, age, a home vector, a set of
task thresholds — and every behaviour it runs is a mechanism that has been
measured in real ants and is cited here as such.

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

**Fields, in the order they should be built:**

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

**Behavioural modes**, as a state machine:

```
        ┌──────────────────────────────────────────────┐
        │                                              │
   IN-NEST ──(task threshold exceeded)──► EXPLORING ───┤
        ▲                                    │         │
        │                          (trail found)       │
        │                                    ▼         │
        │                            TRAIL-FOLLOWING   │
        │                                    │         │
        │                             (food reached)   │
        │                                    ▼         │
        │                                 AT-FOOD      │
        │                          (crop full / poor)  │
        │                                    ▼         │
        └──(unload, trophallaxis)──── RETURNING ◄──────┘
                                            │
                                   (home vector fails)
                                            ▼
                                        SEARCHING ──► (re-find or die)
```

Plus `DEAD`. Transitions are driven by continuous quantities, not timers:

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

**Obstacles** are convex polygons, kept in two representations: the polygon
for rendering, and a rasterized blocked-cell bitmask for collision and for
masking pheromone diffusion. Ants collide, slide along, and preferentially
follow edges (§3.2 thigmotaxis).

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

That table is the project's definition of "working".

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
src/package.lisp        the ANTSIM package (nickname AS)
src/util.lisp           specialized array types + constructors   [from wa]
src/rng.lisp            counter-based RNG keyed on (id, tick)    [from wa]
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
resizing anything. Pheromones are `(simple-array single-float (*))` per
field, indexed `y*w + x`. No consing in the tick loop, ever.

Deposits are accumulated into a **separate deposit buffer** per field and
folded in on the pheromone clock. This is what makes the ant loop
order-independent — two ants depositing in the same cell in the same tick
commute — which is what makes threading bit-exact.

**Spatial hash** over a coarse grid (say 5 cm cells) for ant–ant and
ant–food proximity queries. Rebuilt each tick by counting sort into
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

### 5.5 Live window

Headless covers tests and image output but not "watch it run", which is
most of the point of a playful sim. Options:

- **cl-glfw3** — minimal, well-suited to a single GL window, easy input.
  Recommended.
- **sdl2** — heavier, more capable, more moving parts.
- **frame sequence → ffmpeg** — no new dependency at all, good enough for
  sharing results, useless for interaction.

Recommendation: build M1–M4 headless-only, then add `antsim/live` on GLFW.
Keeping the renderer surface-agnostic from the start costs nothing and
makes this a small addition later.

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

  "choice": { "n": 2.0, "k": 20.0 },

  "nests": [
    { "id": "home", "x": 0.10, "y": 0.40, "r": 0.03,
      "population": 400, "stock": 0.5 }
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

**M0 — the stack stands up.** ASDF systems, package, `util`/`rng`/`pool`
carried over, FiveAM wired, Makefile with the guix GPU targets. A headless
context comes up and writes a non-black PNG. *Proves the toolchain before
any design is committed to it.*

**M1 — the core simulation, no renderer.** Ant table, CRW movement,
collision, pheromone fields with decay and deposit fold-in, the choice
function, path integration, the foraging state machine, food depletion.
*Ends when the §3.8 acceptance tests pass* — symmetry breaking and
shortest-path selection, verified numerically with no picture involved.
This is the milestone that decides whether the science is right, and it
deliberately does not depend on a single line of GL.

**M2 — the renderer, simple ants.** Ortho camera, pheromone field texture,
obstacles, food, nests, ants as simple bodies. Headless PNG gallery of the
M1 scenarios. *First time you can see a trail form.*

**M3 — the ant model.** The vector ant, the tripod gait rig, VS
articulation, LOD, antennae, payload, state tint. The one genuinely novel
piece of engineering in the project, and it gets its own milestone because
it deserves the room to be got right.

**M4 — scenarios and behaviour depth.** JSON loading, richer scenes,
response thresholds, age polyethism, trophallaxis, no-entry pheromone,
alarm. Multiple nests.

**M5 — live and interactive.** GLFW window, camera pan/zoom, run/pause/
speed, click an ant to inspect its state, drop food, place obstacles, poke
the nest and watch the alarm field.

**M6 — polish.** Colour, time-lapse capture, the *Formica* parameter set as
a contrasting species, a gallery document like `docs/M2-renderer.md`.

## 8. Risks

| risk | severity | mitigation |
|---|---|---|
| VS leg articulation fights back | medium | LOD-simple ants work from M2; the pose-LUT fallback is a known-good plan B |
| Literature constants are in units the model does not use (e.g. `k` in "passages", not concentration) | **high** | calibration pass with documented fits, exactly as waldameisen §2.8; the bridge experiments *are* the calibration target |
| Trail dynamics tuned into a regime that looks right but is not | medium | the n=1 control test — if it still selects a path, the selection is coming from something other than the choice function |
| Multi-rate clocks introduce order dependence | medium | deposit buffers + previous-tick reads make the ant step commutative; the determinism test catches regressions |
| Performance | low | 5 k ants × 160 k cells at 20 Hz is small; waldameisen already instanced 3 k |
| Scope — the science is deep enough to never ship | **high** | M1's acceptance table is the definition of done; everything past it is optional |

## 9. Open decisions

These change the work materially, so they are called out rather than
silently assumed. Current assumption is marked **→**.

1. **Reference species.** → *Lasius niger* (best trail literature, true mass
   recruiter). Alternative: *Formica polyctena* for waldameisen continuity,
   at the cost of pheromone trails being the wrong lens for the species.
2. **Live window.** → headless-only through M4, GLFW at M5. Alternative:
   bring the window forward to M2 if watching it run matters more than
   testing it early.
3. **Colony scale.** → hundreds of ants in a 1–2 m arena, individually
   visible and legible. Alternative: thousands, which is more spectacular
   and less playful.
4. **JSON dependency.** → `com.inuoe.jzon`, confined to `antsim/scenario`
   so the core stays dependency-free. Alternative: hand-rolled reader to
   keep the whole project dependency-free.
5. **Repository.** → antsim as its own git repo, mirroring waldameisen's
   layout and CI. Not yet initialized.

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
