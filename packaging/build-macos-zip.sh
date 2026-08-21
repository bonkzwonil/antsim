#!/bin/sh
# packaging/build-macos-zip.sh — wrap the saved binary for macOS release.
#
#   packaging/build-macos-zip.sh [VERSION] [BINARY] [GLFW_DYLIB]
#
# Run from the top of the tree, after the binary has been saved.
# Output: dist/antsim-<version>-macos-<arch>.zip

set -eu

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
esac

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(sed -n 's/.*:version[[:space:]]*"\([^"]*\)".*/\1/p' antsim.asd | head -n 1)
fi
if [ -z "$VERSION" ]; then
    echo "build-macos-zip: cannot determine version from antsim.asd" >&2
    exit 1
fi

BINARY="${2:-out/antsim}"
if [ ! -f "$BINARY" ]; then
    echo "build-macos-zip: binary $BINARY does not exist — build it first with make binary" >&2
    exit 1
fi

NAME="antsim-${VERSION}-macos-${ARCH}"
STAGE="dist/${NAME}"
ZIP="dist/${NAME}.zip"

echo "==> staging $NAME in $STAGE"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"

cp "$BINARY" "$STAGE/antsim"
chmod +x "$STAGE/antsim"
cp -r scenarios "$STAGE/scenarios"
cp README.md "$STAGE/README.md"

# Bundle GLFW dylib if provided or found
GLFW_DYLIB="${3:-}"
if [ -z "$GLFW_DYLIB" ]; then
    for cand in /opt/homebrew/lib/libglfw.3.dylib /usr/local/lib/libglfw.3.dylib /opt/homebrew/lib/libglfw.dylib /usr/local/lib/libglfw.dylib; do
        if [ -f "$cand" ]; then
            GLFW_DYLIB="$cand"
            break
        fi
    done
fi

if [ -n "$GLFW_DYLIB" ] && [ -f "$GLFW_DYLIB" ]; then
    cp "$GLFW_DYLIB" "$STAGE/libglfw.3.dylib"
    echo "==> bundled $GLFW_DYLIB"
fi

cat > "$STAGE/README-macos.txt" <<README_EOF
antsim $VERSION — macOS build ($ARCH)

Run from Terminal:
  ./antsim

Options and keys:
  ./antsim --help

Shipped scenarios:
  ./antsim --list
  ./antsim goss-double-bridge

Prerequisites:
  antsim requires OpenGL 4.1 Core Profile (built-in on macOS) and GLFW.
  If libglfw is not bundled or installed, install it via Homebrew:
    brew install glfw

Keep ./antsim and ./scenarios in the same folder.
README_EOF

mkdir -p dist
(cd dist && zip -rq "${NAME}.zip" "$NAME")
echo "==> wrote $ZIP"
