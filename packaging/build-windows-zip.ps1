# packaging/build-windows-zip.ps1 — wrap the saved .exe as a release zip.
#
#   pwsh packaging/build-windows-zip.ps1 [-Version 0.4.0] [-Binary out/antsim.exe]
#
# Run from the top of the tree, after the binary has been saved.  Output:
# dist/antsim-<version>-windows-x86_64.zip
#
# A zip and not an installer, deliberately.  An installer for a program
# that is one executable, one DLL and a directory of scenarios buys the
# user a Start Menu entry and costs them a trust prompt about an unsigned
# binary from an unknown publisher — which is a worse first impression than
# unpacking a folder.
#
# What goes in, and why it is exactly this:
#
#   antsim.exe    the saved SBCL image, runtime and all
#   glfw3.dll     the window toolkit.  Windows has no package manager we
#                 can lean on, so this is not optional the way it is on
#                 Linux.  It sits beside the .exe because the loader
#                 searches the executable's own directory first — which is
#                 also why there is no equivalent of AppRun here.
#   scenarios\    §6's files; the program finds them beside the .exe
#   README.md     what the thing is
#
# What is NOT in it: opengl32.dll, which is a system library belonging to
# the graphics driver.  Everything past GL 1.1 is fetched through
# wglGetProcAddress against the live context, so there is exactly one GL
# implementation in the process and nothing to bundle or to get wrong.

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Binary  = 'out/antsim.exe',
    [string]$GlfwDll = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not $Version) {
    # antsim.asd is the single source of truth for the version.  Read it
    # rather than restate it: a packaging script is a bad place to learn
    # that two files disagree.
    $asd = Get-Content antsim.asd -Raw
    if ($asd -match ':version\s+"([^"]+)"') { $Version = $Matches[1] }
}
if (-not $Version) { throw "cannot determine version" }

if (-not (Test-Path $Binary)) { throw "no binary at $Binary — build it first" }

$name    = "antsim-$Version-windows-x86_64"
$stage   = Join-Path 'dist' $name
$zip     = Join-Path 'dist' "$name.zip"

Write-Host "==> building $zip from $Binary"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item $Binary (Join-Path $stage 'antsim.exe')
Copy-Item -Recurse scenarios (Join-Path $stage 'scenarios')
Copy-Item README.md (Join-Path $stage 'README.md')

# --- glfw3.dll ---------------------------------------------------------
if (-not $GlfwDll) {
    $candidates = @('glfw3.dll', 'lib/glfw3.dll', 'dist/glfw3.dll')
    foreach ($c in $candidates) {
        if (Test-Path $c) { $GlfwDll = $c; break }
    }
}
if (-not $GlfwDll -or -not (Test-Path $GlfwDll)) {
    throw "glfw3.dll not found. Pass -GlfwDll, or place it at the top of the tree."
}
Copy-Item $GlfwDll (Join-Path $stage 'glfw3.dll')
Write-Host "==> bundled $GlfwDll"

# A note in the package itself.  The one thing that can go wrong on a
# Windows machine is a graphics driver too old for a 4.5 core context, and
# that failure deserves a sentence the user can read rather than a window
# that never appears.
@"
antsim $Version — Windows build

Run antsim.exe.  Options and keys:  antsim.exe --help
Shipped scenarios:                  antsim.exe --list
One of them:                        antsim.exe goss-double-bridge

Keep antsim.exe, glfw3.dll and the scenarios folder together.  The
program looks for scenarios beside the executable, and Windows looks for
the DLL there too.

Requires a graphics driver providing OpenGL 4.5 — any GPU driver from the
last decade does, but the Microsoft Basic Display Adapter that Windows
installs before you install a real driver does not.  If the window does
not open, that is the first thing to check.
"@ | Set-Content -Path (Join-Path $stage 'README-windows.txt') -Encoding UTF8

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "==> $zip"
Get-Item $zip | Format-List Name, Length
