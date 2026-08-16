# Configuration

Every tunable in the model is a `defparameter` in **`src/params.lisp`** —
one file, deliberately, so the whole calibration can be read in one sitting
and nothing behavioural hides in the code that uses it. Each carries its
provenance (`[lit]` from the literature, `[scale]` derived from §3.1's scale
table, `[cal]` a free parameter nobody measured) and, where it exists, the
measurement that set it.

There are three ways to change one:

| where | reaches | survives |
|---|---|---|
| `src/params.lisp` | everything | it *is* the default |
| scenario JSON | the subset marked ⬥ below | the run |
| the live window | two keys | until you press them again |

**Anything not marked ⬥ can only be changed in source or by rebinding it in
Lisp.** That is a real gap rather than a design: the JSON surface grew when
a particular experiment needed it, so it covers the choice function, the
trail field and the colony rules, and nothing else.

## Why so many are off

Six of these default to **off with their numbers recorded**. That is the
discipline described in [experiments.md](experiments.md), not neglect: a
change ships on its measurement or ships off with it, and one of them
measured *best of anything tried* and is off anyway because it would have
the colony compute something no ant can sense. Results decide between
mechanisms that are equally defensible; they do not decide whether a
mechanism is defensible.

## Navigation (§3.2, §3.4)

| parameter | default | off | what it does |
|---|---|---|---|
| `*obstacle-avoidance*` | 1.0 | 0.0 | antennae veto a direction whose sample is inside terrain |
| `*homing-scan-steps*` | 12 | 0 | how far round a blocked home bearing an ant looks, in 15° steps; 12 is a half turn |
| `*trail-homing-suppression*` | 0.0 | 0.0 | lets a trail override the straight-line bearing. Measured at −29% — **on a model two rounds out of date**, so the negative is stale and it exists to be re-measured |

## Trails (§3.3)

| parameter | default | what it does |
|---|---|---|
| ⬥ `*trail-decay-scale*` | 30.0 | evaporation speed — **lower is slower**. Measured free in outcome, threefold in appearance |
| ⬥ `*trail-cap*` | 600.0 | per-cell saturation ceiling |
| ⬥ `*trail-packet-radius*` | 0.015 | how wide one gaster-touch spreads |
| ⬥ `*trail-tau*`, `*trail-deposit*`, `*trail-packet-spacing*`, `*trail-packet-falloff*` | | the rest of the field and packet shape |
| ⬥ `*choice-n*`, `*choice-k*`, `*choice-eavesdrop*` | 2.0, 20.0, — | the Deneubourg choice function — **the model** |
| `*trail-lost-threshold*` | **0.0 = off** | U-turn on losing a trail; 0.15 enables. Works (trail residence ×3) and does not pay (−4% foraging) |
| `*trail-follow-threshold*` / `*trail-memory-decay*` | 0.5 / 0.93 | the two-level trigger the U-turn needs; one level fires on any faint mark and cost 28% |
| `*uturn-ticks*` / `*uturn-cast-gain*` | 40 / 3.0 | how long the casting lasts and how wide it sweeps |

## Colony demography (§3.10)

| parameter | default | off | what it does |
|---|---|---|---|
| ⬥ `*queen-lay-rate*` | 12.0 | 0 = uncapped | eggs per simulated minute. **The largest single win after the homing fix**: +24% food, minimum larder 307 against zero, deaths 23 → 1 |
| ⬥ `*brood-development-minutes*` | 8 | 1 | egg → worker delay. Worth +17% on its own — a lag is a feedback term, not a detail |
| ⬥ `*brood-investment*` | 0.1 | 0 = no brood | fraction of the breedable larder spent per colony tick |
| ⬥ `*brood-reserve-ration*` | **0.0 = off** | | breed from surplus over a per-worker reserve. Measured **best of anything tried** (4929 vs 4778) and off anyway: it needs a colony-wide aggregate |
| ⬥ `*forager-maturity-ticks*` | **0 = off** | | callow workers do not forage. Real (temporal polyethism) and costs 7% — maturity without nursing is all cost, since young ants here do nothing |
| ⬥ `*max-age-ticks*` | — | | death by age. Documented as unreachable in practice |
| `*age-shade-ticks*` | 36000 | | display only: age at which an ant draws as fully mature |

## Energy and the nest (§3.5)

| parameter | default | off | what it does |
|---|---|---|---|
| `*forager-eats-at-source*` | **t** | nil | an ant standing on food eats. Modest, consistent: ~5–9% fewer deaths in both arms |
| `*nest-meals-per-tick*` | 2 | 0 = the old trough | hungriest resting ants fed to satiety, bounded per tick. **Modelling, not a fix** — the collapse it addressed was pre-queen and no longer occurs |
| `*nest-feed-rate*` | 0.002 | | the old communal sip, used only when meals are off |
| ⬥ `*forager-expendability*` | **1.0 = off** | | 0.0 means a forager from an empty nest never turns back. Measured harmful: population 626 → 207, deaths 23 → 457, births flat |
| ⬥ `*resting-ants-block*` | **nil** | t | whether resting ants take part in ant-ant collision. Left switchable on purpose: passing runs smoother, colliding looks better, and nothing in the model ranks those |

## Live window

| key | does |
|---|---|
| `A` | drop a food source at the cursor |
| `N` | toggle whether resting ants collide |
| `H` / `?` | show or hide the key legend |
| `SPACE` | pause |
| `+` / `-` | time compression |
| `HOME` | frame the whole world |
| wheel · right-drag · left-click | zoom · pan · inspect |
| `Q` / `ESC` | quit |

```sh
SCENARIO=scenarios/antsim.json make live     # a scenario file
SEED=397767704 make live                     # repeat a run
```

Without `SEED` the window draws a fresh one and prints it, so every session
differs and any session worth keeping can be replayed. The headless paths —
tests, acceptance, gallery — are unaffected and stay deterministic.

## Scenario JSON

The ⬥ parameters are settable per run, in three blocks:

```json
"choice":     { "n": 2.0, "k": 20.0 },
"pheromones": { "trail": { "decay_scale": 20.0, "max": 600.0 } },
"colony_rules": {
  "queen_lay_rate": 12.0,
  "brood_development_minutes": 8,
  "brood_investment": 0.0,
  "max_age_ticks": 2000000000,
  "resting_ants_block": false
}
```

Unknown keys are an **error naming the path**, not a silent ignore — a
scenario that quietly drops a setting is worse than one that refuses to
load. `_`-prefixed keys are comments and are allowed anywhere.

Both bridge scenarios use `colony_rules` to pin their experimental
protocol: a fixed colony, and no death by old age. That is stated in the
file rather than applied inside the run loop, because controls hidden in a
run loop are controls nobody can check — and because it keeps the JSON and
Lisp forms of those experiments the same experiment.
