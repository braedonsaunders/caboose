// SPDX-License-Identifier: MIT
// Isolated diagnostic using the real generated Mesa Vulkan encoder. This is
// deliberately not an ICD entrypoint and never enables the public socket ICD.
#include "SocketStream.h"
#include "ResourceTracker.h"
#include "VkEncoder.h"
#include <cstdio>
#include <cstdint>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: encoder_probe UNIX_SOCKET\n");
        return 2;
    }
    if (gfxstream::vk::ResourceTracker::get()->getStreamFeatures() != 0) {
        std::fprintf(stderr, "unexpected encoder feature mask\n");
        return 1;
    }
    auto* stream = new CabooseSocketStream(1024 * 1024);
    if (stream->connect(argv[1]) != 0) {
        std::perror("socket handshake");
        stream->decRef();
        return 1;
    }
    const uint32_t flags = 0;
    if (stream->writeFully(&flags, sizeof(flags)) != 0) {
        std::perror("client flags");
        stream->decRef();
        return 1;
    }
    uint32_t version = 0;
    VkResult result;
    {
        gfxstream::vk::VkEncoder encoder(stream);
        result = encoder.vkEnumerateInstanceVersion(&version, true);
    }
    stream->decRef();
    if (result != VK_SUCCESS || version == 0) {
        std::fprintf(stderr, "vkEnumerateInstanceVersion returned %d, version %u\n", result, version);
        return 1;
    }
    std::printf("{\"vk_result\":%d,\"api_version\":%u}\n", result, version);
    return 0;
}
