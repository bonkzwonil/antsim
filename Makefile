# HEAP is overridable so a smaller machine can still build:
#   make test HEAP=3072
HEAP ?= 8192
SBCL := sbcl --dynamic-space-size $(HEAP) --noinform --disable-debugger

# By default, commands run directly against mainstream system packages
# (e.g. Ubuntu, Arch, Fedora, macOS, Windows, CI).
#
# For GNU Guix System or environments where OpenGL / NVIDIA drivers / GLFW
# live in isolated package profiles rather than system paths, set GUIX=1:
#   export GUIX=1          (or pass `make live GUIX=1`)
GUIX ?= $(or $(ANTSIM_GUIX),0)
NVDA_PKG ?= nvda@580

ifeq ($(filter-out 0 no false NO FALSE,$(GUIX)),)
  GPU_RUN  ?=
  MESA_RUN ?= env LIBGL_ALWAYS_SOFTWARE=1
  WIN_RUN  ?=
  IM_RUN   ?=
else
  # GPU work needs the driver from a guix shell. If a render comes back
  # black, verify with `nvidia-smi` *inside* this shell before suspecting
  # the renderer — see src/render/preload.lisp.
  GPU_RUN  ?= guix shell $(NVDA_PKG) --

  # Software rendering, for machines with no GPU. Mesa's llvmpipe gives a
  # real 4.5 core context, so the render suite runs in full rather than skipping.
  # The preload searches $GUIX_ENVIRONMENT/lib first, so entering a mesa
  # profile is by itself enough to win over an NVIDIA system profile;
  # LIBGL_ALWAYS_SOFTWARE then keeps Mesa off any hardware path.
  MESA_RUN ?= guix shell mesa -- env LIBGL_ALWAYS_SOFTWARE=1

  # The live window needs GLFW *and* the driver in the same profile, and it
  # needs LD_LIBRARY_PATH set INSIDE that profile — $GUIX_ENVIRONMENT does
  # not exist until the shell has been entered.
  WIN_RUN  ?= guix shell glfw $(NVDA_PKG) -- sh -c 'LD_LIBRARY_PATH=$$GUIX_ENVIRONMENT/lib exec "$$@"' --

  # src/render/png.lisp emits stored deflate blocks (uncompressed PNG).
  # The gallery converts PNG to JPEG with ImageMagick.
  IM_RUN   ?= guix shell imagemagick --
endif

JPEG_QUALITY ?= 90
SMOKE_PNG ?= out/m0-smoke.png

# Make the systems findable without symlinking into ~/quicklisp/local-projects:
# a checkout anywhere builds with no setup.  The trailing ':' tells ASDF to
# append its default configuration, so Quicklisp's own dists still resolve.
export CL_SOURCE_REGISTRY := $(CURDIR):

.PHONY: all test acceptance test-app test-app-bare \
        test-render test-render-mesa test-render-ci \
        test-render-bare smoke smoke-mesa live tui gallery word-scenario \
        repl page check-images clean binary binary-bare \
        appimage appimage-bare \
        icon dist-clean

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

## test-app — the shipped binary's command line: argv, the scenario
## search path, the exit codes.  Needs GLFW to *load* (antsim/app reaches
## antsim/live), but opens no window and needs no GPU.
test-app:
	$(WIN_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/app-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/app-test::app)) 0 1))'

## test-app-bare — alias for test-app.
test-app-bare: test-app

## test-render — renderer suite.  Verifies rendering against GPU driver if present.
test-render:
	$(GPU_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## test-render-mesa — the same suite in software on Mesa llvmpipe.  Needs no
## GPU and skips nothing, so this is what a test environment should run.
test-render-mesa:
	$(MESA_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## test-render-ci — alias for the software render run.
test-render-ci: test-render-mesa

## test-render-bare — alias for test-render.
test-render-bare: test-render

## smoke — M0 end to end: headless context, drawn frame, PNG on disk.
smoke:
	$(GPU_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:m0-smoke :path #p"$(SMOKE_PNG)")'

## smoke-mesa — the same frame in software, for comparing the two stacks.
smoke-mesa:
	$(MESA_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:m0-smoke :path #p"out/m0-smoke-mesa.png")'

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
	$(WIN_RUN) $(SBCL) \
	  --eval '(ql:quickload :antsim/live :silent t)' \
	  --eval '$(if $(SCENARIO),(ant:live-scenario "$(SCENARIO)" $(LIVE_ARGS)),(ant:live-demo $(LIVE_ARGS)))' \
	  --quit

## tui — the same colony, in this terminal, drawn in characters (§5.6).
## No LD_LIBRARY_PATH, no GPU and no graphics stack of any kind: this loads
## antsim/tui, which sits on the core and the scenario format and on nothing
## else.  That is the whole point of the target — it is the path that works
## on a box where `make live` cannot.
##
##   arrows or hjkl pan · z/Z zoom · space pause · . single tick
##   +/- time compression · f frame all · a ascii/arrows · ? keys · q quit
##   SCENARIO=scenarios/goss-double-bridge.json make tui   opens a file
##   SEED=12345 make tui                                   repeats a run
TUI_ARGS := $(if $(SEED),:seed $(SEED),)
tui:
	@$(SBCL) \
	  --eval '(ql:quickload :antsim/tui :silent t)' \
	  --eval '$(if $(SCENARIO),(ant:tui-scenario "$(SCENARIO)" $(TUI_ARGS)),(ant:tui-demo $(TUI_ARGS)))' \
	  --quit

## word-scenario — regenerate both word scenarios: the project's name
## spelled in obstacles, in the same 3x5 font the HUD draws with.
word-scenario:
	$(SBCL) --non-interactive --load scripts/build-word-scenario.lisp

## gallery — regenerate the README's images from a known scenario.  Every
## picture in the documentation comes from here rather than a screenshot,
## so it cannot drift away from what the simulation actually does.
##
## Rendered as PNG and then converted: JPEG at 4:4:4, because these are
## synthetic frames with hard edges between flat areas and chroma
## subsampling puts coloured fringes on exactly the trails and port
## outlines the pictures exist to show.  The PNGs are deleted, so what
## docs/images holds — and what the README, the concept page and Pages
## all serve — is the small version.
gallery:
	$(GPU_RUN) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:render-gallery)'
	$(IM_RUN) sh -c 'for f in docs/images/*.png; do \
	  convert "$$f" -quality $(JPEG_QUALITY) -sampling-factor 1x1 -strip \
	          "$${f%.png}.jpg" || exit 1; done'
	rm -f docs/images/*.png
	@ls -la docs/images/

## check-images — what CI asks of docs/images: no PNGs left behind, and
## nothing over the byte budget.
##   MAX_IMAGE_BYTES=200000 make check-images
check-images:
	$(IM_RUN) ./scripts/check-images.sh

repl:
	sbcl --dynamic-space-size $(HEAP) \
	  --eval '(ql:quickload :antsim)' \
	  --eval '(in-package :antsim)'

## page — regenerate docs/index.html from docs/concept.html.  CI fails if
## the two have drifted, so run this after editing the concept page.
page:
	sbcl --script scripts/build-page.lisp

## --- shipping (docs/shipping.md) --------------------------------------
##
## `binary` saves an executable; `appimage` wraps it for Linux.

## binary — save out/antsim (out/antsim.exe on Windows).
##
##   ANTSIM_COMPRESS=1 make binary    smaller core, slower start
##   ANTSIM_VERSION=1.0.0-rc1 make binary
BINARY ?= out/antsim
SAVE_IMAGE = sbcl --dynamic-space-size $(HEAP) \
	       --script scripts/build-binary.lisp $(BINARY)
binary:
	$(WIN_RUN) $(SAVE_IMAGE)

## binary-bare — alias for binary.
binary-bare: binary

## appimage — dist/antsim-<version>-x86_64.AppImage.
##
## Builds the binary first.
appimage: binary
	packaging/build-appimage.sh

## appimage-bare — alias for appimage.
appimage-bare: appimage

## icon — regenerate packaging/antsim.png.  Committed, so this is only
## needed when the drawing changes.
icon:
	$(SBCL) --script scripts/build-icon.lisp

dist-clean:
	rm -rf dist

clean: dist-clean
	find . -name '*.fasl' -delete
	rm -rf out
