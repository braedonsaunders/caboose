# Private, compile/link-only iOS target. Never installs or launches an app.
cmake_minimum_required(VERSION 3.24)
project(CabooseGfxstreamIOSProbe LANGUAGES C CXX OBJC OBJCXX)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR "Configure this probe with an iOS SDK")
endif()
if(NOT EXISTS "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/vulkan_dispatch.cpp")
    message(FATAL_ERROR "CABOOSE_GFXSTREAM_SOURCE must be the patched private source")
endif()
if(NOT EXISTS "${CABOOSE_ADAPTER_DIR}/process_registry.cpp")
    message(FATAL_ERROR "CABOOSE_ADAPTER_DIR must be a private snapshot of the adapter")
endif()
if(NOT EXISTS "${CABOOSE_MOLTENVK_ARCHIVE}")
    message(FATAL_ERROR "CABOOSE_MOLTENVK_ARCHIVE must be the stock iOS static library")
endif()
set(BUILD_STANDALONE ON CACHE BOOL "" FORCE)
set(ENABLE_VKCEREAL_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_GRAPHICS_DETECTOR OFF CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_HEADLESS ON CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_HOST_GLES 0 CACHE STRING "" FORCE)
set(GFXSTREAM_REPO_ROOT "${CABOOSE_GFXSTREAM_SOURCE}")
add_subdirectory("${CABOOSE_GFXSTREAM_SOURCE}" upstream)
add_subdirectory("${CABOOSE_ADAPTER_DIR}" adapter)
add_executable(caboose_gfxstream_ios_link_probe link_probe.cpp)
set_target_properties(caboose_gfxstream_ios_link_probe PROPERTIES MACOSX_BUNDLE OFF)
target_compile_features(caboose_gfxstream_ios_link_probe PRIVATE cxx_std_17)
target_include_directories(caboose_gfxstream_ios_link_probe PRIVATE
    "${CABOOSE_ADAPTER_DIR}"
    "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan"
    "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/cereal/common")
target_link_libraries(caboose_gfxstream_ios_link_probe PRIVATE
    caboose_gfxstream_framebuffer caboose_gfxstream_connection gfxstream_backend_static
    "${CABOOSE_MOLTENVK_ARCHIVE}" "-framework Foundation" "-framework CoreGraphics"
    "-framework IOSurface" "-framework Metal" "-framework QuartzCore" "-framework UIKit" z)
