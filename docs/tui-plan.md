# A TUI mode — plan

Working document for `feat/ascii`.  It is a plan, not documentation: when
the feature lands, its reasoning folds into `docs/concept.md` §5.6 and this
file goes away.

## 1. What this is for

A second way to watch a colony, for a machine that cannot open a GL window
— a server over SSH, a container, a box with no graphics stack at all.  The
world is drawn as characters in a terminal, with a status line across the
top and arrow keys to pan.

It is explicitly **not** an attempt to reproduce the window in text.  There
is no inspector panel, no vector ant, no pheromone gradient in 24-bit
colour.  A terminal cell is a very large pixel and the honest thing to do
with one is to show *where the ants are and which way they are pointing*.

## 2. The doctrine question, answered up front

§5.5 ends with the rule this feature has to answer to:

> The live window is a second consumer of the frame, never a fork of it —
> which is what keeps the tested path and the watched path the same path.

A TUI *is* a second renderer, so the rule as written would forbid it.  The
resolution is that the rule is about the **frame**, and the TUI is not a
consumer of the frame at all — it is a second consumer of the **world**.
It shares the thing that actually matters (one simulation, one tick, one
set of tables) and shares none of the pipeline, because there is no
pipeline to share: no context, no shader, no vertex buffer, no pixel.

The invariant that replaces it, and that §9 should record:

> The terminal view and the window view are two readings of one world, never
> two worlds.  Neither may hold simulation state the other cannot see, and
> neither may step the world in a way the other does not.

Concretely: `antsim/tui` calls `world-step!` and reads the exported
accessors, exactly as the window does.  It adds no slot to any struct and
no dynamic variable the simulation consults.

## 3. Where it sits

A new **leaf** system, and the dependency direction is the whole point:

```
antsim            (no dependencies)
  ├── antsim/scenario   (+ jzon)
  │     └── antsim/tui        ← new.  Nothing else depends on it.
  └── antsim/render (+ cffi, cl-opengl)
        └── antsim/live (+ cl-glfw3)
              └── antsim/app
```

```lisp
(defsystem "antsim/tui"
  :description "The terminal view (§5.6): ANSI escapes, no GL, no curses."
  :depends-on ("antsim" "antsim/scenario")
  :serial t
  :pathname "src/tui"
  :components ((:file "camera")
               (:file "canvas")
               (:file "draw")
               (:file "status")
               (:file "term")
               (:file "live")))
```

**No external dependency, and that is a decision rather than an accident.**
A curses binding (`cl-charms`, `croatoan`) would drag in `libncurses`,
which the AppImage does not bundle and the shipping doc's bundling
rationale does not cover.  Everything needed is already in SBCL:

| need | how | verified |
|---|---|---|
| raw mode | `sb-posix:tcgetattr` / `tcsetattr`, `termios-lflag`/`-iflag`/`-cc` | ✅ all present, with `icanon` `echo` `isig` `iexten` `ixon` `vmin` `vtime` `tcsanow` |
| terminal size | `TIOCGWINSZ` (`#x5413`) via `sb-posix:ioctl` + an `sb-alien` `winsize` struct | ✅ syscall reached; `sb-unix` has no `winsize`, and `$COLUMNS` is **not** exported to the process, so the ioctl is the only real answer |
| resize events | `SIGWINCH` = 28, `sb-sys:enable-interrupt` | ✅ |
| non-blocking input | `vmin`=0 `vtime`=0 + `read-char-no-hang` | ✅ measured: 5 polls in 0 ms |
| drawing | ANSI escapes written to `*standard-output*` | ✅ UTF-8 external format |

These were probed on this machine under a real pty, not assumed.

## 4. Shape of the code

The split is chosen so that **everything except one file is a pure
function**, which is what lets the tests run in the everywhere-runnable
suite with no terminal, no GPU and no dependencies.

| file | what | pure? |
|---|---|---|
| `src/tui/camera.lisp` | the cell-unit camera | ✅ |
| `src/tui/canvas.lisp` | a character grid + colour plane, and the diff between two of them | ✅ |
| `src/tui/draw.lisp` | world → canvas | ✅ |
| `src/tui/status.lisp` | the status line, as a string | ✅ |
| `src/tui/term.lisp` | termios, winsize, SIGWINCH, ANSI writing, key decoding | ❌ the only file that touches the OS |
| `src/tui/live.lisp` | the loop | ❌ |

The seam that matters:

```lisp
(tui-frame w &key cols rows camera charset colour)  ; → a canvas, no I/O
```

A REPL can call that and print it.  A test can call it and assert on
individual cells.  `term.lisp` never has to be loaded to do either.

### 4.1 The camera

Its own, ~40 lines, **not** `src/render/view.lisp`.  Reusing the GL camera
would mean splitting a new `antsim/view` system out of `antsim/render` and
rewiring the render system to depend on it — an invasive change to working
GL code to buy arithmetic that is cheaper to rewrite.  The TUI's needs are
different anyway: it pans in whole cells and zooms in coarse steps, and it
has no cursor to anchor a zoom to.

```lisp
(defstruct (tui-camera (:conc-name tcam-))
  (cx 0.5f0 :type f32)     ; centre, world metres
  (cy 0.5f0 :type f32)
  (mpc 0.005f0 :type f32)) ; metres per cell *column*
```

**Cell aspect is the one piece of arithmetic that must not be fudged.** A
terminal cell is roughly twice as tall as it is wide, so a row spans
`2*mpc` metres while a column spans `mpc`.  Getting this wrong makes a
circular nest render as an ellipse and is the single most obvious way for
the picture to look wrong.  The ratio lives in one place:

```lisp
(defparameter *tui-cell-aspect* 2.0f0
  "Cell height ÷ cell width, as the terminal actually draws it.  Two is
right for nearly every terminal and font ...")
```

`tui-fit` picks `mpc` so the whole world fits *both* dimensions.  A column
spans `mpc` metres and a row spans `mpc * aspect`, so the two constraints
are `cols*mpc ≥ width` and `rows*mpc*aspect ≥ height`, and the fit is the
looser of them:

```lisp
(max (/ width cols)
     (/ height (* rows *tui-cell-aspect*)))
```

Panning is clamped, unlike the GL camera (which deliberately is not): in a
window you can see you have flown off the arena and drag back, but a
terminal full of blank cells with no scroll bar is just a broken program.
Clamp the centre so at least a quarter of the arena stays on screen.

### 4.2 Drawing a frame

One pass over the **body table**, which already holds ants, corpses, food
discs and nest entrances in one place — the same loop `upload-ants` uses.
Then the ant table only for heading and state.

Painter precedence, highest wins, because several things land in one cell
at any useful zoom:

```
terrain < pheromone shading < food < nest < corpse < ant
```

- **terrain** — `field-blocked-p` on the colony's trail field.  It is the
  pre-rasterised mask of every obstacle, so there is no polygon scan and no
  `point-in-polygon-p` per cell.  Drawn as `#`.
- **pheromone** — `field-at` at the cell centre, normalised against
  `field-max` on a **log** scale.  Real trails sit two orders of magnitude
  below `*trail-cap*`, so a linear ramp shows a blank arena and one bright
  dot; this was worth writing down before anyone implements it and
  concludes the field is broken.  Ramp `" .:-=+*#"`.
- **food** — `o`, sized by `food-current-radius`, **not** `food-r` (the
  authored radius; the pile shrinks as it is eaten).
- **nest** — `@`, from `colony-nest-x/y/r`.
- **ant** — the bearing glyph, below.

Iteration guards, both of which are easy to get wrong: `ants-n` and
`bodies-n` are high-water marks, not counts — gate on `ant-live-p` and skip
`+body-free+`.  And `world-foods` mutates during `world-step!`, so nothing
may be cached across a tick.

### 4.3 The ant glyph, and what it can and cannot say

Heading is radians, `0 = +x`, counter-clockwise, wrapped to `(-π, π]`.
**World y is up and terminal rows go down, so the glyph must be chosen
after the flip** — index the table by `(- heading)`, not `heading`.  This
is not theoretical: the first draft of the mapping indexed in world space
and produced a rosette in which the bottom-right ant pointed up-right.  A
test pins it.

Two charsets, because they are not equivalent:

| set | glyphs | distinct shapes for 8 headings |
|---|---|---|
| `:unicode` (default) | `→ ↘ ↓ ↙ ← ↖ ↑ ↗` | **8** |
| `:ascii` (`--ascii`) | `- \ | / - \ | /` | **4** |

The ASCII set shows the *axis* of travel, not the direction — an ant going
north-west and one going south-east both draw `\`.  That is a real loss and
the reason Unicode is the default; ASCII is the fallback for a terminal
that cannot do better, selected automatically when the locale is not UTF-8
and forced by `--ascii`.  Verified by printing a 16-point rosette in both
and checking the sunburst is consistent.

Colour (optional, `--no-colour` and auto-off when not a tty): 16-colour
ANSI keyed off ant state — resting grey, outbound white, at-food yellow,
returning green, spent dim red — mirroring `ant-state-rgb`'s scheme so the
two views agree about what a colour means.  Multi-colony worlds tint by
`colony-id`.

### 4.4 The status line

Top row, and a pure function so it is testable:

```lisp
(tui-status w &key colony speed paused fps cols)  ; → string
```

Mirrors the window's `live-title` fields so the two views report the same
numbers: `t <s>s · <n> ants · stock <n> · trail <n> · <speed>x [paused]`,
plus the view scale.  Truncated to `cols` — on an 80-column terminal some
fields have to go, and dropping them from the right in a defined order
beats letting the line wrap and shove the world down a row.

### 4.5 Terminal handling

The part that has to be right or the user is left with a broken shell.

**Entering**: save termios; clear `icanon echo isig iexten` and `ixon`; set
`vmin`=0 `vtime`=0; switch to the alternate screen (`\e[?1049h`); hide the
cursor (`\e[?25l`).

**Leaving**: all of it undone, in an `unwind-protect`, on every path —
normal quit, an error, and `sb-sys:interactive-interrupt`.  `isig` is
cleared, so `^C` arrives as the byte 3 and is handled as a key rather than
a signal; the existing exit-code convention (130 for `^C`) is preserved by
returning it from the loop.

**Refusing politely**: if stdout is not a tty, do not garble a pipe — exit
2 with a message that names the next step, per the house rule that output a
user reads must say what to do about it.

**Size, which is dynamic and never assumed.**  `$COLUMNS` is not exported
to a child process — the probe returned `NIL` — so the ioctl is the source
of truth.  Queried at startup and re-queried on `SIGWINCH`.  On resize:
reallocate both canvases, keep the camera *centre* fixed while the visible
span changes with the new cell count, and force a full repaint (the diff is
meaningless across a size change).  The handler only sets a flag; the
resize is done by the loop, because reallocating two arrays inside a signal
handler is how a program acquires an intermittent crash nobody can
reproduce.  Degenerate sizes are handled rather than guarded against: below
about 20×6 the world pane vanishes and only the status line is drawn.

**Drawing without flicker**: two canvases, and only the cells that changed
are emitted, each preceded by a `\e[row;colH`.  Runs of adjacent changed
cells in a row share one cursor move and one colour set.  This is what the
escape sequences are for — repainting a whole 200×60 terminal every frame
is 12000 cells through a pipe and it looks like it.

### 4.6 Keys

Arrow keys arrive as `\e[A`..`\e[D`, and the decoder has to cope with a
sequence split across two non-blocking reads (drain what is available into
a buffer, decode complete sequences, keep the remainder).  A lone `\e` is
ambiguous until the next read, which is the classic bug; resolve it by
treating an unaccompanied `\e` as *escape* only after one poll has gone by
with nothing following.  The decoder is a pure function over a byte buffer
and is tested as one.

Bindings follow the window where the window has one, and invent where it
does not (there are no arrow keys in the GL window — panning there is
mouse-drag, so this is genuinely new):

| key | action |
|---|---|
| `←↑→↓` | pan (with `shift`/capital `HJKL` for a page) |
| `hjkl` | pan, for the vi-fingered |
| `+` `-` | speed ×2 / ÷2 — same as the window |
| `space` | pause — same as the window |
| `.` | single step **(new — the window has no such key)** |
| `f` | fit the whole arena |
| `t` | cycle the shown colony — same as the window |
| `a` | toggle ASCII / Unicode glyphs |
| `?` | key help overlay |
| `q` / `^C` | quit |

Kept as a list of `("key" "action")` pairs, following `*live-keys*`'s
precedent of legend-as-data.

## 5. Getting in

Two entry points, because there are two different machines.

**From a checkout, GL-free** — the point of the whole exercise.  A `make
tui` target loads `antsim/tui` *only*, so nothing dlopens GLFW:

```lisp
(tui-demo &key seed cols rows)          ; the built-in demo world
(tui-scenario path &key seed cols rows) ; a .json scenario
```

**From the shipped binary** — a `--tui` flag.  There are no subcommands in
this CLI and inventing the first one for this would be a large change for a
side feature, so it is an action keyword like the others:

- `(action ... ; :run :list :version :help :tui)` — that comment is a de
  facto enum and must be updated with it.
- a `((string= arg "--tui") (setf (cli-action cli) :tui))` clause,
- a `(:tui ...)` branch in `run-cli`'s `ecase`, returning an exit code,
- **outside** the `*missing-libraries*` guard, which lives inside `:run`
  only.  A terminal mode blocked by a missing graphics library would be
  absurd, and the guard is already written so it does not fire here.
- `--cols` / `--rows` as optional overrides.  `--width`/`--height` keep
  meaning pixels; overloading them with cells would be a trap.

Note that the shipped binary still loads `cl-glfw3` transitively via
`antsim/app`, and always will — that chain is not worth breaking for this.
It is not a problem in practice: the AppImage bundles `libglfw.so.3`, and
`image-restart-init` records a failed reopen in `*missing-libraries*`
rather than dying.  The genuinely GL-free path is `make tui` from a
checkout, and that is the one that must keep working.

## 6. Tests

`tests/tui.lisp`, `(in-suite antsim)` — the everywhere-runnable suite, not
a new system.  This is the payoff of keeping the render pure: no terminal
is needed to test the renderer.  Names are claims, in the house style.

- `a-camera-round-trips-a-world-point-through-a-cell`
- `a-cell-is-twice-as-tall-as-it-is-wide` — a square world in a square
  terminal is not square on screen, and this pins which way
- `fit-frames-the-whole-arena-in-both-dimensions`
- `panning-moves-the-centre-by-whole-cells`
- `panning-cannot-lose-the-arena-off-the-screen`
- `a-bearing-glyph-is-chosen-in-screen-space-not-world-space` — the
  regression the rosette caught
- `eight-headings-give-eight-unicode-glyphs-and-four-ascii-ones`
- `an-ant-outranks-the-food-it-is-standing-on`
- `a-dead-slot-is-not-drawn` — `ants-n` is a high-water mark
- `the-status-line-is-truncated-not-wrapped`
- `an-escape-sequence-split-across-two-reads-is-still-one-key`
- `a-lone-escape-is-not-an-arrow-key`
- `a-canvas-diff-emits-only-the-cells-that-changed`

Argv tests go in `tests/app.lisp` beside the existing `actions` test:
`--tui` parses to `:tui`, and `(search "--tui" (usage))` succeeds — there
is already a test doing exactly that for `--seed` and `--list`.

Nothing here needs a tty, so `make test` covers the lot.  A `make test-tui`
target is not needed and would only be a fourth system to keep in sync
across two CI workflow files.

## 7. Docs the feature owes

Per the repo's conventions, and CI enforces the second one:

1. `docs/concept.md` **§5.6**, after "5.5 The live window" — design
   rationale, the charset trade-off, the controls table.
2. `docs/concept.html`, the same content, then `make page` to regenerate
   `docs/index.html`.  **Never edit `index.html`** — CI fails with
   *"docs/index.html is stale"*.
3. `docs/concept.md` §4.1 gains the `antsim/tui` line; §4.6 gains `make tui`.
4. `docs/concept.md` §9 *Settled* gains the entry from §2 above: why a
   second renderer is not a fork of the first, and why raw ANSI beat curses.
5. `README.md`: a line under "Running it", and a controls table beside the
   window's.
6. `docs/config.md`: `--tui`, `--cols`, `--rows`, `--ascii`, `--no-colour`.
7. `Makefile`: `make tui`, with the several-line `##` prose header the other
   targets have.

`docs/shipping.md` needs nothing — no new bundled library, which is the
main argument for the no-dependency choice.

## 8. Order of work

Each phase ends somewhere useful, and the first two are worth having even
if the rest slips.

| phase | what | ends when |
|---|---|---|
| 0 | `antsim/tui` system, camera, canvas, draw, status — pure, plus their tests | `(princ (tui-frame w :cols 100 :rows 40))` prints a colony in a REPL, and `make test` covers it |
| 1 | `term.lisp`: raw mode, winsize, SIGWINCH, ANSI, diff blit, key decoder | a static world can be panned around with the arrow keys and the terminal survives `^C` |
| 2 | `live.lisp`: the loop, speed, pause, single-step, help | it is the feature |
| 3 | `--tui`, `--cols`, `--rows`, `make tui`, argv tests | it ships |
| 4 | docs 1–7 | `make page` is clean and CI is green |

## 9. Risks

- **Leaving the terminal wrecked.**  The one failure that outlives the
  program.  `unwind-protect` around everything, restore on error and on
  interrupt, and — because `isig` is cleared — handle byte 3 as quit.
- **Cell aspect.**  Wrong and everything looks subtly off; caught by a test
  rather than by eye.
- **A linear pheromone ramp showing nothing.**  Called out in §4.2 so it is
  not rediscovered as a bug.
- **Unicode on a terminal that cannot.**  Sniff the locale, default to
  ASCII when it is not UTF-8, and let `--ascii` force it.
- **POSIX only.**  `sb-posix` termios and `TIOCGWINSZ` are Linux/BSD.  The
  window already ships on Windows and the TUI will not; say so in the docs
  rather than pretending otherwise.
- **Not a bottleneck, but worth stating**: 1200 ants at 20 Hz with a diffed
  repaint at ~30 fps is a few thousand cells a frame.  There is no
  performance problem here and no optimisation should be written for one.
