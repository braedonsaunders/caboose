# The Linux executor: the phone's native runtime (the pinned gfxstream fork and the
# adapter beside this directory) built offscreen for Linux. See README.md.
cmake_minimum_required(VERSION 3.24)
project(CabooseLinuxExecutor LANGUAGES C CXX)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
    message(FATAL_ERROR "The Linux executor builds on Linux only")
endif()
if(NOT EXISTS "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/vulkan_dispatch.cpp")
    message(FATAL_ERROR "CABOOSE_GFXSTREAM_SOURCE must be the gfxstream fork at the pinned commit")
endif()
get_filename_component(CABOOSE_ADAPTER_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
# One shared library holds the decoder, so its objects must be position independent.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_STANDALONE ON CACHE BOOL "" FORCE)
set(ENABLE_VKCEREAL_TESTS OFF CACHE BOOL "" FORCE)
set(BUILD_GRAPHICS_DETECTOR OFF CACHE BOOL "" FORCE)
# The phone's configuration: Vulkan only, offscreen, the indexed v4 WSI.
set(CABOOSE_GFXSTREAM_HEADLESS ON CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_HOST_GLES 0 CACHE STRING "" FORCE)
set(CABOOSE_GFXSTREAM_PRESENTATION_LEASE ON CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_INDEXED_WSI ON CACHE BOOL "" FORCE)
set(CABOOSE_GFXSTREAM_MEMORY_AUDIT ON CACHE BOOL "" FORCE)
set(GFXSTREAM_REPO_ROOT "${CABOOSE_GFXSTREAM_SOURCE}")
add_subdirectory("${CABOOSE_GFXSTREAM_SOURCE}" upstream)
add_subdirectory("${CABOOSE_ADAPTER_DIR}" adapter)

# libcaboose_gpu_executor.so: the native runtime's C API (native_runtime.h, the presentation
# drafts with their headless entry points) and caboose_gpu_executor_start, for executor.py.
add_library(caboose_gpu_executor SHARED executor_start.cpp)
target_compile_features(caboose_gpu_executor PRIVATE cxx_std_17)
target_compile_definitions(caboose_gpu_executor PRIVATE CABOOSE_GPU_INDEXED_WSI=1)
target_include_directories(caboose_gpu_executor PRIVATE
    "${CABOOSE_ADAPTER_DIR}" "${CABOOSE_GFXSTREAM_SOURCE}/third_party/vulkan/include")
# Every runtime entry point, including those nothing in this library calls.
target_link_libraries(caboose_gpu_executor PRIVATE
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,caboose_gpu_native_runtime>"
    caboose_gfxstream_framebuffer caboose_gfxstream_connection gfxstream_backend_static ${CMAKE_DL_LIBS})
target_link_options(caboose_gpu_executor PRIVATE "LINKER:--no-undefined")
