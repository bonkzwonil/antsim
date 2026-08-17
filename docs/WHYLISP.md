# Why Common Lisp, and why SBCL

Not nostalgia, and not because the author likes parentheses. Four properties of
this language and this implementation are load-bearing for *simulation*
specifically, and each is visible in the code rather than asserted here.

---

## 1. Ad-hoc experiments that are still perfectly controlled

All 65 parameters of the model are `defparameter`s in
[`src/params.lisp`](../src/params.lisp) — special, and catalogued in
[config.md](config.md). So an A/B is not a configuration system, a builder
object, or an options struct threaded through nine call frames. It is a `let`:

```lisp
;; the gallery pins the published experiments to the acceptance protocol
(let ((*brood-investment* 0.0f0)
      (*max-age-ticks* 2000000000)
      (*resting-ants-block* nil))
  (bridge-run! b (* 1200 (floor minutes 2)))
  (bridge-reset-counts! b)
  (bridge-run! b (* 1200 (ceiling minutes 2))))
```

Every frame the body calls into sees it without being handed a thing. Nothing
global is mutated, the rebinding is per thread, and it is gone when the form
ends.

So the arrangement is **ad hoc** — declared at the call site, for exactly this
run, with no ceremony and nothing to register — and at the same time **perfectly
controlled**: side-effect free, thread-safe, and incapable of leaking into the
next run. Two experiments can run concurrently in two threads without touching
each other. Maximum flexibility and total isolation, from one binding form.

Most languages make you choose one or the other. You cannot do this in Python:
there the same manoeuvre is either mutating a module global and restoring it in a
`finally` — shared by every thread, so concurrent runs corrupt each other — or
plumbing the parameter through every call site by hand. `contextvars` buys back
the isolation, but only for variables declared as such up front, with `set` and
`reset` tokens to carry around. Here it is `let`, and it works on any special.

And it composes with the live image, which is where it stops being a tidiness
argument. At a SLIME REPL you can take a colony that is *already running* —
grown, with its trail laid, at whatever tick it has reached — and put it into
different physics for the next call, by wrapping that call in a different `let`:

```lisp
(defparameter *w* (gallery-world))
(world-run! *w* 24000)                                   ; grow one, 20 min

(let ((*resting-ants-block* t))    (world-run! *w* 1200)) ; same colony,
(let ((*trail-decay-scale* 3.0f0)) (world-run! *w* 1200)) ; different world
```

The colony is the same object at the same tick; only the conditions around the
next call changed, and they change back. The experimental condition is a property
of the **call**, not of the world or of how it was constructed — so a question
you think of twenty simulated minutes in does not cost you the twenty minutes.

Receipt: the same gallery run renders its foraging pictures with
`*resting-ants-block*` bound **on** and the two bridge frames with it bound
**off**, and when the gallery was regenerated those two bridge frames came back
byte-for-byte identical to the previous run. The isolation held, and the file
system proved it.

The whole of [experiments.md](experiments.md) is measurements made this way. When
a mechanism turns out not to pay it ships switched off with its number recorded
rather than deleted — which is cheap only because "off" is a default binding
rather than a code path.

## 2. The REPL is the instrument, not a convenience

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

## 3. It compiles to bare metal

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

## 4. Determinism is a design decision the language does not fight

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
