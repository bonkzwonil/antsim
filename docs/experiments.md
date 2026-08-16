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

### Colony factor screen — running

Six factors, each alone against the baseline, then all together.

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
