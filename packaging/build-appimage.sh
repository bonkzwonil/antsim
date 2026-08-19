#!/usr/bin/env bash
# packaging/build-appimage.sh — wrap the saved binary as an AppImage.
#
#   packaging/build-appimage.sh [version]
#
# Run from the top of the tree, after `make binary`.  With no version the
# one in antsim.asd is used.  Output: dist/antsim-<version>-x86_64.AppImage
#
# Target is a standard Ubuntu desktop.  What that means concretely, and
# what decides everything below:
#
#   * libGL / libEGL / libX11 / libwayland come from the user.  A desktop
#     has them by definition, and the GL ones MUST come from there — see
#     packaging/AppRun.
#   * GLFW does not.  `libglfw3` is not installed by default on Ubuntu, so
#     it is bundled.  It is the only library we ship.
#   * glibc is not bundled and cannot be, which is why CI builds on the
#     oldest Ubuntu it supports: a binary linked against a newer glibc
#     will not start on an older one, and the reverse is fine.
#
# Environment:
#   ANTSIM_BINARY    the saved executable      (default out/antsim)
#   ANTSIM_GLFW      path to libglfw.so.3      (default: ask the loader)
#   APPIMAGETOOL     path to appimagetool      (default: download, cached)
#   ARCH             AppImage architecture     (default x86_64)

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

binary="${ANTSIM_BINARY:-out/antsim}"
arch="${ARCH:-x86_64}"

version="${1:-}"
if [ -z "$version" ]; then
    # The .asd is the single source of truth for the version; read it
    # rather than restate it, so this script cannot be the thing that
    # disagrees with the release.
    version="$(sed -n 's/.*:version *"\([^"]*\)".*/\1/p' antsim.asd | head -1)"
fi
[ -n "$version" ] || { echo "cannot determine version" >&2; exit 1; }

[ -x "$binary" ] || { echo "no binary at $binary — run 'make binary' first" >&2; exit 1; }

appdir="dist/AppDir"
out="dist/antsim-${version}-${arch}.AppImage"

echo "==> building $out from $binary"
rm -rf "$appdir"
mkdir -p "$appdir/usr/bin" "$appdir/usr/lib" \
         "$appdir/usr/share/antsim" \
         "$appdir/usr/share/applications" \
         "$appdir/usr/share/icons/hicolor/256x256/apps"

install -m 755 "$binary" "$appdir/usr/bin/antsim"
install -m 755 packaging/AppRun "$appdir/AppRun"

# The desktop file and icon go in both places: at the AppDir root, where
# appimagetool insists on finding them, and under usr/share, where a
# desktop integrator that unpacks the image expects them.
install -m 644 packaging/antsim.desktop "$appdir/antsim.desktop"
install -m 644 packaging/antsim.desktop "$appdir/usr/share/applications/antsim.desktop"
install -m 644 packaging/antsim.png "$appdir/antsim.png"
install -m 644 packaging/antsim.png \
        "$appdir/usr/share/icons/hicolor/256x256/apps/antsim.png"

# The scenarios.  A binary that can only ever show the built-in demo is
# not the program; §6's format is half of what there is to look at.
cp -r scenarios "$appdir/usr/share/antsim/scenarios"
install -m 644 README.md "$appdir/usr/share/antsim/README.md"

# --- the one bundled library ------------------------------------------
find_lib() {
    local soname="$1" path
    path="$(ldconfig -p 2>/dev/null | awk -v s="$soname" '$1 == s {print $NF; exit}')" || true
    if [ -z "$path" ]; then
        for d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu; do
            [ -e "$d/$soname" ] && { path="$d/$soname"; break; }
        done
    fi
    printf '%s' "$path"
}

glfw="${ANTSIM_GLFW:-$(find_lib libglfw.so.3)}"
[ -n "$glfw" ] || { echo "libglfw.so.3 not found — install libglfw3" >&2; exit 1; }
# Follow the symlink: the AppDir wants the real object under the soname
# the loader will ask for, not a link into a directory that is not there.
cp -L "$glfw" "$appdir/usr/lib/libglfw.so.3"
chmod 644 "$appdir/usr/lib/libglfw.so.3"
echo "==> bundled $glfw"

# Say out loud what the user's machine is still expected to provide.  A
# packaging script that silently assumes things is how a release turns out
# to need a library nobody documented.
echo "==> expected from the host:"
ldd "$appdir/usr/lib/libglfw.so.3" "$appdir/usr/bin/antsim" 2>/dev/null |
    awk '/=>/ {print $1}' | sort -u | grep -v '^libglfw' | sed 's/^/      /'

# The ELF interpreter is the one thing in here that no LD_LIBRARY_PATH can
# rescue: the kernel reads it out of the header and uses it before the
# process exists.  A binary built under a Guix profile names a
# /gnu/store/… loader and will not start on any machine that has no such
# directory — which is every Ubuntu desktop this is aimed at.  It is an
# easy mistake (`make appimage` on a developer machine does it) and a
# silent one, so it is checked rather than assumed.
# Via ldd rather than readelf: binutils is not guaranteed to be installed
# and glibc's loader always is, and it prints its own path.
interp="$(LC_ALL=C ldd "$appdir/usr/bin/antsim" 2>/dev/null |
          grep -o '/[^ ]*ld-linux[^ ]*' | head -1)"
case "$interp" in
    /lib64/*|/lib/*|"")
        [ -n "$interp" ] && echo "==> interpreter $interp" ;;
    *)
        echo "==> WARNING: non-standard ELF interpreter" >&2
        echo "        $interp" >&2
        echo "    This AppImage will only start on a machine that has that" >&2
        echo "    exact path.  Release builds must come from CI (Ubuntu)," >&2
        echo "    not from a Guix or Nix profile." >&2 ;;
esac

# --- appimagetool ------------------------------------------------------
tool="${APPIMAGETOOL:-}"
if [ -z "$tool" ]; then
    tool="dist/appimagetool-${arch}.AppImage"
    if [ ! -x "$tool" ]; then
        echo "==> fetching appimagetool"
        curl -fsSLo "$tool" \
          "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${arch}.AppImage"
        chmod +x "$tool"
    fi
fi

# --appimage-extract-and-run: appimagetool is itself an AppImage, and
# containers and CI runners generally have no FUSE.  Without this the tool
# fails on a mount it never needed for this job.
ARCH="$arch" "$tool" --appimage-extract-and-run "$appdir" "$out"

chmod +x "$out"
echo "==> $out"
ls -lh "$out"
