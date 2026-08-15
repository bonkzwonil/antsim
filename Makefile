# HEAP is overridable so a smaller machine can still build:
#   make test HEAP=3072
HEAP ?= 8192
SBCL := sbcl --dynamic-space-size $(HEAP) --noinform --disable-debugger

# GPU work needs the driver from a guix shell.  If a render comes back
# black, verify with `nvidia-smi` *inside* this shell before suspecting
# the renderer — see src/render/preload.lisp.
GPU := guix shell nvda@580 --

SMOKE_PNG ?= out/m0-smoke.png

# Make the systems findable without symlinking into ~/quicklisp/local-projects:
# a checkout anywhere builds with no setup.  The trailing ':' tells ASDF to
# append its default configuration, so Quicklisp's own dists still resolve.
export CL_SOURCE_REGISTRY := $(CURDIR):

.PHONY: all test test-render test-render-ci smoke repl page clean

all: test

## test — the core suite.  No GPU, no graphics stack.
test:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/test::antsim)) 0 1))'

## test-render — renderer suite under the GPU shell.  This is the one
## that actually verifies rendering.
test-render:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## test-render-ci — same suite without the guix/GPU wrapper, for machines
## with no driver: the PNG tests run and the GL tests SKIP rather than
## fail, so a green run here does NOT by itself mean the renderer works.
##
## On a host that already has the driver in its system profile this still
## reaches the GPU and really does verify it — check the suite's output
## for "Skip: 0" before reading a pass as proof of anything.
test-render-ci:
	$(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render-test :silent t)' \
	  --eval '(uiop:quit (if (fiveam:run! (quote antsim/render-test::render)) 0 1))'

## smoke — M0 end to end: headless context, drawn frame, PNG on disk.
smoke:
	$(GPU) $(SBCL) --non-interactive \
	  --eval '(ql:quickload :antsim/render :silent t)' \
	  --eval '(ant:m0-smoke :path #p"$(SMOKE_PNG)")'

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
