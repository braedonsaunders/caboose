// SPDX-License-Identifier: MIT
#include "device_answers.h"
#include <cassert>
#include <cstdio>
using caboose::memory::DeviceFingerprints;
using caboose::memory::layoutQuestion;

int main() {
    // Fingerprints tell creations apart by every byte and by length, and keep the physical
    // device that scopes their answers.
    const char a[] = "extensions features queues", b[] = "extensions features queuez";
    const auto fa = DeviceFingerprints::of(0x10, a, sizeof(a)), fb = DeviceFingerprints::of(0x10, b, sizeof(b));
    const auto again = DeviceFingerprints::of(0x10, a, sizeof(a)), shorter = DeviceFingerprints::of(0x10, a, sizeof(a) - 1);
    assert(fa.physical == 0x10 && fa.high == again.high && fa.low == again.low);
    assert(fa.high != fb.high && fa.low != fb.low);
    assert(fa.high != shorter.high || fa.low != shorter.low);

    // A device has a fingerprint from its creation until it is destroyed or its executor goes.
    DeviceFingerprints devices;
    DeviceFingerprints::Fingerprint found;
    assert(!devices.find(0x100, &found));
    devices.created(0x100, fa);
    assert(devices.find(0x100, &found) && found.high == fa.high && found.physical == 0x10);
    devices.created(0x100, fb);  // a handle reused by a device made another way
    assert(devices.find(0x100, &found) && found.high == fb.high);
    devices.destroyed(0x100);
    assert(!devices.find(0x100, &found));
    devices.created(0, fa);
    devices.created(0x200, DeviceFingerprints::Fingerprint{});  // no physical device: no scope
    assert(devices.size() == 0);
    for (uint64_t device = 1; device <= DeviceFingerprints::kMaxDevices + 8; ++device) devices.created(device, fa);
    assert(devices.size() == DeviceFingerprints::kMaxDevices);
    devices.destroyed(1);
    devices.created(DeviceFingerprints::kMaxDevices + 100, fb);
    assert(devices.find(DeviceFingerprints::kMaxDevices + 100, &found) && found.high == fb.high);

    // A layout's question holds its flags, bindings and pNext contents.
    VkDescriptorSetLayoutBinding bindings[2] = {
        {0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_VERTEX_BIT, nullptr},
        {1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 16, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr},
    };
    VkDescriptorSetLayoutCreateInfo layout{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, nullptr, 0, 2, bindings};
    std::string first, second;
    assert(layoutQuestion(&layout, &first) && layoutQuestion(&layout, &second) && first == second);
    bindings[1].descriptorCount = 17;
    second.clear(); assert(layoutQuestion(&layout, &second) && first != second);
    bindings[1].descriptorCount = 16;
    layout.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT;
    second.clear(); assert(layoutQuestion(&layout, &second) && first != second);
    layout.flags = 0;

    // Binding flags are part of it, by value.
    VkDescriptorBindingFlags flags[2] = {0, VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT};
    VkDescriptorSetLayoutBindingFlagsCreateInfo bindingFlags{
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, nullptr, 2, flags};
    layout.pNext = &bindingFlags;
    std::string flagged, flaggedAgain;
    assert(layoutQuestion(&layout, &flagged) && flagged != first);
    VkDescriptorBindingFlags copy[2] = {0, VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT};
    bindingFlags.pBindingFlags = copy;  // the same contents elsewhere in memory
    assert(layoutQuestion(&layout, &flaggedAgain) && flagged == flaggedAgain);
    copy[1] = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
    flaggedAgain.clear(); assert(layoutQuestion(&layout, &flaggedAgain) && flagged != flaggedAgain);

    // Mutable descriptor type lists are part of it.
    VkDescriptorType types[2] = {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE};
    VkMutableDescriptorTypeListEXT list{2, types};
    VkMutableDescriptorTypeCreateInfoEXT mutableTypes{VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT, nullptr, 1, &list};
    bindingFlags.pNext = &mutableTypes;
    std::string withTypes, otherTypes;
    assert(layoutQuestion(&layout, &withTypes) && withTypes != flaggedAgain);
    types[1] = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    assert(layoutQuestion(&layout, &otherTypes) && withTypes != otherTypes);

    // A structure of any other kind, or a malformed one, is never asked from the cache.
    VkBaseInStructure unknown{VK_STRUCTURE_TYPE_APPLICATION_INFO, nullptr};
    mutableTypes.pNext = &unknown;
    std::string none; assert(!layoutQuestion(&layout, &none));
    mutableTypes.pNext = nullptr;
    bindingFlags.pBindingFlags = nullptr;
    none.clear(); assert(!layoutQuestion(&layout, &none));
    bindingFlags.pBindingFlags = copy;
    layout.pNext = nullptr;

    // Immutable samplers can carry conversions that change a binding's descriptor count:
    // such layouts are always asked. Other types ignore pImmutableSamplers.
    VkSampler samplers[16] = {};
    bindings[1].pImmutableSamplers = samplers;
    none.clear(); assert(!layoutQuestion(&layout, &none));
    bindings[1].pImmutableSamplers = nullptr;
    bindings[0].pImmutableSamplers = samplers;
    std::string ignored; assert(layoutQuestion(&layout, &ignored) && ignored == first);
    std::puts("device answers: fingerprints, device lifetimes, bounds and layout questions passed");
    return 0;
}
