# Source-only adapter target. The caller must provide the real initialized
# gfxstream Vulkan backend and its transitive dependencies; this is not that backend.
if(NOT TARGET gfxstream-vulkan-server)
    message(FATAL_ERROR "Provide the pinned gfxstream-vulkan-server target before this adapter")
endif()
if(NOT GFXSTREAM_REPO_ROOT OR NOT EXISTS "${GFXSTREAM_REPO_ROOT}/host/vulkan/vk_decoder.h")
    message(FATAL_ERROR "GFXSTREAM_REPO_ROOT must name the pinned gfxstream checkout")
endif()
add_library(caboose_gfxstream_connection STATIC socket_stream.cpp decode_connection.cpp)
target_compile_features(caboose_gfxstream_connection PRIVATE cxx_std_17)
target_include_directories(caboose_gfxstream_connection PRIVATE
    "${GFXSTREAM_REPO_ROOT}/host/vulkan"
    "${GFXSTREAM_REPO_ROOT}/host/include")
target_link_libraries(caboose_gfxstream_connection PRIVATE gfxstream-vulkan-server gfxstream_host_iostream)
