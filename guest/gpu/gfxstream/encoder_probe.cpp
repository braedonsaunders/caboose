// SPDX-License-Identifier: MIT
// Isolated diagnostic using the real generated Mesa Vulkan encoder. This is
// deliberately not an ICD entrypoint and never enables the public socket ICD.
#include "SocketStream.h"
#include "ResourceTracker.h"
#include "VkEncoder.h"
#include <cstdio>
#include <cstdint>
#include <vector>

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
    // Enable the upstream wire bit only after the v2 hello was validated.
    GfxStreamVkFeatureInfo features = {};
    features.hasVulkanNullOptionalStrings = true;
    gfxstream::vk::ResourceTracker::get()->setupFeatures(&features);
    const uint32_t flags = 0;
    if (stream->writeFully(&flags, sizeof(flags)) != 0) {
        std::perror("client flags");
        stream->decRef();
        return 1;
    }
    uint32_t version = 0;
    VkResult result;
    uint32_t extensionCount = 0;
    VkResult extensionResult = VK_ERROR_INITIALIZATION_FAILED;
    {
        gfxstream::vk::VkEncoder encoder(stream);
        result = encoder.vkEnumerateInstanceVersion(&version, true);
        if (result == VK_SUCCESS) {
            extensionResult = encoder.vkEnumerateInstanceExtensionProperties(
                nullptr, &extensionCount, nullptr, true);
            if (extensionResult == VK_SUCCESS && extensionCount > 0 && extensionCount <= 4096) {
                std::vector<VkExtensionProperties> extensions(extensionCount);
                extensionResult = encoder.vkEnumerateInstanceExtensionProperties(
                    nullptr, &extensionCount, extensions.data(), true);
            } else if (extensionResult == VK_SUCCESS) {
                extensionResult = VK_ERROR_INITIALIZATION_FAILED;
            }
        }
    }
    stream->decRef();
    if (result != VK_SUCCESS || version == 0 || extensionResult != VK_SUCCESS) {
        std::fprintf(stderr, "vkEnumerateInstanceVersion returned %d, version %u\n", result, version);
        return 1;
    }
    std::printf("{\"vk_result\":%d,\"api_version\":%u,\"extension_result\":%d,\"extension_count\":%u}\n", result, version, extensionResult, extensionCount);
    return 0;
}
