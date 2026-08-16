# HEAP is overridable so a smaller machine can still build:
#   make test HEAP=3072
HEAP ?= 8192
SBCL := sbcl --dynamic-space-size $(HEAP) --noinform --disable-debugger

# GPU work needs the driver from a guix shell.  If a render comes back
# black, verify with `nvidia-smi` *inside* this shell before suspecting
# the renderer — see src/render/preload.lisp.
GPU := guix shell nvda@580 --

# Software rendering, for machines with no GPU.  Mesa's llvmpipe gives a
# real 4.5 core context (measured: "4.5 (Core Profile) Mesa 26.0.2",
# GLSL 4.50), so the render suite runs in full rather than skipping.
# It is slow, which does not matter for a handful of small frames.
#
# The preload searches $GUIX_ENVIRONMENT/lib first, so entering a mesa
# profile is by itself enough to win over an NVIDIA system profile;
# LIBGL_ALWAYS_SOFTWARE then keeps Mesa off any hardware path.
MESA := guix shell mesa -- env LIBGL_ALWAYS_SOFTWARE=1

# The live window needs GLFW *and* the driver in the same profile, and it
# needs LD_LIBRARY_PATH set INSIDE that profile — $GUIX_ENVIRONMENT does
# not exist until the shell has been entered, so setting it on the outside
# silently expands to nothing.  Hence `sh -c` rather than `env`.
WIN := guix shell glfw nvda@580 --

SMOKE_PNG ?= out/m0-smoke.png

# Make the systems findable without symlinking into ~/quicklisp/local-projects:
# a checkout anywhere builds with no setup.  The trailing ':' tells ASDF to
# append its default configuration, so Quicklisp's own dists still resolve.
export CL_SOURCE_REGISTRY := $(CURDIR):

.PHONY: all test acceptance test-render test-render-mesa test-render-ci \
        test-render-bare smoke smoke-mesa live gallery word-scenario \
        repl page clean

all: test

## test — the core suite.  No GPU, no graphics stack.
test:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/test::antsim)) 0 1))'

## acceptance — the §3.8 rows that are published experiments rather than
## properties of a function: Deneubourg's binary bridge and Goss's double
## bridge.  Separate from `test` because each row is several simulated
## colony-minutes per seed, and the claims are about a distribution over
## seeds rather than a single run.  No GPU.
acceptance:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/test::acceptance)) 0 1))'

## test-render — renderer suite under the GPU shell.  This is the one
## that actually verifies rendering.
test-render:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## test-render-mesa — the same suite in software on llvmpipe.  Needs no
## GPU and skips nothing, so this is what a test environment should run.
## Slow, and that is fine.
test-render-mesa:
	$(MESA) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## test-render-ci — alias for the software run.  CI has no GPU, and a
## suite that silently skips its GL tests is worse than one that is slow.
test-render-ci: test-render-mesa

## test-render-bare — no wrapper at all: whatever GL the host happens to
## have.  GL tests SKIP if it has none, so a green run here proves only
## the PNG writer.  The suite prints the backend it used; read that line
## before reading the result.
test-render-bare:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## smoke — M0 end to end: headless context, drawn frame, PNG on disk.
smoke:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:m0-smoke :path #p"$(SMOKE_PNG)")'

## live — the interactive window (§5.5).  The window itself lists its keys
## in the bottom-right corner; `h` hides that legend.
##   wheel zoom (cursor-anchored) · right-drag pan · left-click inspect
##   space pause · +/- time compression · home frame all · q or escape quit
##   SCENARIO=scenarios/goss-double-bridge.json make live   opens a file
##   SEED=12345 make live                                   repeats a run
##
## Without SEED the window draws a fresh one and prints it, so every
## session differs and any session worth keeping can be replayed.  The
## headless paths — tests, acceptance, gallery — are unaffected and stay
## deterministic; a playground and a result are different things.
LIVE_ARGS := $(if $(SEED),:seed $(SEED),)
live:
	$(WIN) sh -c 'LD_LIBRARY_PATH=$$GUIX_ENVIRONMENT/lib exec $(SBCL) \
	  --eval "(ql:quickload :antsim/live :silent t)" \
	  --eval "$(if $(SCENARIO),(ant:live-scenario \"$(SCENARIO)\" $(LIVE_ARGS)),(ant:live-demo $(LIVE_ARGS)))" \
	  --quit'

## word-scenario — regenerate both word scenarios: the project's name
## spelled in obstacles, in the same 3x5 font the HUD draws with.  Built
## from *FONT-3X5* itself rather than a transcription of it, so the
## scenarios cannot drift away from the font and spelling something else
## is a one-line change.
##
##   scenarios/antsim.json        1.00 x 0.72 m
##   scenarios/antsim-large.json  5.00 x 3.60 m — the same, five times over
##
## Only the geometry is five times bigger.  The ant is not scaled, which
## is the whole reason the large one is a different experiment rather than
## the same picture printed larger: a journey five times longer costs five
## times the energy out of the same fixed tank, so the large file restates
## the forager's range in its `ant` block.  At the default it starves.
word-scenario:
	$(SBCL) --non-interactive --load scripts/build-word-scenario.lisp

## gallery — regenerate the README's images from a known scenario.  Every
## picture in the documentation comes from here rather than a screenshot,
## so it cannot drift away from what the simulation actually does.
gallery:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:render-gallery)'

## smoke-mesa — the same frame in software, for comparing the two stacks.
smoke-mesa:
	$(MESA) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:m0-smoke :path #p"out/m0-smoke-mesa.png")'

repl:
	sbcl --dynamic-space-size $(HEAP) \
	  --eval '(ql:quickload :antsim)' \
	  --eval '(in-package :antsim)'

## page — regenerate docs/index.html from docs/concept.html.  CI fails if
## the two have drifted, so run this after editing the concept page.
page:
	sbcl --script scripts/build-page.lisp

clean:
	find . -name '*.fasl' -delete
	rm -rf out
