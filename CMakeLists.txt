cmake_minimum_required(VERSION 3.20)

project(SWE1Racer VERSION 0.2.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED True)

# The RSP vector unit code (librecomp, aspMain) uses SSE4.1 on x86; MSVC needs no flag for it.
if(NOT MSVC AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    add_compile_options(-msse4.1)
endif()

# With Emscripten (emcmake cmake), the game builds as a page for a browser, SWE1Racer.html, drawn through WebGPU by
# N64Recomp-browser (lib/N64Recomp-browser). tools/build_web.sh makes the libraries it needs in web-build/ and builds it
# there (BUILDING.md).
if(EMSCRIPTEN)
    set(N64RECOMP_BROWSER_DIR "${CMAKE_SOURCE_DIR}/lib/N64Recomp-browser" CACHE PATH "Path to N64Recomp-browser")
    # Threads are pthreads (SharedArrayBuffer), and the runtime ends a game thread by throwing. -msimd128 is wasm SIMD,
    # which every browser with WebGPU has; -mtail-call is the recompiled code's return_calls.
    add_compile_options(-pthread -fwasm-exceptions -msimd128 -mtail-call)
    # With -msimd128 xxHash would take its NEON path through Emscripten's arm_neon.h, which doesn't compile in C++
    # there. XXH_HAS_INCLUDE is used for nothing else, so XXH3 stays scalar.
    add_compile_options("-DXXH_HAS_INCLUDE(x)=0")
    add_link_options(-pthread -fwasm-exceptions)
    # ccache when it is on PATH.
    include(${N64RECOMP_BROWSER_DIR}/frontend/build_speed.cmake)
    # The shaders the page specializes at build time and builds before the game draws with them (the file says how it
    # was recorded).
    if(EXISTS ${CMAKE_SOURCE_DIR}/src/rt64_shaders.txt)
        set(RT64_PREBUILT_SHADER_LIST ${CMAKE_SOURCE_DIR}/src/rt64_shaders.txt)
    endif()
endif()

# =============================================================================
# Options
# =============================================================================
# Toolkits: deps/ when tools/setup.ps1 fetched them there, else sibling checkouts.
foreach(dep N64ModernRuntime rt64)
    if(EXISTS "${CMAKE_SOURCE_DIR}/deps/${dep}/CMakeLists.txt")
        set(default_${dep} "${CMAKE_SOURCE_DIR}/deps/${dep}")
    else()
        set(default_${dep} "${CMAKE_SOURCE_DIR}/../${dep}")
    endif()
endforeach()
set(N64_MODERN_RUNTIME_DIR "${default_N64ModernRuntime}" CACHE PATH "Path to N64ModernRuntime")
set(RT64_DIR "${default_rt64}" CACHE PATH "Path to RT64 renderer")

# =============================================================================
# SDL2: on Windows the build RT64 ships (RT64 links it by bare name from this folder);
# on Linux and macOS the system's (apt/dnf/pacman libsdl2, brew sdl2)
# =============================================================================
if(EMSCRIPTEN)
    # Emscripten's own port of SDL2, as RT64 takes it.
    add_library(SDL2::SDL2 INTERFACE IMPORTED)
    set_target_properties(SDL2::SDL2 PROPERTIES INTERFACE_COMPILE_OPTIONS "-sUSE_SDL=2" INTERFACE_LINK_OPTIONS "-sUSE_SDL=2")
    add_library(SDL2::SDL2main INTERFACE IMPORTED)
elseif(ANDROID)
    # SDL's source tree, staged into the Gradle project by scripts/build_android.sh
    # Shared: SDL's Java side loads libSDL2.so before libmain.so.
    set(SDL_SHARED ON CACHE BOOL "" FORCE)
    set(SDL_STATIC OFF CACHE BOOL "" FORCE)
    add_subdirectory(${SDL2_SOURCE_DIR} ${CMAKE_BINARY_DIR}/SDL)
    set(SDL2_INCLUDE_DIRS "${SDL2_SOURCE_DIR}/include")
elseif(NOT WIN32)
    find_package(SDL2 REQUIRED)
    if(NOT TARGET SDL2::SDL2main)
        add_library(SDL2::SDL2main INTERFACE IMPORTED)
    endif()
else()
set(SDL2_DIR_WIN "${RT64_DIR}/src/contrib/mupen64plus-win32-deps/SDL2-2.26.3")
link_directories("${SDL2_DIR_WIN}/lib/x64")
add_library(SDL2::SDL2 SHARED IMPORTED)
set_target_properties(SDL2::SDL2 PROPERTIES
    IMPORTED_LOCATION "${SDL2_DIR_WIN}/lib/x64/SDL2.dll"
    IMPORTED_IMPLIB "${SDL2_DIR_WIN}/lib/x64/SDL2.lib"
    INTERFACE_INCLUDE_DIRECTORIES "${SDL2_DIR_WIN}/include")
add_library(SDL2::SDL2main STATIC IMPORTED)
set_target_properties(SDL2::SDL2main PROPERTIES IMPORTED_LOCATION "${SDL2_DIR_WIN}/lib/x64/SDL2main.lib")
endif()

# =============================================================================
# RT64 Renderer
# =============================================================================
set(RT64_STATIC ON CACHE BOOL "Build RT64 as static library" FORCE)
add_subdirectory(${RT64_DIR} ${CMAKE_BINARY_DIR}/rt64)

# =============================================================================
# N64ModernRuntime (librecomp + ultramodern)
# =============================================================================
add_subdirectory(${N64_MODERN_RUNTIME_DIR} ${CMAKE_BINARY_DIR}/N64ModernRuntime)
# The game's own libultra pokes VI/AI/PI/MI registers (0xA4000000+) directly;
# commit memory past kseg0 so those accesses land in scratch memory.
target_compile_definitions(librecomp PUBLIC RECOMP_MEM_SIZE_MB=640)

if(EMSCRIPTEN)
    add_subdirectory(${N64RECOMP_BROWSER_DIR}/frontend ${CMAKE_BINARY_DIR}/web_frontend)
    # fmt 11.1 (N64Recomp's) leans on <cstdlib> arriving through other headers, which Emscripten's libc++ doesn't do.
    target_compile_options(fmt PRIVATE -include cstdlib)
endif()

# =============================================================================
# Recompiled Functions Library
# =============================================================================
file(GLOB RECOMP_SOURCES "RecompiledFuncs/*.c")

add_library(RecompiledFuncs STATIC ${RECOMP_SOURCES})

target_include_directories(RecompiledFuncs PRIVATE
    ${N64_MODERN_RUNTIME_DIR}/N64Recomp/include  # recomp.h
    ${CMAKE_SOURCE_DIR}/RecompiledFuncs           # funcs.h
)

# Disable strict aliasing for recompiled code (MIPS memory access patterns)
if(MSVC)
    # MSVC doesn't have strict aliasing by default
else()
    # -Wno-implicit-function-declaration: N64Recomp calls __osSiRawStartDma_recomp (src/main.cpp)
    # without declaring it in funcs.h; clang 16+ makes that an error.
    target_compile_options(RecompiledFuncs PRIVATE -fno-strict-aliasing -Wno-implicit-function-declaration)
endif()
# WebAssembly checks a call's signature when it links and turns a call to an undeclared function into a trap, so with
# Emscripten that is an error, but for the one call above, which src/main.cpp defines with the signature it is called
# with.
if(EMSCRIPTEN)
    target_compile_options(RecompiledFuncs PRIVATE -Werror=implicit-function-declaration)
    target_compile_options(RecompiledFuncs PRIVATE "SHELL:-include ${CMAKE_SOURCE_DIR}/include/web_recomp_decls.h")
endif()

# =============================================================================
# Main Executable
# =============================================================================
add_subdirectory(frontend)

set(GAME_SOURCES src/main.cpp src/section_table.cpp rsp/aspMain.cpp)
if(ANDROID)
    # SDL's Java side (SDLActivity) loads libmain.so and calls its SDL_main.
    add_library(SWE1Racer SHARED ${GAME_SOURCES})
    set_target_properties(SWE1Racer PROPERTIES OUTPUT_NAME main)
else()
    add_executable(SWE1Racer ${GAME_SOURCES})
endif()
if(NOT EXISTS "${CMAKE_SOURCE_DIR}/rsp/aspMain.cpp")
    message(FATAL_ERROR "rsp/aspMain.cpp is missing. Run: RSPRecomp rsp/aspMain.toml (tools/setup.ps1 does it)")
endif()

target_include_directories(SWE1Racer PRIVATE
    ${N64_MODERN_RUNTIME_DIR}/N64Recomp/include     # recomp.h
    ${N64_MODERN_RUNTIME_DIR}/librecomp/include      # librecomp headers
    ${N64_MODERN_RUNTIME_DIR}/ultramodern/include    # ultramodern headers
    ${RT64_DIR}/src                                   # RT64 headers
    ${RT64_DIR}/src/contrib                           # RT64 contrib (json, im3d, etc.)
    ${RT64_DIR}/src/contrib/hlslpp/include            # hlsl++
    ${RT64_DIR}/src/contrib/plume                     # plume render interface
    ${RT64_DIR}/src/contrib/imgui                     # imgui
    ${RT64_DIR}/src/contrib/mupen64plus-core/src/api  # mupen64plus API types
    ${CMAKE_SOURCE_DIR}/RecompiledFuncs              # funcs.h
    ${CMAKE_SOURCE_DIR}/include
)

# RT64 requires these defines for its headers (normally set at directory scope)
target_compile_definitions(SWE1Racer PRIVATE NOMINMAX HLSL_CPU FFX_GCC)

target_link_libraries(SWE1Racer PRIVATE
    RecompiledFuncs
    librecomp
    ultramodern
    n64frontend
    rt64
    SDL2::SDL2
    SDL2::SDL2main
)

if(EMSCRIPTEN)
    # The page (lib/N64Recomp-browser/frontend). No ROM in it: the player picks theirs in the launcher, and it stays in
    # the browser.
    n64recomp_browser_frontend_page(SWE1Racer)
endif()

if(WIN32)
    target_link_libraries(SWE1Racer PRIVATE dxgi d3d12 d3dcompiler dbghelp ws2_32)
    target_link_options(SWE1Racer PRIVATE /MAP)
    # RT64 loads the DXC runtime next to the exe; without it setup() silently skips init.
    add_custom_command(TARGET SWE1Racer POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${RT64_DIR}/src/contrib/dxc/bin/x64/dxil.dll ${RT64_DIR}/src/contrib/dxc/bin/x64/dxcompiler.dll
        ${SDL2_DIR_WIN}/lib/x64/SDL2.dll
        $<TARGET_FILE_DIR:SWE1Racer>)
endif()
