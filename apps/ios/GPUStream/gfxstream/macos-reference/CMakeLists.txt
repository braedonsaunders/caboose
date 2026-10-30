cmake_minimum_required(VERSION 3.24)
project(CabooseGfxstreamReference LANGUAGES C CXX OBJC OBJCXX)
if(NOT EXISTS "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/vulkan_dispatch.cpp")
    message(FATAL_ERROR "CABOOSE_GFXSTREAM_SOURCE must be a patched private gfxstream copy")
endif()
get_filename_component(CABOOSE_ADAPTER_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(BUILD_STANDALONE ON CACHE BOOL "" FORCE)
set(ENABLE_VKCEREAL_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_GRAPHICS_DETECTOR OFF CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_HOST_GLES 1 CACHE STRING "" FORCE)
set(GFXSTREAM_REPO_ROOT "${CABOOSE_GFXSTREAM_SOURCE}")
add_subdirectory("${CABOOSE_GFXSTREAM_SOURCE}" upstream)
add_subdirectory("${CABOOSE_ADAPTER_DIR}" adapter)
add_executable(caboose_gfxstream_lifecycle lifecycle.cpp)
target_compile_features(caboose_gfxstream_lifecycle PRIVATE cxx_std_17)
target_include_directories(caboose_gfxstream_lifecycle PRIVATE
    "${CABOOSE_ADAPTER_DIR}"
    "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan"
    "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/cereal/common")
target_link_libraries(caboose_gfxstream_lifecycle PRIVATE
    caboose_gfxstream_framebuffer caboose_gfxstream_connection gfxstream_backend_static)

# The retained macOS EGL backend calls CGL and desktop GL directly.
if(APPLE)
    target_link_libraries(caboose_gfxstream_lifecycle PRIVATE "-framework OpenGL")
endif()
