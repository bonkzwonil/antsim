#!/bin/sh
# scripts/check-images.sh — keep docs/images web-sized.
#
# The gallery is rendered by `make gallery`, which writes PNG and then
# converts to JPEG with ImageMagick, because src/render/png.lisp emits
# stored deflate blocks: a 640x448 frame is 860 kB of essentially raw RGB
# and the hero was 3 MB.  Nothing stops a hand-made frame being committed
# in that state, and nobody notices a slow page — so CI asks.
#
# Two questions, both about what a reader downloads:
#
#   1. Is anything in docs/images still a PNG?  If it is, `make gallery`
#      was not run to completion, or a picture was added by hand and never
#      converted.
#   2. Is anything larger than the budget?  The budget is deliberately
#      several times the largest frame we ship, so it fires on a mistake
#      rather than on a picture that happens to be busy.
#
# Uses ImageMagick's `identify` rather than `ls` alone, so the log says
# what the picture *is* — format and dimensions — next to what it costs.
# ImageMagick 6 spells the binary `identify`; 7 keeps it as a shim.
#
# Run: make check-images   (or directly, with identify on PATH)

set -eu

DIR=${IMAGE_DIR:-docs/images}
MAX=${MAX_IMAGE_BYTES:-300000}

[ -d "$DIR" ] || { echo "check-images: no $DIR, nothing to check"; exit 0; }

fail=0

for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    bytes=$(wc -c < "$f")
    printf '  %-36s %8s B  %s\n' \
        "$f" "$bytes" "$(identify -format '%m %wx%h' "$f" 2>/dev/null || echo '?')"

    case "$f" in
        *.png)
            echo "    ERROR: PNG in $DIR — run 'make gallery' to convert it"
            fail=1
            ;;
    esac

    if [ "$bytes" -gt "$MAX" ]; then
        echo "    ERROR: $bytes B exceeds the $MAX B budget"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "check-images: docs/images is not web-sized (see above)"
    exit 1
fi

echo "check-images: ok — nothing in $DIR is a PNG or over $MAX B"
