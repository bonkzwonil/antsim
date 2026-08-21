# Shipping

How a release of antsim is built, what is in it, and why it is in it.

Three artefacts, one tag:

| | |
|---|---|
| **Linux** | `antsim-<version>-x86_64.AppImage` |
| **Windows** | `antsim-<version>-windows-x86_64.zip` |
| **macOS** | `antsim-<version>-macos-<arch>.zip` |

Neither needs SBCL, Quicklisp, or a checkout. All open the live window
of §5.5 and read the scenario files of §6.

---

## Making a release

The version in `antsim.asd` is the single source of truth. Everything
else reads it: the build script stamps it into the binary, both packaging
scripts name their output from it, and both release workflows refuse a tag
that disagrees with it.

```sh
# 1. bump :version in antsim.asd, and commit it
# 2. tag
git tag -a v1.0.0 -m 'antsim 1.0.0'
# 3. the canonical remote first — it builds and checks the Linux packaging
git push origin v1.0.0
# 4. then the release mirror, which is what publishes
git push github v1.0.0
```

Step 4 builds all platforms and creates a GitHub Release with the
artefacts and a `SHA256SUMS` beside them. A tag with a suffix —
`v1.0.0-rc1` — is published as a prerelease.

Nothing about this fires on an ordinary push. A release is a deliberate
act, and there is no useful sense in which every commit on `main` is one.

To test a change to the release machinery *without* spending a tag, run
the GitHub workflow by hand (`workflow_dispatch`). It builds all
artefacts, stamps them `<version>+<sha>` so they cannot be mistaken for
the release, and publishes nothing.

---

## What is in the packages, and what is not

The interesting decisions are all about the boundary between what we ship
and what the user's machine provides.

**OpenGL is never bundled.** It belongs to the
graphics driver, it has to match the kernel module actually loaded, and
putting a second GL implementation into the process is precisely the
failure `src/render/preload.lisp` exists to prevent — README §5.4. On
Linux the driver's `libGL`/`libEGL` come from the system; on macOS,
`OpenGL.framework` is provided by the OS; on Windows,
`opengl32.dll` is a system library and everything past GL 1.1 is fetched
through `wglGetProcAddress` against the live context.

**GLFW is bundled on Linux and Windows releases.** On macOS, GLFW can either
be bundled beside the executable (`libglfw.3.dylib`) or installed via Homebrew
(`brew install glfw`).

**glibc is not bundled and cannot be.** It is forward-compatible and not
backward-compatible: a binary runs on a newer glibc than it was built
against, never on an older one. So the release AppImage is built in an
`ubuntu:22.04` container — a container rather than a runner label, so the
pin does not expire the day GitHub retires an image — and therefore runs
on 22.04 and everything after it. Building on 24.04 would silently drop
22.04, and nothing would notice until a user did.

### Linux, the AppImage

```
AppRun                              LD_LIBRARY_PATH, then exec
usr/bin/antsim                      the saved SBCL image
usr/lib/libglfw.so.3                the only bundled library
usr/share/antsim/scenarios/*.json
antsim.desktop, antsim.png
```

`AppRun` puts `usr/lib` in front of the loader's search and leaves
everything else alone; the binary finds its scenarios through `$APPDIR`,
which the AppImage runtime sets.

If the AppImage will not mount, `--appimage-extract-and-run` unpacks it to
a temporary directory instead. That is a FUSE problem on the host, not a
problem with the build.

### Windows, the zip

```
antsim.exe
glfw3.dll        lib-static-ucrt, so no VC++ redistributable is implied
scenarios\
README-windows.txt
```

A zip and not an installer: for one executable, one DLL and a folder, an
installer buys a Start Menu entry and costs a SmartScreen warning about an
unsigned binary from an unknown publisher. Unpacking a folder is the
better first impression.

The `.exe` finds `glfw3.dll` and `scenarios\` because Windows searches the
executable's own directory first, which is also why there is no AppRun
equivalent here. Keep the folder together.

### macOS, the zip

```
antsim
libglfw.3.dylib  (optional bundled dylib, or resolved from Homebrew)
scenarios/
README-macos.txt
```

The macOS build targets **OpenGL 4.1 Core Profile** using texture buffer
objects (TBOs) for instance data. Unpack the zip and run `./antsim` directly
from Terminal.

---

## The OpenGL 4.1 Architecture and macOS

macOS caps OpenGL at **4.1 Core Profile** (`#version 410 core`). It lacks
OpenGL 4.3 (SSBOs) and OpenGL 4.4 (`glBufferStorage` persistent coherent mapping).

The project uses an OpenGL 4.1 Core Profile Texture Buffer Object (TBO) architecture
across all platforms:
- Instance data for bodies, articulated ants, and HUD items are stored in standard
  texture buffer objects (`samplerBuffer` / `usamplerBuffer`) formatted as `RGBA32F`
  and `R32UI`.
- Shaders index instances via `texelFetch(u_sampler, gl_InstanceID)`.
- Per-frame instance updates stream data via standard `glBufferSubData`.
- Headless rendering on macOS creates an invisible GLFW context (`:visible nil`)
  to render to offscreen framebuffers.

This architecture runs identically across macOS, Linux, and Windows.

---

## Building one by hand

```sh
make binary          # out/antsim — under a guix shell, for GLFW
make appimage        # dist/antsim-<version>-x86_64.AppImage
make macos-zip       # dist/antsim-<version>-macos-<arch>.zip
make icon            # regenerate packaging/antsim.png (committed)
make test-app        # the command line: argv, search path, exit codes
```

The `-bare` variants (`binary-bare`, `appimage-bare`, `test-app-bare`) are
the same commands without the `guix shell` wrapper, for a distribution
where GLFW is an ordinary system package. They are what CI runs, and they
share their command text with the wrapped targets so the two cannot drift
into building different things.

An AppImage built this way is built against *this* machine's glibc, and on
Guix against a `/gnu/store` ELF interpreter that no Ubuntu has. The
packaging script checks for that and says so out loud rather than handing
you an artefact that starts nowhere but here. Release builds come from CI.

---

## The part that is genuinely subtle

`save-lisp-and-die` writes out the memory of a running process. That
memory contains opinions about the machine it was running on, and three of
them do not survive being moved — all three failing quietly rather than
loudly, which is why `scripts/build-binary.lisp` and
`ANTSIM::IMAGE-RESTART-INIT` deal with each explicitly.

**Foreign libraries.** SBCL records every shared object it has opened and
reopens each one *by the path it was opened with*, inside `REINIT`, before
any hook of ours could have an opinion. Measured on a build machine, the
image had recorded:

```
libglfw.so.3
/gnu/store/…-mesa-26.0.2/lib/libGL.so.1
/gnu/store/…-profile/lib/libEGL.so.1
```

The absolute two are obviously unshippable. The soname is subtler and is
the one that actually bit: it resolves through the loader, which is fine
right up until a machine has no GLFW, and then `antsim --version` dies in
`REINIT` with an SBCL backtrace about a shared object, having never
reached a line of antsim. Printing a version number should not require a
window toolkit.

So the build closes all of them and the startup hook opens them again *by
name*, which is the only form that re-resolves through the loader — and
therefore the form that lets the AppImage's bundled copy win on
`LD_LIBRARY_PATH`. A failure is recorded rather than fatal: `--version`,
`--help` and `--list` keep working, and the one subcommand that needs a
window says which library is missing and how to install it.

**Cached GL entry points.** cl-opengl resolves extension functions once
and caches them as raw pointers into the GL implementation that was loaded
at the time. In a fresh process those addresses are meaningless. The
library provides `RESET-GL-POINTERS` for exactly this moment.

**The build directory.** `*default-pathname-defaults*` is wherever the
image was saved. A relative scenario path typed by a user has to resolve
against their working directory, not against a path on a CI runner.

None of this is needed when `MAIN` is called from a REPL, and none of it
does any harm there — which is what makes it testable without building an
image.

---

## Two remotes, one publisher

The canonical remote is the self-hosted instance; the GitHub repository is
a release mirror pushed by hand. Both have a release workflow and they do
different jobs:

- **Canonical** (`.forgejo/workflows/release.yml`) builds the Linux
  AppImage on a tag, proves it starts, and uploads it as a build artefact.
  It publishes nothing. Its purpose is that day-to-day work lands here, so
  a change that breaks the packaging is found on the tag *here* rather
  than when the mirror is pushed — which is the most expensive possible
  moment to find out.
- **Mirror** (`.github/workflows/release.yml`) builds both platforms and
  publishes the Releases page.

One publisher, deliberately. Two release pipelines would produce two
AppImages built on two base images with two different glibc floors, and
"the 1.0.0 Linux build" would name two files that are not the same file
and only one of which runs on Ubuntu 22.04.

If the canonical instance should host releases too, that is a Forgejo API
call away — create the release, then post the asset — but it should attach
*the same file* the mirror published rather than build a second one.

---

## Pins

`.github/workflows/release.yml` pins the Windows toolchain:

| | |
|---|---|
| `SBCL_WINDOWS_VERSION` | the SBCL MSI from SourceForge |
| `GLFW_WINDOWS_VERSION` | the GLFW binary release |
| `SHIP_HEAP` | dynamic space, frozen into the image by `:save-runtime-options` |

Pinned rather than "latest", because a release is the one build that
should be reproducible and a toolchain that moves under it is how two tags
with the same source produce two different binaries. Bumping them is
ordinary work when there is a reason.

`SHIP_HEAP` is worth understanding: `:save-runtime-options` freezes the
dynamic space size at build time, so it is not a build setting that
happens to leak — it is the shipped process's reserved address space,
forever. Four gigabytes of reservation, not of memory; the largest
scenario here runs in a small fraction of it. The 8192 the Makefile
defaults to is for building and testing.
