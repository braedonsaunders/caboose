# Source-only adapter target. The caller must provide the real initialized
# gfxstream Vulkan backend and its transitive dependencies; this is not that backend.
if(NOT TARGET gfxstream-vulkan-server)
    message(FATAL_ERROR "Provide the pinned gfxstream-vulkan-server target before this adapter")
endif()
if(NOT GFXSTREAM_REPO_ROOT OR NOT EXISTS "${GFXSTREAM_REPO_ROOT}/host/vulkan/vk_decoder.h")
    message(FATAL_ERROR "GFXSTREAM_REPO_ROOT must name the pinned gfxstream checkout")
endif()
# Must match the backend's RenderThreadInfo layout in every translation unit.
set(CABOOSE_GFXSTREAM_HOST_GLES 1 CACHE STRING "GFXSTREAM_ENABLE_HOST_GLES used by the supplied backend")
if(NOT CABOOSE_GFXSTREAM_HOST_GLES MATCHES "^[01]$")
    message(FATAL_ERROR "CABOOSE_GFXSTREAM_HOST_GLES must be 0 or 1")
endif()
# Upstream directory-wide definitions do not propagate into an external adapter.
# Generated Vulkan dispatch layouts must match the backend translation units.
add_library(caboose_gfxstream_abi INTERFACE)
target_compile_definitions(caboose_gfxstream_abi INTERFACE
    VK_GFXSTREAM_STRUCTURE_TYPE_EXT GLM_FORCE_RADIANS GLM_FORCE_DEFAULT_ALIGNED_GENTYPES)
foreach(version 1_0 1_1 1_2 1_3 1_4)
    target_compile_definitions(caboose_gfxstream_abi INTERFACE
        VK_BASE_VERSION_${version} VK_COMPUTE_VERSION_${version} VK_GRAPHICS_VERSION_${version})
endforeach()
if(APPLE)
    target_compile_definitions(caboose_gfxstream_abi INTERFACE
        VK_USE_PLATFORM_MACOS_MVK VK_USE_PLATFORM_METAL_EXT)
endif()
add_library(caboose_gfxstream_connection STATIC socket_stream.cpp decode_connection.cpp)
target_compile_definitions(caboose_gfxstream_connection PRIVATE GFXSTREAM_ENABLE_HOST_GLES=${CABOOSE_GFXSTREAM_HOST_GLES})
target_compile_features(caboose_gfxstream_connection PRIVATE cxx_std_17)
target_include_directories(caboose_gfxstream_connection PRIVATE
    "${GFXSTREAM_REPO_ROOT}"
    "${GFXSTREAM_REPO_ROOT}/host"
    "${GFXSTREAM_REPO_ROOT}/host/vulkan"
    "${GFXSTREAM_REPO_ROOT}/host/include")
target_link_libraries(caboose_gfxstream_connection PUBLIC caboose_gfxstream_abi PRIVATE gfxstream-vulkan-server gfxstream_host_iostream)
# RenderThreadInfo's GLES variant includes gles_v2_decoder.h, which includes
# gl_snapshot.h. Upstream GLSnapshot exposes this directory, but the Vulkan
# server target does not propagate it to this external adapter.
if(CABOOSE_GFXSTREAM_HOST_GLES STREQUAL "1")
    target_include_directories(caboose_gfxstream_connection PRIVATE
        "${GFXSTREAM_REPO_ROOT}/host/gl/glsnapshot")
endif()

# This retains the real upstream framebuffer and offscreen Vulkan compositor.
# Its upstream target currently has desktop dependencies and is not iOS-ready.
if(TARGET gfxstream_backend_static)
    add_library(caboose_gfxstream_framebuffer STATIC headless_framebuffer.cpp process_registry.cpp)
    target_compile_definitions(caboose_gfxstream_framebuffer PRIVATE GFXSTREAM_ENABLE_HOST_GLES=${CABOOSE_GFXSTREAM_HOST_GLES})
    target_compile_features(caboose_gfxstream_framebuffer PRIVATE cxx_std_17)
    target_include_directories(caboose_gfxstream_framebuffer PRIVATE
        "${GFXSTREAM_REPO_ROOT}"
        "${GFXSTREAM_REPO_ROOT}/host/vulkan"
        "${GFXSTREAM_REPO_ROOT}/host")
    target_link_libraries(caboose_gfxstream_framebuffer PUBLIC caboose_gfxstream_abi PRIVATE gfxstream_backend_static caboose_gfxstream_connection)
    if(CABOOSE_GFXSTREAM_HOST_GLES STREQUAL "1")
        target_include_directories(caboose_gfxstream_framebuffer PRIVATE
            "${GFXSTREAM_REPO_ROOT}/host/gl/glsnapshot")
    endif()
endif()
