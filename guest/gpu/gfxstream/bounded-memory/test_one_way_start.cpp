// SPDX-License-Identifier: MIT
#include "one_way_start.h"

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

using namespace caboose;

namespace {

VkInstanceCreateInfo instanceInfo(const char* const* extensions, uint32_t count, const VkApplicationInfo* app) {
    VkInstanceCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = app;
    info.enabledExtensionCount = count;
    info.ppEnabledExtensionNames = extensions;
    return info;
}

// The same instance asked twice, its extensions in another order, keys the same; another
// application or API version does not; a chained structure other than the loader's is never
// predicted.
void instanceQuestions() {
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "glxinfo";
    app.apiVersion = VK_API_VERSION_1_3;
    const char* ab[] = {"VK_KHR_surface", "VK_KHR_get_physical_device_properties2"};
    const char* ba[] = {"VK_KHR_get_physical_device_properties2", "VK_KHR_surface"};
    std::string first, second, third, fourth;
    auto one = instanceInfo(ab, 2, &app), two = instanceInfo(ba, 2, &app);
    assert(one_way::instanceQuestion(&one, &first));
    assert(one_way::instanceQuestion(&two, &second));
    assert(first == second);
    assert(one_way::instanceKey(first) == one_way::instanceKey(second));

    VkApplicationInfo other = app;
    other.apiVersion = VK_API_VERSION_1_1;
    auto three = instanceInfo(ab, 2, &other);
    assert(one_way::instanceQuestion(&three, &third));
    assert(one_way::instanceKey(third) != one_way::instanceKey(first));
    auto noApp = instanceInfo(ab, 2, nullptr);
    assert(one_way::instanceQuestion(&noApp, &fourth));
    assert(fourth != first);

    // The loader's own structure is taken off before the driver: it does not change the key.
    VkBaseInStructure loader{VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO, nullptr};
    auto withLoader = instanceInfo(ab, 2, &app);
    withLoader.pNext = &loader;
    std::string loaded;
    assert(one_way::instanceQuestion(&withLoader, &loaded) && loaded == first);
    // Anything else is asked every time.
    VkBaseInStructure messenger{VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, nullptr};
    auto withMessenger = instanceInfo(ab, 2, &app);
    withMessenger.pNext = &messenger;
    std::string refused;
    assert(!one_way::instanceQuestion(&withMessenger, &refused));
    const char* missing[] = {"VK_KHR_surface", nullptr};
    auto broken = instanceInfo(missing, 2, &app);
    assert(!one_way::instanceQuestion(&broken, &refused));
    assert(!one_way::instanceQuestion(nullptr, &refused));
    std::puts("pass instance questions");
}

// A success is kept for the connection it was asked on: not once the executor is lost, not
// for a connection that has since been replaced, and a new connection starts with none.
void keptForTheSession() {
    memory::StaticQueryCache cache;
    cache.connection("session-a", 9);
    completion::executorLost.store(false);
    memory::DeviceFingerprints::Fingerprint device{0x10, 1, 2};
    const std::string deviceKey = one_way::deviceKey(device);
    const std::string queueKey = one_way::queueKey(device, 0, 0, 0);
    assert(!one_way::succeededBefore(deviceKey, cache));

    uint64_t epoch = cache.epoch();
    one_way::succeeded(deviceKey, epoch, cache);
    assert(one_way::succeededBefore(deviceKey, cache));
    assert(!one_way::succeededBefore(queueKey, cache));
    assert(!one_way::succeededBefore(one_way::queueKey(device, 0, 0, 1), cache));
    // Another device's fingerprint is another question.
    assert(!one_way::succeededBefore(one_way::deviceKey({0x10, 1, 3}), cache));

    // An answer asked on a connection that has since been replaced is not kept for the new one.
    cache.connection("session-b", 9);
    assert(!one_way::succeededBefore(deviceKey, cache));
    one_way::succeeded(queueKey, epoch, cache);
    assert(!one_way::succeededBefore(queueKey, cache));

    // Nothing is kept once the executor is lost.
    epoch = cache.epoch();
    completion::executorLost.store(true);
    one_way::succeeded(queueKey, epoch, cache);
    one_way::listed(1, epoch, cache);
    completion::executorLost.store(false);
    assert(!one_way::succeededBefore(queueKey, cache));
    assert(one_way::listedBefore(cache) == 0);

    one_way::listed(1, epoch, cache);
    assert(one_way::listedBefore(cache) == 1);
    one_way::listed(0, epoch, cache);  // none found is never kept
    assert(one_way::listedBefore(cache) == 1);
    cache.connection("session-c", 9);
    assert(one_way::listedBefore(cache) == 0);
    std::puts("pass kept for the session");
}

// The grant needs silent success's; a process waits for its feed only so long, and not at all
// once the executor is lost.
void grantAndFeed() {
    auto& mode = silent::replyMode();
    mode.granted(false);
    mode.startGranted(true);
    assert(!one_way::granted());
    mode.granted(true);
    assert(one_way::granted());
    mode.startGranted(false);
    assert(!one_way::granted());
    mode.granted(false);

    completion::feedActive.store(false);
    completion::executorLost.store(false);
    const auto started = std::chrono::steady_clock::now();
    assert(!one_way::awaitFeed(std::chrono::milliseconds(20)));
    assert(std::chrono::steady_clock::now() - started >= std::chrono::milliseconds(20));
    std::thread feed([] {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        completion::feedActive.store(true);
    });
    assert(one_way::awaitFeed(std::chrono::seconds(5)));
    feed.join();
    completion::feedActive.store(false);
    completion::executorLost.store(true);
    const auto lost = std::chrono::steady_clock::now();
    assert(!one_way::awaitFeed(std::chrono::seconds(5)));
    assert(std::chrono::steady_clock::now() - lost < std::chrono::seconds(1));
    completion::executorLost.store(false);
    std::puts("pass grant and feed");
}

// REPLY_MODE(3) and back to 1 around a predicted command; a FAULT for one of the start
// commands loses the device, as any silent command's does.
void modesAndFaults() {
    uint8_t packet[silent::kReplyModePacketSize];
    silent::encodeReplyMode(packet, one_way::kModeStart);
    uint32_t words[4];
    std::memcpy(words, packet, sizeof(words));
    assert(words[0] == silent::kReplyModeOpcode && words[1] == silent::kReplyModePacketSize && words[2] == 3 &&
           words[3] == 0);
    silent::encodeReplyMode(packet);
    std::memcpy(words, packet, sizeof(words));
    assert(words[2] == silent::kModeSilentSuccess);
    for (uint32_t opcode : one_way::kStartOpcodes) {
        assert(one_way::startOpcode(opcode));
        assert(!silent::silentOpcode(opcode));  // REPLY_MODE(1) still answers them
    }
    assert(!one_way::startOpcode(20018u));

    completion::executorLost.store(false);
    silent::fault(20011u, -3);
    assert(completion::executorLost.load());
    completion::executorLost.store(false);
    std::puts("pass modes and faults");
}

}  // namespace

int main() {
    instanceQuestions();
    keptForTheSession();
    grantAndFeed();
    modesAndFaults();
    return 0;
}
