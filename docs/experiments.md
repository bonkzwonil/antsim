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

### The trough: why colonies starved with food coming in

Reported from the window, and the code agrees exactly. Every resting ant
drew `*nest-feed-rate*` = 0.002 energy per tick from a common store, so
one forager's load — about a unit — was spread over five hundred
ant-ticks. With several hundred ants in the nest that is roughly *one
tick each*: everybody gets a hair, nobody gets a meal. Meanwhile an empty
larder has pushed the departure bar down to about 0.11, so an ant holding
almost nothing still qualifies to leave — walks out, and exhausts.

Watched, that is not an equilibrium but a **ratchet**. Each delivery
lifts the whole nest over the bar at the same instant, the whole nest
departs, and a fraction of it does not come back. The reproducer is seed
397767704 after T8000: the nest wakes up for a split second and goes red
again. The endpoint on the word scenario is **extinction at T10000 with
both sources untouched and full**, and a ring of corpses centred on the
nest door.

The food was never the constraint. The distribution rule was.

The fix is trophallaxis's recipient half, which can be had without the
pairwise coupling §3.9 defers:

- **fully restored** — a unit of stock buys one forager that finishes a
  trip, or five hundred that get halfway; only the first is worth
  anything and the second is what makes corpses;
- **hungriest first** — which forced feeding out of the ant loop into its
  own pass, because that loop walks the table in index order and cannot
  know who is hungriest until it has seen everyone, so feeding inside it
  can only ever be first-come, and the order is the *array's layout*;
- **bounded per tick** — a nest serves a few ants at a time, not all of
  them at once.

One trap on the way: requiring the larder to cover an ant's whole deficit
before serving it inverts the queue. An ant at 0.99 wants 0.01 and is
always affordable; a starving one wants 0.9 and never is. The nearly-full
skim the stock and the ants that need it are served last. A served ant
takes its deficit *or whatever is there*, whichever is less.

### The meal fix, measured in the regime it exists for

**First attempt measured nothing, because it measured the wrong regime.**
Four configurations on a colony that started small and grew healthily came
back identical — 1057 ants thriving even with fully-old behaviour. A
colony whose income comfortably covers its metabolism does not care how
the nest shares food, so the rule could not matter and dutifully did not.

The reproducer, supplied from the window, is the same arena **overloaded**:
1400 ants on 40 units of stock, so metabolism exceeds income from the
first tick and the only question left is how the nest shares what little
arrives. It ships as `scenarios/antsim-overload.json` with its seed.

Trajectory to T7200, `*forager-eats-at-source*` on:

| | trough (meals 0) | meals 2 |
|---|---|---|
| T1200 | 944, stock 64.7 | 1026, stock 102.7 |
| T2400 | 699, stock **0.0** | 856, stock 233.6 |
| T3600 | 647, stock **0.0** | 955, stock 242.9 |
| T4800 | 644, stock **0.0** | 1072, stock 190.9 |
| T6000 | 644, stock **0.0** | 1144, stock 102.2 |
| T7200 | 644, stock **0.0** | 1146, stock 50.4 |
| able at worst | **83** | **807** |
| died | 929 | 1227 |

The trough loses 929 ants — over half — and then **locks**: population flat
at 644, stock pinned at zero from T2400 onward, 83 ants able to work. It
does not die, and it never recovers either. Meals dip to 851 and climb
back to 1146, holding a real larder throughout.

Ten times as many able foragers at the worst point is the number that
matters, because it is the one the colony's future depends on.

Eating at the source is separable and also real. Without it the trough
does not even stabilise — 1063 → 840 → 513 → 443 → 420 → 378, stock zero
throughout, 27 able at worst. The two do different jobs: meals decide how
many ants can leave at all, eating at the source decides whether one that
leaves survives the trip.

**The correction this forced.** An earlier entry here concluded the meal
rule was "modelling, not a fix" — that the collapse it addressed was a
pre-queen phenomenon already cured. That was wrong, and wrong for a
reason worth keeping: the failure had not been cured, it had merely been
made *harder to reach*. Brood regulation stops a colony growing into the
overloaded state on its own; it does nothing for a colony that starts
there. Absence of a failure under one starting condition is not absence
of the failure.

### Symmetry breaking, off its own test rig

The word scenario also shows the binary bridge's phenomenon — traffic
committing to one of two near-equal routes, and occasionally flipping —
in a geometry where nobody arranged for it. The routes through the
lettering are equal by accident, not by construction.

That is worth more than it looks. A purpose-built apparatus always
carries the worry that it *manufactures* the effect it demonstrates:
Deneubourg's bridge is two deliberately equal arms with everything else
controlled, so a sceptic can ask whether symmetry breaking is a property
of colonies or of bridges. The same dynamic arriving unbidden in a
scenario built as a joke is the answer an acceptance row cannot give.

Also a reminder that the acceptance rows test the *claim*, not the
mechanism's reach. Nothing in §3.8 would have caught it if trail
commitment only worked inside the apparatus.

### Pockets kill ants, and the word scenario is the reproducer

`scenarios/antsim.json` spells the project's name in obstacles, and the
concave letters turned out to be a better diagnostic than anything built
on purpose: **ants pile up and die inside the pockets** — the notch in
the N, the inside of the S.

The mechanism is §3.4's stated limitation, made visible, plus a step that
was not recorded:

1. The home vector points *through* the letter, so a laden ant walks into
   the pocket.
2. The antennal veto lets it slide along the inside wall, but leaving a
   concavity means walking **away** from the nest, which no bearing can
   express however wide the scan.
3. It dies there.

**A fourth step was claimed here and was wrong.** The write-up said the
corpses narrow the pocket and trap the next ant — a positive feedback.
They do not: a corpse is a *movable* body, ants shove it, and watching a
long run shows the corpse piles ending up well clear of the pockets
rather than filling them. The mistake was reading a grey mass in a
picture as evidence of a mechanism instead of checking
`body-kind-movable-p`, which answers it in one line.

What actually holds the ants there is the pair the window shows: the
bearing is followed too eagerly, and once an ant is against a wall it
adheres to it. Both are things this model added on purpose — the home
vector is total for a laden ant, and the antennal scan makes it follow an
edge rather than press into it — so the trap is built out of two fixes,
each of which is right on its own.

**The model already names the missing behaviour.** §3.2 lists *search
spirals* — an ant homing on a vector that is not getting it there
switches to an expanding systematic search — as real, documented, and
deferred. That is exactly the escape a pocket needs: not a better
bearing, but a rule for noticing the bearing has stopped working. The
same counter would bound the other half, since an ant that has been
following an edge for a long time without its bearing coming clear is an
ant whose edge-following has become the problem rather than the fix.

Both halves want the same piece of state: *how long have I been failing
to make progress toward home*. That is one number per ant, and it is the
cheapest thing on this list.

**The other candidate fix has an expired measurement against it.** Letting the
trail override the straight-line bearing was measured at −29% (262 units
delivered against 367) and the negative was kept in the source. That run
predates both the antennal veto and brood regulation — a model in which
ants died on walls constantly and the colony grew to zero reserve. The
nest A/B reversed sign for exactly this reason once the model changed
underneath it, so this one is owed a re-run before it is treated as
settled.

Worth stating as a rule, since it has now bitten twice: **a negative
result has a shelf life.** It is a fact about the model it was measured
on, and this model has changed twice since.

### Individual walking speed (§3.1) — shipped

Every ant in the colony walked at exactly `*walk-speed*`. §3.1 quotes a
*range* — 1–3 cm/s — and the model had been taking its midpoint and
handing the same number to every worker, which is the one claim in the
movement model that nothing in the literature supports. `*speed-spread*`
gives each ant a lifelong multiplier drawn uniformly from 1 ± 0.10, from
its id and the world seed only, on its own stream (`ANT-PACE`, the same
construction as `ANT-HANDEDNESS`).

The question that had to be answered before it could ship is whether it
moves the two published rows. Both bridges, **sixteen seeds each**, the
acceptance protocol (fixed colony, six minutes to commit, six minutes
measured), and the only difference between the columns is the parameter:

| row | spread | mean busiest arm | worst replicate | winners |
|---|---|---|---|---|
| binary | 0.00 | 0.947 | 0.623 | 9 / 7 |
| binary | **0.10** | 0.944 | 0.668 | 9 / 7 |
| double | 0.00 | 0.798 | 0.706 | 16 / 16 short |
| double | **0.10** | **0.814** | 0.672 | 16 / 16 short |

Nothing moved that the rows are about. The binary bridge commits just as
hard and still splits its choice 9/7 across seeds; the double bridge's
short arm still wins **every** replicate, and its mean share went *up* by
1.6 points, which is inside the spread of the distribution and is
reported as "not worse" rather than as an improvement.

Individual seeds do reshuffle, and they have to: this changes every
trajectory. That is the reason the comparison is sixteen seeds per cell
and stated as an aggregate — a per-seed diff between the columns would
have looked alarming and meant nothing.

Two things recorded rather than fixed:

- **A brisk ant is very slightly the fitter forager.** Energy drains per
  tick, not per metre (§3.5), so 10% more speed is 10% more range for the
  same fuel. At this width it is inside the noise of a foraging trip.
  Removing it means making metabolism speed-dependent, which is a real
  mechanism and a separate one.
- **The spread is a tenth, not the quoted range.** 1 to 3 cm/s is a
  factor of three, and a factor of three between individuals would be two
  castes rather than variation; the published range is across studies,
  colonies and temperatures at least as much as across workers of one
  nest.

`*speed-spread*` has an exact off position — at 0 the multiplier is
`1.0f0` and the previous model is restored bit for bit, which is what
made the table above a controlled comparison and is asserted by a test.

**Noticed while measuring, and not caused by this change:** the per-seed
tables in the README no longer reproduce. They were written at `d6b0035`
and there have been roughly a dozen model commits since — antennal wall
sensing, the colony demography, the queen calibration, the bridge width
fix, the meal fix — any of which moves individual trajectories. The
*claims* those tables support all still hold, and the acceptance rows
assert them over seeds rather than per seed, which is why nothing caught
it. They are owed a regeneration under a stated protocol, which is a job
of its own and is on the list below.

### Scaling the arena — what does and does not scale with it

`scenarios/antsim-large.json` is `antsim.json` five times over in every
length: a 5.00 × 3.60 m arena, letters 17.5 cm to a pixel, the nest 3.125 m
from the nearest source instead of 0.625 m.

**The naive version does not work, and the way it fails is the finding.**
Scaling only the geometry — same ant, same everything else, population
raised to 2000 to suit the longer trail — gives a colony that never gets
going:

| arena | nest→food | pop @30 min | stock | trail | eaten | died |
|---|---|---|---|---|---|---|
| 1.00 × 0.72 m | 0.625 m | 502 ↑ | 1412 | 182 k | 2720 | 162 |
| 5.00 × 3.60 m | 3.125 m | **26** | **0** | 240 | **8** | **2173** |

Eight units of food in half an hour against 2720, stock gone by minute
20, and 2000 workers down to 26. The source is not *hard* to reach at
3 m, it is out of range.

The binding constraint is the forager's tank, and it is a constraint on
the **outbound** leg only — an ant refills to full standing on the source
(§3.5), so getting home is never the problem. `*energy-drain-walking*`
is `[cal]`, set so an ant empties after about seven minutes of walking,
which is roughly 8 m of path; a forager sets out at full and turns back
at its give-up threshold, so it has about 4.5 m of *path* to find
something with. A straight 3.125 m fits inside that and a correlated
random walk over the same ground does not.

Range against the same arena, 40 minutes, everything else held:

| `*energy-drain-walking*` | range | pop | stock | trail | eaten | died |
|---|---|---|---|---|---|---|
| 1.2e-4 (default) | 1× | 26 | 0 | 240 | 8 | 2173 |
| 4.8e-5 | 2.5× | 1962 | 692 ↓ | 423 k | 870 | 422 |
| **2.4e-5** | **5×** | **2300 ↑** | **2938** | **640 k** | **1308** | **84** |

**Five times the distance wants five times the range**, and the middle
row is what a half-measure looks like: a trail does form and food does
come in, but the larder falls all the way through and the deaths are
five times the working case. It is a colony on its way down, not a
working one.

So the large scenario states the range in its own file, and that is what
the new `ant` block in §6 exists for. Which way the honesty runs is worth
being explicit about: a real *Lasius* forager ranges much further than
eight metres and trunk trails run to tens of them, so the large arena's
value is the *more* defensible one and the shipped default is the
compromise. The default does not move — nothing outside this one file
sees it.

Scaled by exactly `1/5`, so a journey costs the same fraction of a tank
in both files and they stay the same experiment at two sizes. A test
asserts that ratio against the geometry ratio, because the failure it
guards is silent: get it wrong and the two scenarios still both run,
they just stop being comparable.

**Population answers to the area, and the first version of this entry got
that wrong.** It argued population from trail length — a road five times
longer needs five times the traffic to hold it against an evaporation
clock — and shipped 2000. That reasoning is right about *maintaining* a
trail and silent about the two things that scale with the box instead:
**finding** the food, which an ant does by covering ground, and how
inhabited the arena looks, which is ants per square metre. Five times the
length is twenty-five times the area.

Measured on the same arena, 30 minutes, only the colony changed:

| population | trail found | trail @30 min | eaten @30 min | died |
|---|---|---|---|---|
| 2000 (×5, by length) | 8 min | 438 k | 734 | 0 |
| 5000 (×12) | ~7 min | **1 170 k** | **1765** | 0 |
| 10000 (×25, by area) | ~4 min | 1 332 k | **2950** | 0 |

More ants is better on every axis and costs nothing in deaths. What rules
out the full ×25 is **not biology but the tick budget**, and the cost is
superlinear because crowding is quadratic in local density:

| population | headless tick rate, before any drawing |
|---|---|
| 2000 | 6.3× real time |
| 5000 | 1.5× |
| 10000 | **0.44×** |

Five times the ants is fourteen times the work. At 10000 the simulation
is slower than real time before a single frame is drawn, and `make live`
opens at 4× compression — so the scenario that exists to be *watched*
would be the one you cannot watch.

**5000 ships**: two and a half times the density of the first attempt,
still comfortably faster than real time, and one number in the script for
anyone who would rather have the crowd than the frame rate. The honest
summary is that this is a performance ceiling wearing a modelling
argument, and it is written down that way so nobody later mistakes it for
a claim about ants.

One thing that is *not* a correction: **the doorways get easier, not
harder.** A gap between letters is 17.5 cm instead of 3.5 cm — seventy
ants abreast instead of fourteen — so the lettering stops being a
bottleneck. The small file is the one where the word shapes the traffic;
the large one is where the *distance* does. They are worth having both.

### Route memory (§3.4, M4) — shipped, and it closes the pockets

The entry above — *pockets kill ants* — ends by naming what is missing:
not a better bearing, but something other than a bearing.  Route memory
is that, and it is the first mechanism since M2.1 that both pays and
survives §3.8.

An ant records its own outward track as up to twelve points 2 cm apart,
and falls back to it **only when the bearing home is blocked**.  The path
is walkable by construction: it contains no wall, because the ant did not
walk through one.

    arena                     route off   route on
    live-demo, one wall            548        548     harvested
    word scenario                  888       1264     harvested
    word scenario                  140        119     corpses
    binary bridge                0.914      0.918     mean share
    binary bridge, worst seed    0.892      0.900

**The two foraging numbers are the result together.**  One small wall is
rarely between an ant and its nest, so a fix aimed at concavities should
do nothing there, and it does nothing to the unit.  The word scenario is
concavities the whole way and it is worth 42%.  A mechanism that helped
on both would be doing something other than what it claims.

**It failed first, in the obvious way, and the suite caught it in one
run.**  The natural implementation has the ant follow the remembered
track the whole way home — which is retracing its own meander: 470 ticks
to cover 10 cm, and the homing acceptance row said so immediately.  It is
also the wrong animal.  *Cataglyphis* runs the vector straight home and
does not retrace; a route is what you fall back on when the vector cannot
be walked.

Note that this also settles the expired measurement flagged in the
pockets entry.  Letting the *trail* override the bearing was −29% and was
owed a re-run; it is superseded rather than re-run, because the ant's own
track is a better answer than the colony's field to the question "which
way from here is walkable" — the track is this ant's, this trip, and
contains no wall by construction, where the field is an average over
everyone who ever came past.

### Three mechanisms that had nothing to do (M4)

Response thresholds, the no-entry field and search spirals were all
built, tested, and change nothing at shipped parameters.  Three different
measured reasons, and the pattern is the finding:

| mechanism | why it is inert |
|---|---|
| Response thresholds | The stimulus is bimodal.  Measured across a colony's life it reads **0.000** while the larder holds and **1.000** within minutes of its failing, with the intermediate values appearing only as a transient on the way down.  A threshold needs a graded middle to slice and there is none.  Three threshold spreads returned byte-identical numbers, which is what a parameter that never fires looks like. |
| No-entry field | The marks never agree.  Marking where an ant *gave up* scatters them over the arena — the field peaked at **0.01** against a cap of 20.  Marking an exhausted source concentrates them (0.65) but fires only for the cohort standing on it when it ran dry, because an ant arriving later never enters AT-FOOD at all. |
| Search spirals | The failure does not occur.  Raise `*pi-noise*` from 0.02 to 0.5 and the mechanism plainly works — one seed's homing goes from 5765 ticks to 304 — but at the shipped noise a home vector does not run out short of the nest, and a colony run harvests **529 against 529**, to the unit. |

None of this is an argument against any of the three; each fires and works
when its precondition is met.  They are failure-recovery mechanisms, and
this model's ants do not currently fail in the ways they recover from.
Two of them want the same missing piece — a remembered food *location*,
where an ant here keeps only a bearing.

**The general lesson is about how to evaluate a mechanism at all.**  A
measurement of "does it help" is only meaningful once the situation it
helps in is something the model produces.  Otherwise the honest reading
of a null result is *the experiment did not run*, not *the mechanism is
worthless* — and the two are easy to confuse when both print 529.

### A source that could be eaten from for ever (M4)

Found by new apparatus rather than by reasoning: the Beckers rig reported
850 feeding visits to a pile that had lost nothing at all.

Food amount is the one accumulator in the model whose magnitude and whose
increment are six orders apart.  A forager takes 0.02 units of a 500 000-
unit pile in a tick; at 500 000 a single-precision ulp is 0.031, so the
take is under half an ulp and `(decf amount take)` rounds straight back
to where it started.

It was not confined to the unlimited sources.  Wherever the take lands
near half an ulp the *rate* is wrong rather than absent — at 500 000 with
quality 1.0 a take of 0.02 rounds up to 0.031 and the pile empties 56%
too fast.  Below roughly 30 000 units the error stops mattering, which is
exactly why every shipped scenario looked right.

Amount and initial are `double-float` now — the only doubles in the model
— and two tests guard it on the struct, so a regression names the cause
instead of a food total being quietly off.

### ε does not blur a trail; it merges two (M4, §3.12)

§3.12 predicted that raising ε would "visibly degrade both colonies'
trail fidelity".  Testing it needed the claim restated twice.

The first apparatus put two nests either side of one contested pile.
Fidelity was flat in ε from 0.0 to 1.0 — and the reason was geometry, not
model: each colony's field lay almost entirely where the other's did not,
so there was nothing for ε to confuse.  **An apparatus in which the
mechanism cannot act is not evidence about the mechanism**, which is the
same mistake the bridge file records for two gaps 40 cm apart.

On crossing routes — nests at opposite corners, each colony's source at
the corner diagonally across, so the fields overlap along their whole
length at an angle, and *neither colony competes for anything* — the
result inverts the expected sign:

    eps   concentration   route fidelity   harvest sw   harvest se
   0.00        0.4955          0.3570           3012         3017
   0.10        0.5019          0.3846           3032         2948
   0.30        0.4658          0.3954           3044         2995
   0.60        0.5269          0.3563           2902         2848
   1.00        0.6014          0.3266           2828         2764

Concentration — how *thin* each colony's field is — goes **up**.  That is
not a defect: two colonies reading each other's marks converge on one
shared road network, and one shared network is thinner than two separate
ones.  It also leads half of each colony toward the other's food, which
is why harvest falls at the same time.

So fidelity for this row has to mean *correctness* and not thinness: the
share of a colony's mark lying on the way to its own source.  And a
little eavesdropping helps — route fidelity peaks at ε = 0.3 — which is
an argument for the shipped ε being small rather than zero.

### Corpses are bulldozed, so necrophoresis needs a moving control (M4)

The pockets entry above corrects an earlier claim that corpses trap ants,
on the grounds that a corpse is a movable body and ants shove it.
Measuring necrophoresis put a number on how much shoving that is, and it
is enough to matter to the experiment:

    necrophoresis   clump before -> after   within 6 cm of nest
        off             5.83  ->   6.18          24  ->  12
        off             5.28  ->   5.67          20  ->  10
        on              5.83  ->  11.43          24  ->   0
        on              5.28  ->  10.96          20  ->   1

**Half the corpses leave the nest area with the behaviour switched off.**
A run against "nothing happens" would have credited traffic's work to the
undertakers.  Against the moving control, clumping roughly doubles where
the traffic alone barely moves it, and the nest goes to nothing rather
than to half.

## On the list, not yet measured

- **The README's per-seed bridge tables.** Stale since `d6b0035` (see
  above). The fix is not to re-run them but to decide first *which*
  protocol they are published under and to generate them from it, the way
  the gallery images are generated, so they cannot drift again.


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
- **Search spirals** (§3.2, §3.9) — deferred since M1 as a refinement,
  and the word scenario shows it is not one. An ant whose bearing has
  stopped making progress has no rule for noticing, so it follows the
  bearing and the wall into a concavity and stays. One counter per ant —
  ticks without progress toward home — serves both the spiral and a bound
  on edge-following.

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
- **A measurement budgeted on a broken model.** The feeding sweep was
  sized from runs where the colony collapsed to a couple of hundred ants.
  With the fix in, colonies survive and grow toward the scenario's
  capacity, so every tick costs an order of magnitude more and an
  eight-configuration sweep that should have taken minutes had not
  finished one configuration in 38 CPU-minutes. A fix that works changes
  what its own measurement costs. Budget on the *fixed* model, not the
  broken one — and treat a run that is mysteriously slow as evidence
  about the change rather than about the machine.
- **A/B against a baseline that already contains the other change.**
  Two energy fixes shipped together — meals in the nest, and foragers
  eating at the source — and then only *meals* was swept. Eating at the
  source was on by default in both arms, so the "control" was not the old
  model at all, and both arms came back thriving with nothing to
  distinguish. Same family as the stale-tree and expired-negative
  mistakes: the baseline was not what it was assumed to be. The new cause
  is specific and easy to repeat — a default was changed, and then
  forgotten to be part of the comparison. Sweep every switch that moved,
  or sweep the cross.
- **Concluding "no effect" from the wrong regime.** The feeding rule
  measured as nothing four times, on colonies whose income comfortably
  covered their metabolism — where it *cannot* matter. In the regime it
  exists for it is the difference between 83 able foragers and 807. Ask
  what conditions make the mechanism binding, and measure there; a null
  from a healthy system says nothing about a sick one.
- **A control arm that passes for the wrong reason.** The wall test's
  disabled case started passing because resting ants had stopped
  colliding with terrain and were walking through the obstacle. Assert the
  control, or the test only proves the fix does *something*.
