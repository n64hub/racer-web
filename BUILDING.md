# Building the web page

This fork's `main` branch builds the game with [Emscripten](https://emscripten.org) into a page, `SWE1Racer.html`,
that draws through WebGPU. The desktop build is upstream's and unchanged: README.md says how to build and run it.

The page is built in `web-build/` by `tools/build_web.sh` (its header says each step), a clone of this checkout, with
one difference from the desktop build: its `deps/rt64` and `deps/N64ModernRuntime` are upstream's at the commits
[N64Recomp-browser](https://github.com/n64hub/N64Recomp-browser) (`lib/N64Recomp-browser`) makes its patches on, with
the web support patched in (its `patches/apply.cmake`), and the desktop's changes to them made again for those commits
on top:

- `patches/web/N64ModernRuntime.patch`: the desktop runtime's fixes for this game (VI events before a mode is set,
  `osViSetMode`, `osPiReadIo`, `RECOMP_MEM_SIZE_MB`, `osGetCount`'s sign, save bounds, deterministic mode, RDRAM kept
  mapped).
- `patches/web/rt64.patch`: the desktop RT64's VI modes whose framebuffer pixels are not square.
- `patches/web/rt64-imgui.patch`: upstream RT64's move to ImGui 1.92 (its "Add PNG texture dumping and Mac support for
  Inspector", less its Mac build files), which the desktop RT64 has, merged with the web support's shader changes, with
  RT64's ImGui and implot at the commits the desktop RT64 pins. The launcher and menus (`frontend/src/ui.cpp`) use
  ImGui 1.92.

The page's own code is in the code itself, behind `__EMSCRIPTEN__`:

- `frontend/src/rt64_context.cpp`: RT64 draws on the page's canvas, with render to RAM's late copy on, and reads the
  game's display lists through the web runtime's interfaces.
- `frontend/src/ui.cpp`: the launcher and menus draw through WebGPU (a copy of rt64-web's inspector's renderer), and
  Load ROM opens the page's file picker.
- `frontend/src/audio.cpp`: the sound plays on the browser's audio thread (N64Recomp-browser's
  `frontend/audio_output.h`), resampled to its rate.
- `frontend/src/app.cpp`: saves and settings are kept under `/home/web_user/.config`, which the page keeps in the
  browser.
- `frontend/src/config.hpp`: the page opens without MSAA and at the display's rate (Framerate Display), as every page
  does.

The page needs recompiled code of its own: the web-patched N64Recomp writes a tail call as a `return_call` and keeps
the FPU's rounding mode for float-to-int conversions (WebAssembly's own instructions only round to nearest), so
`tools/build_web.sh` recompiles the game with it into `web-build/RecompiledFuncs/`.

What the page leaves out, since a browser can't do it: netplay (a page has no UDP sockets), cheats, texture packs
(there is no folder to put one in), fullscreen, the monitor and antialiasing settings, and Quit (a program that ends
leaves the page dead: a reload or closing the tab is the way out).

## What it needs

- The US ROM of Star Wars Episode I: Racer, once (`.z64`, SHA-1 `3542d5597c8a56ea8f5c63bceae97a24c4c08d58`): its copy
  is kept in `web-build/`.
- The [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html), installed and activated
  (`source emsdk_env.sh`).
- [naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga) on `PATH` (`cargo install naga-cli`), which turns the shaders
  into WGSL, and `spirv-opt` ([SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools)), without which the shaders
  come out about twice the size.
- A host clang and clang++ for the recompiler (`HOST_CC` and `HOST_CXX` pick others), CMake 3.20+, Ninja, git and
  Python 3.
- [ccache](https://ccache.dev) on `PATH`, optional: a second build dir then compiles nothing that was compiled before.

It was built on Linux, in the Docker image N64Recomp-browser's README describes.

## Building

```bash
git clone --recursive https://github.com/n64hub/racer-web
cd racer-web
tools/build_web.sh path/to/baserom.z64
```

Run again after a pull, without the ROM: each step skips what is done or redoes only what changed. `WEB_CMAKE_ARGS`
goes to the configure (`-DN64RECOMP_BROWSER_FAST_LINK=ON` for a quick link while trying something, never for a page
people play). `tools/build_web.sh --patches` stops once everything is patched and needs no ROM: N64Recomp-browser's CI
runs it over its own checkout, so a change there that stops this repo's patches applying is caught where it is made.

`web-build/build-web` then holds `SWE1Racer.html`, `.js`, `.wasm` and `coi_serviceworker.js`. The page must be
cross-origin isolated: serve the folder with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, or on a host that can't set headers (GitHub Pages), as is, and
`coi_serviceworker.js` sets them after one reload. The player picks their ROM in the launcher; it, the settings and the
saves are kept in the browser's IndexedDB for that origin.

## The shader list

`src/rt64_shaders.txt` lists the shaders the game draws with, which the page specializes at build time and builds
before the game needs them (without it, every new shader stalls the page as it is built). Its header says what was
played to record it: N64Recomp-browser's `tools/record_shaders.mjs` with `tools/shader_plan.json`, from the launcher
through Tournament's menus to the first race, and the 7 that plays of the play plans missed. It is 101 shaders:
the boot (94) and Boonta Training Course (7).

`tools/play_plan.json` (2-3 minutes) and `tools/play_plan_extended.json` (about 5) are the plays
N64Recomp-browser's `tools/play_page.mjs` runs to test the page. A shader a longer play draws that the list misses
(the page's console names it) goes into the list.

## How it plays

How the page plays in Chrome and Firefox, run by run, is recorded in N64Recomp-browser's
[plays.jsonl](https://github.com/n64hub/N64Recomp-browser/blob/main/plays.jsonl) and its
[games table](https://github.com/n64hub/N64Recomp-browser#games).
