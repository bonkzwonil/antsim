# antsim — nothing to build yet; the code arrives at M0.
#
# HEAP is overridable so CI runners with less memory can build:
#   make test HEAP=3072
HEAP ?= 8192
SBCL := sbcl --dynamic-space-size $(HEAP) --noinform --disable-debugger

.PHONY: page clean

# docs/concept.html is an Artifact fragment (no doctype/head/body); this
# wraps it into a standalone docs/index.html for GitHub Pages or any other
# static host.  Edit docs/concept.html, never docs/index.html.
page:
	sbcl --script scripts/build-page.lisp

clean:
	find . -name '*.fasl' -delete
