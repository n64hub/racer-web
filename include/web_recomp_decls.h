// Included first in every recompiled file on the web build (CMakeLists.txt): what the recompiled code calls without
// N64Recomp's funcs.h declaring it. WebAssembly checks each call's signature against the function it links to, and an
// implicitly declared one (int f()) doesn't match, so the call would trap.
#pragma once
#include "recomp.h"

#ifdef __cplusplus
extern "C" {
#endif

void __osSiRawStartDma_recomp(uint8_t* rdram, recomp_context* ctx); // src/main.cpp

#ifdef __cplusplus
}
#endif
