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
add_library(caboose_gfxstream_connection STATIC socket_stream.cpp packet_framing.cpp decode_connection.cpp)
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
    option(CABOOSE_GFXSTREAM_PRESENTATION_LEASE "Build experimental decoder-owned presentation leases" OFF)
    if(CABOOSE_GFXSTREAM_PRESENTATION_LEASE AND NOT EXISTS "${GFXSTREAM_REPO_ROOT}/host/vulkan/caboose_presentation_lifetime.h")
        message(FATAL_ERROR "Presentation leases require the matching patched decoder source")
    endif()
    if(CABOOSE_GFXSTREAM_PRESENTATION_LEASE)
        file(STRINGS "${GFXSTREAM_REPO_ROOT}/host/vulkan/vk_decoder_global_state.h"
            CABOOSE_ACQUIRE_SYNC REGEX "acquireCabooseAcquireSync")
        if(NOT CABOOSE_ACQUIRE_SYNC)
            message(FATAL_ERROR "Presentation leases require the acquire fence lifetime patch")
        endif()
        file(STRINGS "${GFXSTREAM_REPO_ROOT}/host/vulkan/vk_decoder_global_state.h"
            CABOOSE_SWAPCHAIN_DEVICE REGEX "acquireCabooseSwapchainDevice")
        if(NOT CABOOSE_SWAPCHAIN_DEVICE)
            message(FATAL_ERROR "Presentation leases require the swapchain device lifetime patch")
        endif()
        file(STRINGS "${GFXSTREAM_REPO_ROOT}/host/vulkan/vk_decoder_global_state.h"
            CABOOSE_MAPPED_SOURCES REGEX "acquireCabooseMappedSources")
        if(NOT CABOOSE_MAPPED_SOURCES)
            message(FATAL_ERROR "Presentation leases require the mapped source lifetime patch")
        endif()
        file(STRINGS "${GFXSTREAM_REPO_ROOT}/host/features/include/gfxstream/host/features.h"
            CABOOSE_VIRTUAL_WSI_FEATURE REGEX "BoolFeatureInfo CabooseVirtualWsi")
        if(NOT CABOOSE_VIRTUAL_WSI_FEATURE)
            message(FATAL_ERROR "Presentation leases require the virtual WSI layout patch")
        endif()
    endif()
    add_library(caboose_gfxstream_framebuffer STATIC headless_framebuffer.cpp process_registry.cpp)
    target_compile_definitions(caboose_gfxstream_framebuffer PRIVATE GFXSTREAM_ENABLE_HOST_GLES=${CABOOSE_GFXSTREAM_HOST_GLES})
    if(CABOOSE_GFXSTREAM_PRESENTATION_LEASE)
        target_compile_definitions(caboose_gfxstream_framebuffer PRIVATE CABOOSE_GPU_PRESENTATION_LEASE=1)
        target_sources(caboose_gfxstream_framebuffer PRIVATE presentation_copy_internal.cpp presentation_swapchain_internal.cpp presentation_query_internal.cpp presentation_acquire_internal.cpp presentation_virtual_swapchain_internal.cpp)
    endif()
    target_compile_features(caboose_gfxstream_framebuffer PRIVATE cxx_std_17)
    target_include_directories(caboose_gfxstream_framebuffer PRIVATE
        "${GFXSTREAM_REPO_ROOT}"
        "${GFXSTREAM_REPO_ROOT}/host/vulkan"
        "${GFXSTREAM_REPO_ROOT}/host")
    target_link_libraries(caboose_gfxstream_framebuffer PUBLIC caboose_gfxstream_abi PRIVATE gfxstream_backend_static caboose_gfxstream_connection)
    add_library(caboose_gpu_native_runtime STATIC native_runtime.cpp)
    if(CABOOSE_GFXSTREAM_PRESENTATION_LEASE)
        target_compile_definitions(caboose_gpu_native_runtime PRIVATE CABOOSE_GPU_PRESENTATION_LEASE=1)
    endif()
    target_compile_features(caboose_gpu_native_runtime PRIVATE cxx_std_17)
    target_compile_definitions(caboose_gpu_native_runtime PRIVATE GFXSTREAM_ENABLE_HOST_GLES=${CABOOSE_GFXSTREAM_HOST_GLES})
    target_include_directories(caboose_gpu_native_runtime PUBLIC "${GFXSTREAM_REPO_ROOT}/third_party/vulkan/include" PRIVATE
        "${GFXSTREAM_REPO_ROOT}" "${GFXSTREAM_REPO_ROOT}/host"
        "${GFXSTREAM_REPO_ROOT}/host/vulkan")
    target_link_libraries(caboose_gpu_native_runtime PUBLIC caboose_gfxstream_abi PRIVATE
        caboose_gfxstream_framebuffer caboose_gfxstream_connection gfxstream_backend_static)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        target_sources(caboose_gpu_native_runtime PRIVATE metal_surface_internal.mm)
        if(CABOOSE_GFXSTREAM_PRESENTATION_LEASE)
            target_sources(caboose_gpu_native_runtime PRIVATE presentation_api.mm)
        endif()
        target_compile_options(caboose_gpu_native_runtime PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
        target_link_libraries(caboose_gpu_native_runtime PRIVATE "-framework Foundation" "-framework QuartzCore")
    endif()
    option(CABOOSE_GFXSTREAM_RUNTIME_TESTS "Build real-provider runtime lifecycle fixture" OFF)
    if(CABOOSE_GFXSTREAM_RUNTIME_TESTS)
        add_executable(caboose_gpu_native_runtime_lifecycle tests/native_runtime_lifecycle.cpp)
        target_compile_features(caboose_gpu_native_runtime_lifecycle PRIVATE cxx_std_17)
        target_compile_definitions(caboose_gpu_native_runtime_lifecycle PRIVATE GFXSTREAM_ENABLE_HOST_GLES=${CABOOSE_GFXSTREAM_HOST_GLES})
        target_include_directories(caboose_gpu_native_runtime_lifecycle PRIVATE
            "${CMAKE_CURRENT_SOURCE_DIR}" "${GFXSTREAM_REPO_ROOT}" "${GFXSTREAM_REPO_ROOT}/host"
            "${GFXSTREAM_REPO_ROOT}/host/vulkan")
        target_link_libraries(caboose_gpu_native_runtime_lifecycle PRIVATE caboose_gpu_native_runtime gfxstream_backend_static ${CMAKE_DL_LIBS})
        if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
            target_link_libraries(caboose_gpu_native_runtime_lifecycle PRIVATE "-framework OpenGL")
        endif()
        add_executable(caboose_gpu_native_stream_eof tests/native_stream_eof.cpp)
        target_compile_features(caboose_gpu_native_stream_eof PRIVATE cxx_std_17)
        target_include_directories(caboose_gpu_native_stream_eof PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
        target_link_libraries(caboose_gpu_native_stream_eof PRIVATE caboose_gpu_native_runtime gfxstream_host_iostream gfxstream_common_logging ${CMAKE_DL_LIBS})
        if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
            target_link_libraries(caboose_gpu_native_stream_eof PRIVATE "-framework OpenGL")
        endif()
    endif()
    if(CABOOSE_GFXSTREAM_HOST_GLES STREQUAL "1")
        target_include_directories(caboose_gfxstream_framebuffer PRIVATE
            "${GFXSTREAM_REPO_ROOT}/host/gl/glsnapshot")
    endif()
endif()

option(CABOOSE_GFXSTREAM_FRAMING_TESTS "Build portable decoder framing fixtures" OFF)
if(CABOOSE_GFXSTREAM_FRAMING_TESTS)
    add_executable(caboose_gfxstream_framing_test tests/packet_framing_test.cpp packet_framing.cpp)
    target_compile_features(caboose_gfxstream_framing_test PRIVATE cxx_std_17)
    target_include_directories(caboose_gfxstream_framing_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    add_executable(caboose_gpu_presentation_lifetime_test tests/presentation_lifetime_test.cpp)
    target_compile_features(caboose_gpu_presentation_lifetime_test PRIVATE cxx_std_17)
    target_include_directories(caboose_gpu_presentation_lifetime_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
endif()
