# Experiments

A lab notebook, not a design document. `concept.md` records what the model
does and why; this records the runs that decided it — including the ones
that decided *against* something, which are the entries most worth having.

## How a change gets in

Every behavioural change ships with an **off-switch**: a parameter whose
old value restores the previous behaviour exactly. That is not a
convenience, it is what makes the claim measurable rather than asserted —
a change with no off-switch can only be argued about.

The order is:

1. **Diagnose**, and say what would falsify the diagnosis.
2. **Screen** one factor at a time against the baseline.
3. **Combine** only the factors that moved something.
4. **Set the default from the numbers**, and record the number even when
   it says no.

Step 4 is the one that costs something. Three changes so far are built,
tested, documented and **off**, because they worked and did not pay.

## The harness

`factor.lisp` (session scratch, not in the repo) takes a list of factor
names, binds every switch to its old value, turns on the named ones, and
runs the double bridge for 40 simulated minutes across three seeds,
averaging. Columns: food taken from the source, total births, final and
peak population, the **minimum larder after minute 10**, final larder, and
deaths.

The minimum larder is the headline. A colony can look healthy on every
other column while sitting permanently at zero reserve, and that turned
out to be the actual failure.

## Log

### Wall-following (§3.2, §3.4) — shipped

The homing bearing ignored the antennae, so a laden ant walked into walls
and slid along them, marking the surface as it went. Fixed by giving the
bearing the same antennal veto.

| scan | food | pop | died |
|---|---|---|---|
| off | 571 | 181 | 126 |
| 90° cap | 1739 | 287 | 152 |
| half turn | **2368** | **488** | **0.5** |

Two wrong versions first, both kept in the source: deriving the turn side
from the ant's heading (unstable — a stalled ant steers into its own
pheromone), and capping the scan at a right angle (the arc is measured
from the bearing, which is perpendicular to the wall for one instant
only).

### U-turn on a lost trail (§3.2) — built, off

Works: trail residence ×3 over six seeds. Does not pay: neutral on the
bridge, −4% in the open arena, same direction in every seed.

First version fired on any faint trail brushed in passing and cost 28% of
food delivered; the trigger needs two levels, not one.

### Forager expendability (§3.5) — built, off pending the screen

Diagnosis: departure and give-up were one number, so an ant leaving at the
margin already met the condition to turn back.

| expendability | eaten | born | pop | stock | died |
|---|---|---|---|---|---|
| off | 4021 | 657 | 626 | 0.0 | 31 |
| half | 3973 | 653 | 271 | 11.6 | 382 |
| full | 4029 | **664** | 109 | 54.8 | 555 |

Births flat within 2%. Spending foragers converts standing workers into
corpses at an unchanged production rate. The larder recovers only because
there are fewer mouths.

### Unregulated growth (§3.10) — the actual cause

Traced through a collapse at the old settings:

| minute | pop | stock | nest | outbound | at food | delivered |
|---|---|---|---|---|---|---|
| 1 | 169 | 359 | 19 | 141 | 0 | 14 |
| 20 | 519 | 344 | 61 | 337 | 1 | 170 |
| 40 | 743 | **0** | 79 | 451 | 0 | 5 |

Population rises monotonically, larder falls monotonically, and delivery
is *fine* throughout — averaging 120/minute. The colony was never failing
to fetch food. It converted every surplus into mouths, so its fixed point
is zero reserve, and a colony with no reserve cannot absorb the jams and
trail collapses that this simulation produces constantly.

Two hypotheses were eliminated by measurement before this one was found:
the nest entrance jamming (laden ants queued outside the unload radius
never exceeded 16) and ants oscillating through the door (they were
*outbound*, 553 of them, with one ant at the food).

### Colony factor screen

Six factors, each alone against the baseline, three seeds, 40 simulated
minutes, averaged.

| config | eaten | born | pop | min-stock | died |
|---|---|---|---|---|---|
| base | 3934 | 650 | 626 | **0.0** | 23 |
| nest | 3552 | 584 | 555 | 0.0 | 28 |
| spend | 3873 | 664 | 207 | 20.2 | 457 |
| reserve | 4416 | 604 | 600 | 205.4 | 3 |
| **queen** | **4881** | 618 | 617 | **307.0** | **1** |
| develop | 4619 | **697** | **688** | 176.6 | 9 |
| mature | 3981 | 670 | 666 | 58.0 | 4 |
| all six | 4248 | 486 | 484 | 328.7 | 2 |

Every brood factor breaks the zero-reserve lock *and* delivers more food.
The single best change is the queen's bounded lay rate: +24% food, a
minimum larder of 307 against nothing, and deaths from 23 to 1. Capping
how fast a colony can convert a windfall into mouths turns out to be
worth more than anything else tried.

`all six` is worse than the best subsets because it carries the two
factors that cost something, which is the argument for screening before
combining.

Two negatives:

- **spend** — population 626 to 207 and deaths 23 to 457, with births
  flat. The superorganism reasoning behind it is sound and the model
  disagrees: it kills workers faster without producing more.
- **nest** — a net 10% cost. This *reverses* an earlier reading of the
  same change, and the earlier one was wrong because resting ants were
  then exempt from terrain and walking through obstacles. It survives on
  its modelling argument — the nest disc is a door, not a chamber system
  — and not on its numbers, which is how it is presented.

### Colony combinations

Only the factors the screen moved, plus the two it showed costing
something so their cost is measured *in combination* rather than assumed.

| config | eaten | born | pop | min-stock | died |
|---|---|---|---|---|---|
| base | 3934 | 650 | 626 | 0.0 | 23 |
| queen | 4881 | 618 | 617 | 307.0 | 1 |
| queen+reserve | 4142 | 552 | 550 | 242.4 | 2 |
| queen+develop | **5069** | 534 | 532 | **360.8** | 2 |
| reserve+develop | 4922 | 637 | 635 | 328.4 | 2 |
| queen+reserve+develop | 4587 | 533 | 530 | 325.9 | 3 |
| +maturity | 4167 | 486 | 485 | 329.5 | 1 |
| +maturity+nest | 4248 | 486 | 484 | 328.7 | 2 |
| +maturity+spend | 4167 | 486 | 485 | 329.5 | 1 |

The last row is **identical to the one above it in every column**.
Forager expendability has become unreachable: once the colony holds a
reserve, urgency never rises to where it fires. Fixing the cause did not
merely make the symptomatic change unnecessary, it made it inert.

Reserve and queen are two regulators of one overshoot, so stacking them
over-damps — the colony grows more slowly and ends smaller without
holding more.

### Confirmation, five seeds — and a reversal

| config | eaten | born | pop | min-stock | died |
|---|---|---|---|---|---|
| base | 4042 | 659 | 636 | 8.2 | 22 |
| queen+develop | 4778 | 534 | 532 | 312.0 | 2 |
| **reserve+develop** | **4929** | **639** | **638** | 323.8 | 2 |
| queen+develop+nest | 4131 | 502 | 498 | 264.1 | 4 |
| queen+develop+maturity | 4446 | 524 | 523 | 335.8 | 2 |

Five seeds reverse the three-seed winner. `reserve+develop` scored 4922
and 4929 across the two rounds; `queen+develop` swung 5069 → 4778. The
3% gap that made queen+develop look best was seed noise, and acting on it
would have shipped the wrong default and a wrong sentence in §3.10.

**Rule earned here: a gap of a few percent on three seeds is not a
result.** The 24% gap from the baseline was always safe to trust; the one
between the leaders was not.

**And the winner on numbers is not the one that shipped.** `reserve`
requires the colony to compute stock per living worker and decide against
it — a colony-wide aggregate, which is exactly what this model refuses
everywhere else. §3.5 is explicit that foraging urgency is *the only*
quantity read colony-wide, and that an ant learns it locally by asking for
food and being given none; a second global reader in the brood rule spends
that principle for 3%.

A bounded lay rate and a development delay ask nobody to compute anything.
One animal can lay only so fast, and an egg takes as long as it takes.
The regulation falls out of two physical facts rather than out of a
measurement the colony has no way to make — so `queen+develop` ships, at
4778 against 4929, and the 3% is the price of not inventing a sense.

Results decide between mechanisms that are equally defensible. They do
not decide whether a mechanism is defensible.

`nest` costs 14% and `maturity` 7%, both consistent across every round
they appear in.

### Calibrating the queen — and an error in how it was asked

First attempt swept the lay rate on top of `reserve+develop`:

| lay rate | eaten | born | pop | min-stock |
|---|---|---|---|---|
| 0 (off) | 4929 | 639 | 638 | 323.8 |
| 12 | 4493 | 533 | 530 | 305.5 |
| 25 | 4929 | 639 | 638 | 323.8 |
| 50 | 4929 | 639 | 638 | 323.8 |
| 100 | 4929 | 639 | 638 | 323.8 |

Identical to unbounded at every rate above 25 — the cap never binds.
Which is the right answer to the wrong question: `reserve` is not
shipping, and with it present the reserve does the regulating while the
cap is a formality that only shows up as a cost when set too low.

In the shipping configuration the cap **is** the feedback term. The same
number is being asked to do a completely different job, so it was swept
again against `develop` alone.

**A parameter calibrated in a configuration you are not shipping is not
calibrated.**

Swept again against `develop` alone, where the cap carries the whole
feedback term:

| lay rate | eaten | born | pop | min-stock | died |
|---|---|---|---|---|---|
| 0 (off) | 4549 | 701 | 695 | 149.2 | 6 |
| 6 | 4539 | 342 | 340 | 493.7 | 2 |
| 9 | 4446 | 438 | 436 | 400.4 | 2 |
| **12** | **4778** | 534 | 532 | 312.0 | 2 |
| 18 | 4138 | 674 | 669 | 84.3 | 6 |
| 25 | 4549 | 701 | 695 | 149.2 | 6 |
| 40 | 4549 | 701 | 695 | 149.2 | 6 |

12 stays. Two caveats worth carrying:

- **The delay is doing most of the work.** `develop` alone holds a
  minimum larder of 149 with no cap at all, against 8 for the bare
  baseline. The cap roughly doubles what is left to gain.
- **The response is not monotonic and 12 is a narrow optimum** — 18 is
  markedly worse than either 12 or 25. That is a number calibrated on one
  scenario at one colony size, not a law, and a scenario of very different
  scale should re-check it. Above 25 the cap never binds at all, which is
  the honest upper bound on what this apparatus can say about a queen.

### The double bridge has a working density window

The acceptance row began failing on one seed of three — short-arm share
0.590 against a 0.60 bar — after the colony rules shipped. Four
explanations were tried; three were wrong.

**Wrong: the colony rules weakened selection.** Six seeds across four
configurations, and the short arm won all 24. The shipped rules *raise*
the mean share (0.790 → 0.817) and widen the spread. Growth was not
biasing the result, it was adding variance.

**Wrong: growth floods the arms, so fix the population.** Correct
science — Deneubourg and Goss ran fixed colonies — and it made the
failing seed *worse*, 0.590 → 0.544.

**Wrong: a fixed colony needs to be bigger to supply the traffic the
nonlinearity feeds on.** The opposite:

| start | 1 | 2 | 3 | 4 | 5 | 6 | mean | min |
|---|---|---|---|---|---|---|---|---|
| 150 | 0.544 | 0.973 | 0.975 | 0.724 | 0.974 | 0.676 | 0.811 | 0.544 |
| **300** | 0.839 | 0.833 | 0.822 | 0.606 | 0.864 | 0.714 | 0.780 | **0.606** |
| 600 | 0.763 | 0.624 | 0.750 | 0.748 | 0.673 | 0.745 | 0.717 | 0.624 |
| 900 | 0.717 | **0.463** | 0.791 | 0.748 | 0.603 | 0.818 | 0.690 | lost |
| 1200 | 0.696 | 0.783 | **0.308** | 0.772 | 0.722 | 0.727 | 0.668 | lost |

At 900 and 1200 ants the **long arm wins outright** on some seeds. The
shortest-path result does not merely weaken with crowding, it inverts.

**Right, apparently: the apparatus has a density window.** Too few ants
and the nonlinearity never latches, so individual runs wander — 150 has
the best mean and the worst single seed. Too many and the corridors jam
and congestion decides instead of length. Around 300 the spread is by far
the tightest and nothing is lost.

That is a property of the experiment worth stating in its own right, and
it is not a knob: it says a bridge result quoted without its colony size
is under-specified.

### Trail decay — free in outcome, threefold in appearance

`*trail-decay-scale*` divides the literature tau, so a *lower* number is a
*slower* decay. Five seeds, two scenarios.

| decay | foraging: mins to strip | foraging: peak trail | bridge: eaten |
|---|---|---|---|
| 30 (current) | 26.8 | 129 549 | 2602 |
| 20 | 27.3 | 193 422 | 2475 |
| 15 | 26.7 | 245 086 | 2685 |
| 10 | 26.0 | 302 274 | 2341 |
| 5 | 27.2 | 393 118 | 2826 |

Time to strip the source moves by 1.3 minutes across a **sixfold** change
in decay rate — noise. Food on the bridge is non-monotonic, also noise.
Peak trail mass triples.

So this parameter is nearly free in outcome and dominant in appearance,
which makes it a legitimate aesthetic choice rather than a performance
one — an unusual position for a parameter in this model and worth saying
plainly.

**One cost is not measured here.** Evaporation is the colony's only way
to forget. Time-to-strip says nothing about the aftermath: how long a
road outlives a dead source, or how quickly a colony can abandon one and
re-route. A slower decay lengthens exactly the sequence the README calls
"the road outlives the source", which is visually the best thing in the
simulation and is also, precisely, a loss of adaptability. Anyone
changing this should measure the aftermath, not the harvest.

**The first attempt at this measurement was worthless** and is kept as a
lesson: it used *food eaten* on a scenario with a finite source, so every
setting scored an identical 2500 — the whole source — and the parameter
looked to have no effect at all. A saturated metric does not report "no
difference", it reports nothing.

### The nest crowd, explained — and an A/B that expired

Resting ants were given their own body kind so they leave the ant-ant
collision pass: the nest disc is a *door*, the real thing is a chamber
system going down, and a 2 cm disc cannot hold the hundreds of workers a
mature colony rests in it. Measured against the *unregulated* colony this
cost 10–14% of food delivered, for no reason any measurement could
supply, so it was shipped switchable rather than on — an unexplained cost
that size is as likely to be a bug in the change as a property of it.

Watching the toggle live supplied the mechanism the numbers could not.
A crowded nest **shoves** resting ants, so a departing ant no longer sets
off from the spot it arrived at, and the exit bearing it remembers
(§3.4) stops matching the direction it actually leaves in. It wanders
instead of returning to the source.

That is measurable, and it holds:

| resting ants | eaten | exit error (rad) |
|---|---|---|
| blocking | 2296 | 0.420 |
| passing | **2400** | **0.308** |

4.5% more food, and departures 27% closer to the remembered bearing.

**The earlier 14% was not wrong, it had expired.** It was measured before
brood regulation shipped, when the colony grew unbounded past 600 ants,
and a nest crowd at that population is a different phenomenon from a nest
crowd at a regulated one. An A/B is only valid against the model it was
run on, and this model changed underneath it.

Kept as a live toggle (**N**) regardless, at the user's suggestion:
passing runs smoother, colliding looks better, and the model has no basis
for ranking "delivers more food" against "reads right on screen". A
parameter whose honest answer is *it depends what you are looking at*
should stay visible rather than be buried in a default.

## On the list, not yet measured

- **Lane formation at pinch points.** Two streams meeting head-on at a
  corner block each other; the pile does not resolve because the
  non-overlap rule is symmetric and prefers no side. Because deposition
  counts *attempted* distance, the stalled ants keep marking, which
  recruits more ants into the jam. Probably the mechanism behind §3.8's
  density window — past ~900 ants the long arm wins, so congestion has
  overtaken pheromone as the route-selector. Documented in *L. niger*
  (Dussutour et al. 2004). Two candidate fixes with different costs; see
  §3.11.
- **Trail decay.** Measured and parked: performance flat across a sixfold
  change, appearance triples. An aesthetic choice, which is unusual for a
  parameter here. The unmeasured half is the *aftermath* — how long a road
  outlives a dead source — since evaporation is the colony's only way to
  forget.
- **Encounter-based recruitment** (§3.4) — descoped, and noteworthy.
  The fast channel the model lacks: a laden ant meeting an outbound one
  carries *current* information, where pheromone is an average over the
  last several minutes. Ants antennate and share food on meeting, and the
  content is navigational.

  It shares its expensive half with lane formation: both need the broad
  phase to report **encounters** rather than only overlaps. M3 builds that
  event for the physical half regardless, so whatever rides on it
  afterwards is a rule rather than an infrastructure. Order matters and
  the two are easy to conflate.

## Mistakes worth not repeating

- **Measuring a stale tree.** Two runs were read, or nearly read, from
  code that predated the fix under test. Kill the run when the tree
  changes.
- **Not pinning the parameter under test.** One probe used the new
  default rather than the old behaviour, so it measured the change
  instead of the bug.
- **A metric that flatters.** Food *removed from the source* counts food
  carried by an ant that then died. Total births is the honest integral.
- **A control arm that passes for the wrong reason.** The wall test's
  disabled case started passing because resting ants had stopped
  colliding with terrain and were walking through the obstacle. Assert the
  control, or the test only proves the fix does *something*.
