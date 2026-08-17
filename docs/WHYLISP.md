# Why Common Lisp, and why SBCL

Not nostalgia, and not because the author likes parentheses.

Five properties of this language and this implementation are load-bearing for
*simulation* specifically. Each one is visible in the code rather than asserted
here, and each is linked to the file it lives in.

---

## 1. An experiment needs an off switch, and dynamic binding is one

Every parameter in the model — all 65 of them, catalogued in
[config.md](config.md) — is a special variable in
[`src/params.lisp`](../src/params.lisp). So an A/B is not a configuration
system, a builder object, or an options struct threaded through nine call
frames. It is a `let`:

```lisp
;; the gallery pins the published experiments to the acceptance protocol
(let ((*brood-investment* 0.0f0)
      (*max-age-ticks* 2000000000)
      (*resting-ants-block* nil))
  (bridge-run! b (* 1200 (floor minutes 2)))
  (bridge-reset-counts! b)
  (bridge-run! b (* 1200 (ceiling minutes 2))))
```

The binding has **dynamic extent**, so the change ends exactly where the form
does. There is no teardown to forget and no global left mutated for whoever
calls next.

That is not a stylistic preference, and there is a receipt for it. The same
gallery run renders its foraging pictures with `*resting-ants-block*` bound
**on** and the two bridge frames with it bound **off** — and when the gallery
was regenerated, those two bridge frames came back byte-for-byte identical to
the previous run. The isolation held, and the file system proved it.

The whole of [experiments.md](experiments.md) is measurements made this way.
When a mechanism turns out not to pay, it ships switched off with its number
recorded rather than being deleted — which is only cheap because "switched off"
is a default binding rather than a code path.

## 2. Two scopes, and the language tells them apart

Everything is **lexically scoped by default**. Closures close over exactly what
the text says they close over, which is why the RNG can be a pure function, and
why redefining a rule does not mean auditing what else was watching a variable.

**Dynamic scope is the deliberate exception** — requested by declaration, and
marked in the name by the `*earmuffs*` convention. So the 65 parameters above
are visibly the ones with run-wide extent, and everything else is visibly not.

Most languages give you one of these. Having both, distinguishable at a glance,
is precisely what makes the `let`-as-experiment pattern of §1 safe instead of a
global-mutation trap. The convention is doing real work: `*resting-ants-block*`
announces that it is rebindable and run-scoped, and a lexical `b` announces that
it is not.

## 3. The REPL is the instrument, not a convenience

A colony worth looking at costs twenty simulated minutes to grow. In a
compile-run-exit language, every question you think of *after* it has grown
costs you the colony.

`make repl` leaves the world in a variable. Inspect an individual ant,
recompile the rule that decides whether it turns, and call it again on the
**same** world, at the same tick, with the trail it has already laid.

Several of the findings in [DIARY.md](DIARY.md) came out of that and could not
easily have come out of a log: the nest quietly filling with ants that were not
leaving, the departure bearing that pointed backwards, the food source that
stayed fat while the colony starved beside it. Every aggregate being printed at
the time looked plausible.

### And over SLIME, it stops being a prompt

With SLIME and Swank the REPL becomes an environment rather than a terminal.
The editor talks to the running image:

- compile a single function with a keystroke, and it is live in the world
  already in memory;
- jump to the definition of anything, including into the implementation;
- inspect a structure by clicking through it, field by field;
- and when something signals, you get the condition with a **live stack** and a
  set of **restarts** to choose from — not a process that has already exited
  and a trace of where it used to be.

It is a genuinely *playful* way to work. That is not a frivolous property for a
project whose entire method is watching a thing run and asking it questions —
[the renderer exists](DIARY.md#what-the-window-found) on exactly that argument.

## 4. It compiles to bare metal

SBCL emits **native machine code ahead of time**. No bytecode VM, no
interpreter, no JIT waiting to notice that a loop is hot. There is no warm-up,
so the first tick of a run costs what the millionth does — which is what makes
a deterministic benchmark of a simulation meaningful in the first place.

With types declared, the numeric core is genuinely fast: **competitive with C**
on this kind of work and sometimes ahead of it, because the compiler sees the
whole program and inlines across boundaries a C translation unit would hide.

The model is structure-of-arrays over unboxed vectors — `f32v`, `u32v`, `fixv`,
defined in [`src/util.lisp`](../src/util.lisp) — and the inner loops in
[`bodies.lisp`](../src/world/bodies.lisp) and
[`geom.lisp`](../src/world/geom.lisp) carry `(optimize (speed 3) (safety 0))`
with the array types declared. The collision pass over a few thousand discs is
therefore arithmetic on float vectors, not a walk over a graph of objects. Ask
SBCL to disassemble any of them and you get the instructions.

The part that matters most for a project like this: **you choose per function.**
The exploratory code and the tight loop live in the same file, in the same
language, with no foreign-function boundary and no second build system between
them. Nothing has to be rewritten in another language once it turns out to be
hot — you add a declaration to the function you already have.

## 5. Determinism is a design decision the language does not fight

`*random-state*` is banned from simulation code. A stateful generator makes a
threaded run irreproducible the instant two threads draw from it, and this model
is a claim about *distributions over seeds* — "the colony commits to one branch"
is only meaningful across many independent repetitions.

The replacement is ordinary code in [`src/rng.lisp`](../src/rng.lisp): a pure
function of `(id, tick, stream, seed)`. Nothing to advance, no sequence
position, no lock in the hot loop. An ant's draws are the same whichever worker
thread stepped it. Any tick can be recomputed without replaying the ticks before
it, which is what makes a failing acceptance run debuggable at all.

The test suite pins its exact output, so a well-meaning improvement to the
mixing cannot silently invalidate a stored run.

---

## The honest counterweight

The GL binding is a foreign-function layer, the ecosystem for it is thin, and
[§5.4 of the design document](concept.md#54-headless-and-the-libgl-trap) exists
because getting a headless context up on the right `libGL` took real work. A
render coming back black has more possible causes here than it would in a
mainstream games stack.

None of that is Lisp being unsuitable — it is a small ecosystem, and the cost is
paid once, at the boundary. The numeric core, which is where the science lives,
has **no foreign dependency at all**: `make test` runs 43 022 checks with no GPU
and no graphics stack, and the renderer suite runs in software on llvmpipe for
CI.

---

*Part of [antsim](https://github.com/bonkzwonil/antsim). The design document is
[concept.md](concept.md); the measurement log is [experiments.md](experiments.md).*
