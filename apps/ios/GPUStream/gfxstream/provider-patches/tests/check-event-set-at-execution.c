// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The MoltenVK event patch (moltenvk-event-set-at-execution.patch): a vkCmdSetEvent submitted
// while the event is set, held by a timeline wait until the host has reset the event, must
// leave it set once the GPU reaches it; as must DXVK's order (host reset, record, submit).
// Exit 0 when every case sets within a second. Against a stock MoltenVK 1.4.2 the held case
// fails. Build on a Mac against the MoltenVK to check (see provider-patches/README).
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <unistd.h>
#define CK(x) do { VkResult r_ = (x); if (r_) { printf("%s = %d\n", #x, r_); return 2; } } while (0)
static VkDevice dev; static VkQueue q; static VkCommandPool pool;
static int setWithin(VkEvent e) {
    for (int i = 0; i < 1000; ++i) { if (vkGetEventStatus(dev, e) == VK_EVENT_SET) return 1; usleep(1000); }
    return 0;
}
static void submitSet(VkEvent e, int v2, VkSemaphore hold, uint64_t value) {
    VkCommandBufferAllocateInfo ai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, 0, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &ai, &cb);
    VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, 0, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cb, &bi);
    if (v2) {
        VkMemoryBarrier2 mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER_2, 0, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, 0,
                               VK_PIPELINE_STAGE_2_HOST_BIT, VK_ACCESS_2_HOST_READ_BIT};
        VkDependencyInfo di = {VK_STRUCTURE_TYPE_DEPENDENCY_INFO, 0, 0, 1, &mb};
        vkCmdSetEvent2(cb, e, &di);
    } else {
        vkCmdSetEvent(cb, e, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
    }
    vkEndCommandBuffer(cb);
    VkTimelineSemaphoreSubmitInfo tsi = {VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
    tsi.waitSemaphoreValueCount = 1; tsi.pWaitSemaphoreValues = &value;
    const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1; si.pCommandBuffers = &cb;
    if (hold) { si.pNext = &tsi; si.waitSemaphoreCount = 1; si.pWaitSemaphores = &hold; si.pWaitDstStageMask = &stage; }
    vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE);
}
int main(void) {
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion = VK_API_VERSION_1_3;
    const char* ext[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app; ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = ext;
    VkInstance inst; CK(vkCreateInstance(&ici, 0, &inst));
    uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
    float pr = 1; VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, 0, 1, &pr};
    VkPhysicalDeviceVulkan12Features f12 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; f12.timelineSemaphore = 1;
    VkPhysicalDeviceVulkan13Features f13 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, &f12}; f13.synchronization2 = 1;
    const char* dext[] = {"VK_KHR_portability_subset"};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dci.pNext = &f13;
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci; dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = dext;
    CK(vkCreateDevice(pd, &dci, 0, &dev)); vkGetDeviceQueue(dev, 0, 0, &q);
    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; CK(vkCreateCommandPool(dev, &pci, 0, &pool));
    VkEventCreateInfo eci = {VK_STRUCTURE_TYPE_EVENT_CREATE_INFO}; VkEvent e; CK(vkCreateEvent(dev, &eci, 0, &e));
    VkSemaphoreTypeCreateInfo sti = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, 0, VK_SEMAPHORE_TYPE_TIMELINE, 0};
    VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, &sti};
    VkSemaphore hold; CK(vkCreateSemaphore(dev, &sci, 0, &hold));
    int failed = 0;
    uint64_t gate = 0;
    for (int v2 = 0; v2 < 2; ++v2) {
        // DXVK's order: host reset, record and submit the set, poll.
        vkResetEvent(dev, e); submitSet(e, v2, VK_NULL_HANDLE, 0);
        int ok = setWithin(e); failed |= !ok;
        printf("%s vkCmdSetEvent%s reset-then-submit\n", ok ? "PASS" : "FAIL", v2 ? "2" : "");
        // Submitted while set, held until the host reset is done.
        ++gate; submitSet(e, v2, hold, gate); vkResetEvent(dev, e);
        VkSemaphoreSignalInfo signal = {VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO, 0, hold, gate};
        vkSignalSemaphore(dev, &signal);
        ok = setWithin(e); failed |= !ok;
        printf("%s vkCmdSetEvent%s submit-then-reset\n", ok ? "PASS" : "FAIL", v2 ? "2" : "");
        // A host reset after the device set is a reset.
        vkDeviceWaitIdle(dev); vkResetEvent(dev, e);
        ok = vkGetEventStatus(dev, e) == VK_EVENT_RESET; failed |= !ok;
        printf("%s vkCmdSetEvent%s reset-after-set\n", ok ? "PASS" : "FAIL", v2 ? "2" : "");
        vkSetEvent(dev, e);
    }
    vkDeviceWaitIdle(dev);
    return failed;
}
