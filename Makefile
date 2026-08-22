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

# src/render/png.lisp emits *stored* deflate blocks — a valid zlib stream
# that needs no compressor, which is the right trade for a file a test
# writes and reads back, and the wrong one for a gallery: a 640x448 frame
# comes to 860 kB of essentially raw RGB and the hero to 3 MB.  So the
# gallery renders PNG and is then converted, and only the JPEGs are
# committed and published.
#
# Note the binary is `convert`, not `magick`: this is ImageMagick 6.
IM := guix shell imagemagick --
JPEG_QUALITY ?= 90

SMOKE_PNG ?= out/m0-smoke.png

# Make the systems findable without symlinking into ~/quicklisp/local-projects:
# a checkout anywhere builds with no setup.  The trailing ':' tells ASDF to
# append its default configuration, so Quicklisp's own dists still resolve.
export CL_SOURCE_REGISTRY := $(CURDIR):

.PHONY: all test acceptance test-app test-app-bare \
        test-render test-render-mesa test-render-ci \
        test-render-bare smoke smoke-mesa live gallery timelapse \
        word-scenario \
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
## antsim/live), but opens no window and needs no GPU, so it runs
## anywhere GLFW is installed — which includes the release CI.
test-app:
	$(WIN) sh -c 'LD_LIBRARY_PATH=$$GUIX_ENVIRONMENT/lib exec $(SBCL) \
	  --non-interactive \
	  --eval "(ql:quickload :antsim/app-test :silent t)" \
	  --eval "(uiop:quit (if (fiveam:run! (quote antsim/app-test::app)) 0 1))"'

## test-app-bare — the same, with no guix shell.  What CI runs.
test-app-bare:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/app-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/app-test::app)) 0 1))'

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
##   scenarios/antsim.json           1.00 x 0.72 m
##   scenarios/antsim-overload.json  the same arena, far too many ants
##   scenarios/antsim-large.json     5.00 x 3.60 m — five times over
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
##
## Rendered as PNG and then converted: JPEG at 4:4:4, because these are
## synthetic frames with hard edges between flat areas and chroma
## subsampling puts coloured fringes on exactly the trails and port
## outlines the pictures exist to show.  The PNGs are deleted, so what
## docs/images holds — and what the README, the concept page and Pages
## all serve — is the small version.
##
## The loop takes every PNG in the directory rather than only the ones
## RENDER-GALLERY just wrote, so a frame added by hand is converted too
## and cannot quietly reintroduce a megabyte.
gallery:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:render-gallery)'
	$(IM) sh -c 'for f in docs/images/*.png; do \
	  convert "$$f" -quality $(JPEG_QUALITY) -sampling-factor 1x1 -strip \
	          "$${f%.png}.jpg" || exit 1; done'
	rm -f docs/images/*.png
	@ls -la docs/images/

## check-images — what CI asks of docs/images: no PNGs left behind, and
## nothing over the byte budget.  Shares scripts/check-images.sh with both
## workflows, so the rule cannot mean one thing here and another there.
##
##   MAX_IMAGE_BYTES=200000 make check-images
check-images:
	$(IM) ./scripts/check-images.sh

## timelapse — half an hour of the gallery's scenario as one contact
## sheet, sampled every twenty simulated seconds and captioned with the
## simulated time.  Writes docs/images/16-timelapse.jpg.  The individual
## frames are *not* written by default: png.lisp compresses nothing by
## design, so a full sequence is ~300 MB of intermediate for one picture.
## To get them anyway, for ffmpeg:
##   sbcl ... --eval '(ant:render-timelapse-demo :frames t)'
##
## Converted and the PNG deleted for the same reason `gallery` is, and by
## the same rule: the sheet is the largest picture in the directory, so it
## is the one a PNG would cost most on.
timelapse:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:render-timelapse-demo)'
	$(IM) sh -c 'for f in docs/images/*.png; do \
	  convert "$$f" -quality $(JPEG_QUALITY) -sampling-factor 1x1 -strip \
	          "$${f%.png}.jpg" || exit 1; done'
	rm -f docs/images/*.png
	@ls -la docs/images/

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

## --- shipping (docs/shipping.md) --------------------------------------
##
## `binary` saves an executable; `appimage` wraps it for Linux.  Neither
## is what CI runs on a push — releases are tagged by hand, and the
## workflows fire on the tag.  These targets exist so that the thing CI
## does can be done here first, which is the only way to find out that it
## works without burning a tag to learn it.

## binary — save out/antsim (out/antsim.exe on Windows).
##
## Under a guix shell because the *build* needs GLFW present to load
## cl-glfw3, exactly as `live` does.  The saved image does not: it closes
## every foreign library before saving and opens them again on startup,
## so the binary this produces is not tied to this profile.  See the long
## comment in scripts/build-binary.lisp.
##
##   ANTSIM_COMPRESS=1 make binary    smaller core, slower start
##   ANTSIM_VERSION=1.0.0-rc1 make binary
BINARY ?= out/antsim
SAVE_IMAGE = sbcl --dynamic-space-size $(HEAP) \
	       --script scripts/build-binary.lisp $(BINARY)
binary:
	$(WIN) sh -c 'LD_LIBRARY_PATH=$$GUIX_ENVIRONMENT/lib exec $(SAVE_IMAGE)'

## binary-bare — the same save, with no guix shell around it: for a
## distribution where GLFW is an ordinary system package.  This is what
## CI runs, and it shares $(SAVE_IMAGE) with the target above precisely so
## that the two cannot drift into building different things.
binary-bare:
	$(SAVE_IMAGE)

## appimage — dist/antsim-<version>-x86_64.AppImage.
##
## Builds the binary first.  Note that an AppImage built here is built
## against *this* machine's glibc and, on Guix, against a /gnu/store
## loader that no Ubuntu has — the packaging script says so out loud.
## Releases are built on the oldest Ubuntu we support, in CI, for exactly
## this reason: a binary runs on a newer glibc than it was built against,
## never on an older one.
appimage: binary
	packaging/build-appimage.sh

## appimage-bare — as appimage, without the guix shell.  What CI runs.
appimage-bare: binary-bare
	packaging/build-appimage.sh

## icon — regenerate packaging/antsim.png.  Committed, so this is only
## needed when the drawing changes.
icon:
	$(SBCL) --script scripts/build-icon.lisp

dist-clean:
	rm -rf dist

clean: dist-clean
	find . -name '*.fasl' -delete
	rm -rf out
