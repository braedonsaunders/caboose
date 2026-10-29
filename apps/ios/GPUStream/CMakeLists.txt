# The GPU stream player: GFXReconstruct's Vulkan replay, a C API and MoltenVK, merged into
# one static library for CabooseKit. scripts/build-gpu-stream.sh configures it once per
# platform; see apps/ios/README.md.
cmake_minimum_required(VERSION 3.24)
project(CabooseGPUStream LANGUAGES C CXX OBJCXX)

set(GFXRECON_SOURCE_DIR "" CACHE PATH "GFXReconstruct source tree, with the patches in patches/ applied")
set(MOLTENVK_LIBRARY "" CACHE FILEPATH "MoltenVK static library for this platform, a single architecture")
if (NOT EXISTS "${GFXRECON_SOURCE_DIR}/framework" OR NOT EXISTS "${MOLTENVK_LIBRARY}")
    message(FATAL_ERROR "Set GFXRECON_SOURCE_DIR and MOLTENVK_LIBRARY (scripts/build-gpu-stream.sh does)")
endif ()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)

# GFXReconstruct's replay only: no OpenXR, no LZ4 or Zstd (zlib comes with the SDK), no
# headless or display surfaces, and its warnings are not errors in this build.
set(GFXRECON_ENABLE_OPENXR OFF CACHE BOOL "" FORCE)
set(GFXRECON_TOCPP_SUPPORT OFF CACHE BOOL "" FORCE)
set(LZ4_OPTIONAL ON CACHE BOOL "" FORCE)
set(BUILD_WERROR OFF CACHE BOOL "" FORCE)
set(RUN_TESTS OFF CACHE BOOL "" FORCE)
set(CMAKE_DISABLE_FIND_PACKAGE_LZ4 ON)
set(CMAKE_DISABLE_FIND_PACKAGE_ZSTD ON)
set(HEADLESS FALSE)
if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # GFXReconstruct's own application target links AppKit, which iOS lacks. This build
    # never builds that target (caboose_gpu_stream compiles the application layer itself),
    # but CMake still requires the library to be found.
    set(APPKIT_LIBRARY "-framework UIKit" CACHE STRING "Stands in for AppKit in GFXReconstruct's unused application target")
endif ()
# GFXReconstruct's tools are configured but never built; on iOS CMake would otherwise make
# each executable a bundle, which their install rules do not describe.
set(CMAKE_MACOSX_BUNDLE OFF)
add_subdirectory("${GFXRECON_SOURCE_DIR}" gfxreconstruct EXCLUDE_FROM_ALL)

# GFXReconstruct's application layer, with layer_window.mm in place of its AppKit
# MetalContext and MetalWindow.
add_library(caboose_gpu_stream STATIC
    src/player.mm
    src/layer_window.mm
    "${GFXRECON_SOURCE_DIR}/framework/application/application.cpp"
    "${GFXRECON_SOURCE_DIR}/framework/application/wsi_context.cpp")
target_include_directories(caboose_gpu_stream PRIVATE include src "${GFXRECON_SOURCE_DIR}/framework")
target_compile_options(caboose_gpu_stream PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(caboose_gpu_stream PRIVATE
    gfxrecon_decode
    gfxrecon_encode
    gfxrecon_graphics
    gfxrecon_format
    gfxrecon_util
    gfxrecon_replay_event_plugin_abi
    gfxrecon_replay_event_plugin_loader
    vulkan_registry
    platform_specific)

# Everything the player needs, in one archive.
set(merged "${CMAKE_BINARY_DIR}/libCabooseGPUStream.a")
add_custom_command(OUTPUT "${merged}"
    COMMAND libtool -static -no_warning_for_no_symbols -o "${merged}"
        $<TARGET_FILE:caboose_gpu_stream>
        $<TARGET_FILE:gfxrecon_decode>
        $<TARGET_FILE:gfxrecon_encode>
        $<TARGET_FILE:gfxrecon_graphics>
        $<TARGET_FILE:gfxrecon_format>
        $<TARGET_FILE:gfxrecon_util>
        $<TARGET_FILE:gfxrecon_replay_event_plugin_loader>
        $<TARGET_FILE:spirv-reflect-static>
        $<TARGET_FILE:project_version>
        "${MOLTENVK_LIBRARY}"
    DEPENDS caboose_gpu_stream gfxrecon_decode gfxrecon_encode gfxrecon_graphics gfxrecon_format gfxrecon_util
        gfxrecon_replay_event_plugin_loader spirv-reflect-static project_version "${MOLTENVK_LIBRARY}"
    COMMENT "Merging libCabooseGPUStream.a"
    VERBATIM)
add_custom_target(caboose_gpu_stream_merged ALL DEPENDS "${merged}")
