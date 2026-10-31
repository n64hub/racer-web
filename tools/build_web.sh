#!/usr/bin/env bash
# Builds the web page, web-build/build-web/SWE1Racer.html, from this checkout and your ROM (BUILDING.md says what it
# needs and how to serve it):
#
#   tools/build_web.sh [path/to/rom.z64]
#   tools/build_web.sh --patches          the patch step alone: no ROM, and only git, CMake and Python
#
# The ROM defaults to baserom.z64 here, and is needed once: its copy stays in web-build/. Safe to run again after a
# pull: every step skips what is done or redoes only what changed. Extra arguments for the page's CMake configure go in
# $WEB_CMAKE_ARGS (it runs once per build dir: delete web-build/build-web/build.ninja to configure again). --patches
# stops once everything is patched, which N64Recomp-browser's CI can run with its own checkout as lib/N64Recomp-browser.
#
# The page is built in web-build/, a clone of this checkout at its commit with its uncommitted changes, so the desktop
# build's deps/ and RecompiledFuncs/ here are left alone. Its deps/ there hold the libraries at the upstream commits
# N64Recomp-browser's patches are made on (lib/N64Recomp-browser/patches/patches.txt) in place of the desktop's forks,
# with the web support patched in, and then this port's own changes to them, made again for those commits:
#   patches/web/N64ModernRuntime.patch  the desktop runtime's fixes for this game: VI events before a mode is set,
#                                       osViSetMode, osPiReadIo, RECOMP_MEM_SIZE_MB, osGetCount's sign, save bounds,
#                                       deterministic mode, RDRAM kept mapped
#   patches/web/rt64.patch              the desktop RT64's VI modes whose framebuffer pixels are not square
#   patches/web/rt64-imgui.patch        upstream RT64's move to ImGui 1.92 (its 8bd2cf1, "Add PNG texture dumping and
#                                       Mac support for Inspector", less its Mac build files), merged with the web
#                                       support's shader changes: the desktop RT64 has it
# with RT64's ImGui and implot at the newer commits the desktop RT64 pins, which the menus (frontend/src/ui.cpp) use.
# The page's own changes to the game's code are in the code itself, behind __EMSCRIPTEN__.
# The recompiled code is made by N64Recomp patched for the web (N64Recomp-browser): it writes the tail calls as
# return_calls and keeps the FPU's rounding mode for float-to-int conversions, which WebAssembly's own instructions
# can't.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES_ONLY=false
if [ "${1:-}" = --patches ]; then PATCHES_ONLY=true; shift; fi
ROM="${1:-$HERE/baserom.z64}"
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac
WORK="$HERE/web-build"
BROWSER="$HERE/lib/N64Recomp-browser"
ROM_SHA1=3542d5597c8a56ea8f5c63bceae97a24c4c08d58
IMGUI=ed73ef4e84c9488256c5710de6ff1ebc2c9a8496
IMPLOT=09e2ba71766e25d88053a2173936c9d1043bae42
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

[ -f "$BROWSER/patches/patches.txt" ] || fail "lib/N64Recomp-browser is missing: git submodule update --init lib/N64Recomp-browser"
TOOLS="git cmake ninja clang clang++ python3 emcmake embuilder"
! $PATCHES_ONLY || TOOLS="git cmake python3"
for t in $TOOLS; do command -v "$t" > /dev/null || fail "$t not found"; done
upstream() { awk -v n="$1" '$1 == n { print $4 }' "$BROWSER/patches/patches.txt"; }

# ---------------------------------------------------------------- the copy
[ "$(git -C "$WORK" remote get-url origin 2> /dev/null)" = "$HERE" ] || rm -rf "$WORK"
[ -d "$WORK/.git" ] || git clone -q --no-checkout "$HERE" "$WORK"
cd "$WORK"
here_state() {
    git -C "$HERE" rev-parse HEAD
    git -C "$HERE" diff HEAD -- . ':!lib'
}

# ---------------------------------------------------------------- the patches
# Everything is patched from scratch whenever the patches, or what they patch, aren't as this left them.
LIBS="deps/rt64 deps/N64ModernRuntime"
patched_state() {
    {
        here_state
        cat "$BROWSER"/patches/*.patch
        git diff HEAD
        for lib in $LIBS; do
            git -C "$lib" rev-parse HEAD
            git -C "$lib" diff HEAD
            git -C "$lib" submodule foreach --recursive -q 'git rev-parse HEAD && git diff HEAD'
        done
    } | git hash-object --stdin
}
PATCHED="$(git rev-parse --git-dir)/web-patched"
if [ "$(cat "$PATCHED" 2> /dev/null)" != "$(patched_state 2> /dev/null)" ]; then
    step "Copying this checkout into web-build/ and patching it"
    git fetch -q "$HERE" HEAD
    git checkout -q -f --detach FETCH_HEAD
    git clean -fdq # files the last copy added (its ignored ones stay: deps/, the builds, RecompiledFuncs/)
    git -C "$HERE" diff --binary HEAD -- . ':!lib' | git apply --allow-empty
    # The libraries at N64Recomp-browser's upstream commits, clean.
    moveto() { # <dir> <upstream repository> <commit>
        [ -d "$1/.git" ] || git clone -q --no-checkout "$2" "$1"
        if [ "$(git -C "$1" rev-parse HEAD 2> /dev/null)" != "$3" ]; then
            git -C "$1" fetch -q --depth 1 origin "$3"
            git -C "$1" checkout -q -f --detach "$3"
        fi
        git -C "$1" submodule foreach --recursive -q 'git reset -q --hard && git clean -fdq'
        git -C "$1" reset -q --hard
        git -C "$1" clean -fdq
        git -C "$1" submodule update -q --init --recursive --depth 1
    }
    mkdir -p deps
    moveto deps/rt64 https://github.com/rt64/rt64 "$(upstream rt64)"
    moveto deps/N64ModernRuntime https://github.com/N64Recomp/N64ModernRuntime "$(upstream N64ModernRuntime)"

    # The web support (N64Recomp-browser), then this port's changes on top.
    web_patch() { cmake -P "$BROWSER/patches/apply.cmake" "$@"; }
    web_patch rt64 deps/rt64
    web_patch plume deps/rt64/src/contrib/plume
    web_patch hlslpp deps/rt64/src/contrib/hlslpp
    web_patch N64ModernRuntime deps/N64ModernRuntime
    web_patch N64Recomp deps/N64ModernRuntime/N64Recomp
    for pin in "src/contrib/imgui $IMGUI" "src/contrib/implot $IMPLOT"; do
        set -- $pin
        git -C "deps/rt64/$1" fetch -q --depth 1 origin "$2"
        git -C "deps/rt64/$1" checkout -q -f --detach "$2"
    done
    git -C deps/rt64 apply "$HERE/patches/web/rt64.patch"
    git -C deps/rt64 apply "$HERE/patches/web/rt64-imgui.patch"
    git -C deps/N64ModernRuntime apply "$HERE/patches/web/N64ModernRuntime.patch"
    patched_state > "$PATCHED"
fi
! $PATCHES_ONLY || { step "Patched"; exit 0; }

# ---------------------------------------------------------------- the recompiled code
step "Building the recompilers"
if [ ! -f build-tools/build.ninja ]; then
    cmake -S deps/N64ModernRuntime/N64Recomp -B build-tools -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="${HOST_CC:-clang}" -DCMAKE_CXX_COMPILER="${HOST_CXX:-clang++}" > /dev/null
fi
cmake --build build-tools --target N64RecompCLI RSPRecomp

if [ ! -f baserom.z64 ] || [ -f "$ROM" ]; then
    [ -f "$ROM" ] || fail "ROM not found: $ROM (your Star Wars Episode I: Racer US ROM, or pass its path)"
    [ "$(sha1sum "$ROM" | cut -d' ' -f1)" = "$ROM_SHA1" ] || fail "wrong ROM: expected SHA-1 $ROM_SHA1 (US, .z64)"
    cmp -s "$ROM" baserom.z64 || cp -f "$ROM" baserom.z64
fi

step "Recompiling the game"
# Made again whenever what makes it changes (the recompiler, its configs, the scripts after it), and only the files
# that changed are replaced, so the page's build recompiles only those.
inputs="$(cat build-tools/N64Recomp build-tools/RSPRecomp symbols.toml recomp.toml rsp/aspMain.toml \
    tools/fix_fallthroughs.py tools/post_recomp_patches.py baserom.z64 | git hash-object --stdin)"
if [ "$(cat RecompiledFuncs/inputs.txt 2> /dev/null)" != "$inputs" ] || [ ! -f rsp/aspMain.cpp ]; then
    rm -rf RecompiledFuncs.new && mkdir -p RecompiledFuncs.new RecompiledFuncs
    sed 's|^output_func_path = .*|output_func_path = "RecompiledFuncs.new"|' recomp.toml > recomp.web.toml
    ./build-tools/N64Recomp recomp.web.toml > recomp.log 2>&1 || { tail -20 recomp.log; fail "N64Recomp failed (web-build/recomp.log)"; }
    # The scripts patch RecompiledFuncs/, so they run on the new files there, in a folder of their own.
    rm -rf RecompiledFuncs.old && mv RecompiledFuncs RecompiledFuncs.old && mv RecompiledFuncs.new RecompiledFuncs
    python3 tools/fix_fallthroughs.py
    python3 tools/post_recomp_patches.py
    for file in RecompiledFuncs/*; do
        cmp -s "$file" "RecompiledFuncs.old/${file##*/}" && touch -r "RecompiledFuncs.old/${file##*/}" "$file"
    done
    rm -rf RecompiledFuncs.old
    ./build-tools/RSPRecomp rsp/aspMain.toml > /dev/null
    printf '%s' "$inputs" > RecompiledFuncs/inputs.txt
fi

# ---------------------------------------------------------------- the page
step "Building the page"
# The Emscripten ports CMake finds and the build depends on.
embuilder build sdl2-mt freetype-legacysjlj > /dev/null
if [ ! -f build-web/build.ninja ]; then
    emcmake cmake -S . -B build-web -G Ninja -DCMAKE_BUILD_TYPE=Release -DN64RECOMP_BROWSER_DIR="$BROWSER" ${WEB_CMAKE_ARGS:-}
fi
cmake --build build-web --target SWE1Racer

printf '\nDone: %s/build-web/SWE1Racer.html (BUILDING.md says how to serve it).\n' "$WORK"
