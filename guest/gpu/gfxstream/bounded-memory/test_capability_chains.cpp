// SPDX-License-Identifier: MIT
#include "capability_chains.h"
#include <cassert>
#include <cstdio>
using namespace caboose::memory;

// Two extension structures the test knows the sizes of; anything else is unknown.
static size_t sizes(VkStructureType, const void* extension) {
    switch (static_cast<const VkBaseInStructure*>(extension)->sType) {
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES: return sizeof(VkPhysicalDeviceIDProperties);
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES: return sizeof(VkPhysicalDeviceDriverProperties);
    case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_PROPERTIES: return sizeof(VkPhysicalDeviceVulkan14Properties);
    default: return 0;
    }
}

int main() {
    const auto root = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    VkPhysicalDeviceDriverProperties driver{}; driver.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
    VkPhysicalDeviceIDProperties id{}; id.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES; id.pNext = &driver;
    VkPhysicalDeviceProperties2 asked{}; asked.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2; asked.pNext = &id;
    asked.properties.apiVersion = 77; id.deviceUUID[3] = 9; std::snprintf(driver.driverName, sizeof(driver.driverName), "driver");

    std::string shape;
    assert(chainShape(root, &asked, sizeof(asked), sizes, &shape));
    assert(shape.size() == 3 * 8);
    const std::string answer = chainSave(root, &asked, sizeof(asked), sizes);
    assert(answer.size() == sizeof(asked) + sizeof(id) + sizeof(driver) - 3 * sizeof(VkBaseOutStructure));

    // The same shape in another process's memory: answers land, sType and pNext stay.
    VkPhysicalDeviceDriverProperties driver2{}; driver2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
    VkPhysicalDeviceIDProperties id2{}; id2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES; id2.pNext = &driver2;
    VkPhysicalDeviceProperties2 again{}; again.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2; again.pNext = &id2;
    std::string shape2;
    assert(chainShape(root, &again, sizeof(again), sizes, &shape2) && shape2 == shape);
    assert(chainLoad(root, &again, sizeof(again), sizes, answer));
    assert(again.properties.apiVersion == 77 && id2.deviceUUID[3] == 9 && std::string(driver2.driverName) == "driver");
    assert(again.pNext == &id2 && id2.pNext == &driver2 && id2.sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES);

    // Another order is another shape, and a short answer fills nothing.
    VkPhysicalDeviceIDProperties id3{}; id3.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
    VkPhysicalDeviceDriverProperties driver3{}; driver3.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES; driver3.pNext = &id3;
    VkPhysicalDeviceProperties2 swapped{}; swapped.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2; swapped.pNext = &driver3;
    std::string shape3;
    assert(chainShape(root, &swapped, sizeof(swapped), sizes, &shape3) && shape3 != shape);
    VkPhysicalDeviceProperties2 alone{}; alone.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    assert(!chainLoad(root, &alone, sizeof(alone), sizes, answer) && alone.properties.apiVersion == 0);

    // Unknown structures and structures holding application pointers are never cached.
    VkPhysicalDeviceMaintenance3Properties unknown{}; unknown.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES;
    VkPhysicalDeviceProperties2 withUnknown{}; withUnknown.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2; withUnknown.pNext = &unknown;
    std::string ignored;
    assert(!chainShape(root, &withUnknown, sizeof(withUnknown), sizes, &ignored));
    // A layout list is cached only while its arrays are not given: then it asks only counts.
    VkPhysicalDeviceVulkan14Properties pointers{}; pointers.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_PROPERTIES;
    VkPhysicalDeviceProperties2 withPointers{}; withPointers.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2; withPointers.pNext = &pointers;
    std::string counts;
    assert(chainShape(root, &withPointers, sizeof(withPointers), sizes, &counts));
    VkImageLayout layouts[4] = {};
    pointers.pCopySrcLayouts = layouts; pointers.copySrcLayoutCount = 4;
    assert(!chainShape(root, &withPointers, sizeof(withPointers), sizes, &ignored));
    pointers.pCopySrcLayouts = nullptr; pointers.pCopyDstLayouts = layouts;
    assert(!chainShape(root, &withPointers, sizeof(withPointers), sizes, &ignored));
    std::puts("capability chains: shapes, answers, order, sizes, unknown, pointer-holding and count-only structures passed");
}
