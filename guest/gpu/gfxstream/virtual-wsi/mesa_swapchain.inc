// SPDX-License-Identifier: MIT
// Included inside caboose_surface; every installed entrypoint requires v4 readiness.
struct Image {
    VkImage image=VK_NULL_HANDLE;
    VkDeviceMemory memory=VK_NULL_HANDLE;
    uint64_t serial=0;
};
// Pipelined acquisition, with ordered presents and the completion feed: after each
// present the next image is acquired on the phone against one of these private
// semaphores, so the application's acquire usually returns at once. A submission then
// hands the private semaphore's signal to the application's semaphore and fence; the
// slot's fence tells when that hand-off ran and the semaphore may be signaled again.
struct AcquireSlot {
    VkSemaphore semaphore=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    bool fenceSubmitted=false;
};
constexpr size_t kAcquireSlots=3;
struct DeviceSwapchain {
    std::shared_ptr<Surface> surface;
    VkDevice device=VK_NULL_HANDLE;
    VkSurfaceKHR surfaceHandle=VK_NULL_HANDLE;
    uint64_t native=0;
    bool retired=false, nativeRetired=false, poisoned=false;
    uint32_t family=UINT32_MAX;
    std::vector<Image> images;
    std::vector<AcquireSlot> slots;
    size_t nextSlot=0;
    uint64_t preRequest=0;          // an acquire made ahead of the application, or 0
    size_t preSlot=0;
    VkQueue handoffQueue=VK_NULL_HANDLE;
};
static std::map<VkSwapchainKHR,std::shared_ptr<DeviceSwapchain>> swapchains;
// 1 when presents are ordered behind device-stream ORDER marks and not waited for
// (hello feature 0x400, SocketStream.cpp).
extern "C" int caboose_gfxstream_ordered_present;
// Frames the phone keeps in flight per surface for ordered presents.
constexpr size_t kOrderedFramesInFlight = 2;
// The result an application sees once an earlier ordered present was not queued: as on
// any WSI, the next present or acquire reports it and the swapchain must be recreated.
static VkResult presentFailureResult(Status s) {
    return s.hasVk && VkResult(s.vk)==VK_ERROR_DEVICE_LOST ? VK_ERROR_DEVICE_LOST : VK_ERROR_OUT_OF_DATE_KHR;
}
static bool orderedPresentFailed(DeviceSwapchain& swap, VkResult* result) {
    if (caboose_gfxstream_ordered_present!=1) return false;
    swap.surface->client.pump();
    Status failure{};
    if (!swap.surface->client.presentFailed(swap.native,&failure)) return false;
    swap.poisoned=true; *result=presentFailureResult(failure);
    return true;
}
static std::shared_ptr<DeviceSwapchain> lookupSwapchain(VkSwapchainKHR handle) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it=swapchains.find(handle); return it==swapchains.end()?nullptr:it->second;
}
static uint32_t presentFamily(const ProviderCaps& caps) {
    uint32_t family=UINT32_MAX;
    for (const auto& queue:caps.queues)
        if (queue[3] && (queue[1]&VK_QUEUE_GRAPHICS_BIT)) family=std::min(family,queue[0]);
    return family;
}
// Whether a slot's last hand-off ran, waiting up to `timeout`. The completion feed answers
// locally; a fence it does not track is asked about on the device stream.
static bool slotHandoffDone(DeviceSwapchain& swap, AcquireSlot& slot, uint64_t timeout) {
    uint64_t key=uint64_t(uintptr_t(slot.fence));
    auto answer=timeout ? caboose::completion::tracker().waitFences(&key,1,true,
                              std::chrono::steady_clock::now()+std::chrono::nanoseconds(timeout))
                        : caboose::completion::tracker().fencesSignaled(&key,1,true);
    if (answer!=caboose::completion::Tracker::Answer::AskDevice)
        return answer==caboose::completion::Tracker::Answer::Satisfied;
    VK_FROM_HANDLE(gfxstream_vk_device, device, swap.device);
    auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
    return encoder->vkWaitForFences(device->internal_object,1,&slot.fence,VK_TRUE,timeout,true)==VK_SUCCESS;
}
static void freeImages(DeviceSwapchain& swap) {
    VK_FROM_HANDLE(gfxstream_vk_device, device, swap.device);
    auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
    auto* tracker=gfxstream::vk::ResourceTracker::get();
    for (auto& slot:swap.slots) {
        // A hand-off still running keeps its fence and semaphore.
        if (slot.fenceSubmitted && !slotHandoffDone(swap,slot,10'000'000'000ull)) continue;
        if (slot.semaphore) tracker->on_vkDestroySemaphore(encoder,device->internal_object,slot.semaphore,nullptr);
        if (slot.fence) tracker->on_vkDestroyFence(encoder,device->internal_object,slot.fence,nullptr);
        slot={};
    }
    for (auto& image:swap.images) {
        if (image.image) {
            tracker->on_vkDestroyImage(encoder,device->internal_object,image.image,nullptr);
            image.image=VK_NULL_HANDLE;
        }
        if (image.memory) {
            tracker->on_vkFreeMemory(encoder,device->internal_object,image.memory,nullptr);
            image.memory=VK_NULL_HANDLE;
        }
    }
}
// Acquisition ahead of the application needs the completion feed for its slot fences and
// a single encoder, so the device stream that created a slot's semaphore is the one the
// application's work follows.
static bool pipelinedAcquire(const DeviceSwapchain& swap) {
    return caboose_gfxstream_ordered_present==1 && swap.handoffQueue && swap.slots.size()==kAcquireSlots &&
           caboose::completion::feedActive.load(std::memory_order_acquire) &&
           caboose::memory::deferredReplies.singleEncoder(gfxstream::vk::ResourceTracker::getThreadLocalEncoder());
}
// Creates the private acquire semaphores and fences, before the phone maps the swapchain,
// and picks a queue of the presentation family for the hand-off submissions. Without
// them acquisition stays synchronous.
static void createAcquireSlots(DeviceSwapchain& swap) {
    if (caboose_gfxstream_ordered_present!=1) return;
    VK_FROM_HANDLE(gfxstream_vk_device, device, swap.device);
    for (uint32_t i=0;i<device->queue_count;++i)
        if (device->queues[i].vk.queue_family_index==swap.family) { swap.handoffQueue=device->queues[i].internal_object; break; }
    if (!swap.handoffQueue) return;
    auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
    auto* tracker=gfxstream::vk::ResourceTracker::get();
    VkSemaphoreCreateInfo semaphoreInfo{}; semaphoreInfo.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo fenceInfo{}; fenceInfo.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    for (size_t i=0;i<kAcquireSlots;++i) {
        AcquireSlot slot;
        if (tracker->on_vkCreateSemaphore(encoder,VK_SUCCESS,device->internal_object,&semaphoreInfo,nullptr,&slot.semaphore)!=VK_SUCCESS ||
            tracker->on_vkCreateFence(encoder,VK_SUCCESS,device->internal_object,&fenceInfo,nullptr,&slot.fence)!=VK_SUCCESS) {
            swap.slots.push_back(slot);  // destroyed with the images
            swap.handoffQueue=VK_NULL_HANDLE;
            return;
        }
        swap.slots.push_back(slot);
    }
}
// Acquires the next image ahead of the application, when a slot is free.
static void startPreAcquire(DeviceSwapchain& swap) {
    auto& surface=*swap.surface;
    if (!pipelinedAcquire(swap) || swap.preRequest || swap.retired || swap.poisoned ||
        surface.client.revoked() || surface.client.failed() || surface.query==UINT64_MAX) return;
    const size_t index=swap.nextSlot%kAcquireSlots;
    auto& slot=swap.slots[index];
    if (slot.fenceSubmitted) {
        // The slot's semaphore is free again only once its previous hand-off ran.
        if (!slotHandoffDone(swap,slot,0)) return;
        VK_FROM_HANDLE(gfxstream_vk_device, device, swap.device);
        auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
        if (gfxstream::vk::ResourceTracker::get()->on_vkResetFences(encoder,VK_SUCCESS,device->internal_object,1,&slot.fence)!=VK_SUCCESS)
            return;
        slot.fenceSubmitted=false;
    }
    const uint64_t request=++surface.query;
    surface.client.beginAcquire(swap.native,request,get_host_u64_VkSemaphore(slot.semaphore),0,UINT64_MAX,deadline());
    swap.preRequest=request; swap.preSlot=index; ++swap.nextSlot;
}
// Ends an acquire made ahead of the application before the swapchain retires. An image it
// acquired stays acquired and unused, which native retirement releases.
static void cancelPreAcquire(DeviceSwapchain& swap) {
    if (!swap.preRequest) return;
    auto& client=swap.surface->client;
    client.cancelAcquire(swap.native,swap.preRequest,deadline());
    client.finishAcquire(swap.native,swap.preRequest,deadline());
    swap.preRequest=0;
}
static bool retireSwapchain(DeviceSwapchain& swap) {
    if (swap.retired) return true;
    try {
        auto& client=swap.surface->client;
        if (!swap.nativeRetired && !client.retired()) {
            // An uncertain CREATE may have allocated remotely without returning its ID.
            if (!swap.native) return false;
            cancelPreAcquire(swap);
            auto result=client.retireSwapchain(swap.native,deadline());
            if (apiStatus(status(result.body,48))!=VK_SUCCESS) return false;
        }
        // Actual swapchain or entire-surface retirement precedes source destruction.
        swap.nativeRetired=true; freeImages(swap); swap.retired=true; return true;
    } catch (...) { swap.poisoned=true; return false; }
}
static VkResult VKAPI_CALL createSwapchain(VkDevice handle, const VkSwapchainCreateInfoKHR* info,
    const VkAllocationCallbacks*, VkSwapchainKHR* out) {
    return guarded([&]() -> VkResult {
        if (!indexed() || !info || !out) return VK_ERROR_INITIALIZATION_FAILED;
        if (info->sType!=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR)
            return VK_ERROR_EXTENSION_NOT_PRESENT;
        for (auto* ext=static_cast<const VkBaseInStructure*>(info->pNext); ext; ext=ext->pNext) {
            if (ext->sType!=VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO)
                return VK_ERROR_EXTENSION_NOT_PRESENT;
        }
        auto surface=lookup(info->surface); if (!surface) return VK_ERROR_SURFACE_LOST_KHR;
        std::lock_guard<std::recursive_mutex> operation(surface->operationMutex);
        if (surface->client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
        if (surface->client.failed()) return apiStatus(surface->client.failure());
        if (info->oldSwapchain) {
            auto previous=lookupSwapchain(info->oldSwapchain);
            if (!previous || previous->surface!=surface || previous->device!=handle || previous->retired)
                return VK_ERROR_INITIALIZATION_FAILED;
            if (!previous->nativeRetired && !surface->client.retired()) {
                if (!previous->native) return VK_ERROR_INITIALIZATION_FAILED;
                cancelPreAcquire(*previous);
                surface->client.waitPresentationIdle(deadline());
                auto retired=surface->client.retireSwapchain(previous->native,deadline());
                auto retiredResult=apiStatus(status(retired.body,48));
                if (retiredResult!=VK_SUCCESS) return retiredResult;
                previous->nativeRetired=true;
            }
        }
        VK_FROM_HANDLE(gfxstream_vk_device, device, handle);
        auto physical=gfxstream_vk_physical_device_to_handle(device->physical_device);
        Bytes raw; auto result=query(physical,info->surface,raw); if (result!=VK_SUCCESS) return result;
        auto caps=providerCaps(raw);
        auto swap=std::make_shared<DeviceSwapchain>();
        swap->device=handle; swap->surface=surface; swap->surfaceHandle=info->surface;
        swap->family=presentFamily(caps);
        bool queueExists=false;
        for (uint32_t i=0;i<device->queue_family_count;++i)
            if (device->queue_families[i]==swap->family) queueExists=true;
        if (!queueExists) return VK_ERROR_INITIALIZATION_FAILED;
        uint64_t old=0;
        // Native receives every base creation field and rejects unsupported values.
        if (surface->query==UINT64_MAX) return VK_ERROR_INITIALIZATION_FAILED;
        Bytes request; put64(request,++surface->query);
        put64(request,get_host_u64_VkDevice(device->internal_object)); put64(request,old);
        for (uint32_t word:{info->flags,info->minImageCount,uint32_t(info->imageFormat),uint32_t(info->imageColorSpace),
             info->imageExtent.width,info->imageExtent.height,info->imageArrayLayers,info->imageUsage,
             uint32_t(info->preTransform),uint32_t(info->compositeAlpha),uint32_t(info->presentMode),info->clipped,
             uint32_t(info->imageSharingMode),info->imageSharingMode==VK_SHARING_MODE_EXCLUSIVE?0:info->queueFamilyIndexCount})
            put32(request,word);
        if (info->imageSharingMode==VK_SHARING_MODE_CONCURRENT) {
            if (info->queueFamilyIndexCount>64 || !info->pQueueFamilyIndices) return VK_ERROR_INITIALIZATION_FAILED;
            for (uint32_t i=0;i<info->queueFamilyIndexCount;++i) put32(request,info->pQueueFamilyIndices[i]);
        }
        // Register before CREATE itself: a lost reply still prevents device destruction.
        auto guestHandle=reinterpret_cast<VkSwapchainKHR>(swap.get());
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (swapchains.size()>=64) return VK_ERROR_OUT_OF_HOST_MEMORY;
            swapchains.emplace(guestHandle,swap);
        }
        auto created=surface->client.createSwapchain(request,deadline());
        result=apiStatus(status(created.body,56));
        if (result!=VK_SUCCESS) {
            std::lock_guard<std::mutex> lock(mutex); swapchains.erase(guestHandle); return result;
        }
        swap->native=u64(created.body,48);
        auto cleanup=[&](VkResult failure) {
            if (retireSwapchain(*swap)) {
                std::lock_guard<std::mutex> lock(mutex); swapchains.erase(guestHandle);
            }
            return failure;
        };
        try {
            swap->images.resize(u32(created.body,72));
            auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
            VkPhysicalDeviceMemoryProperties memory{};
            encoder->vkGetPhysicalDeviceMemoryProperties(device->physical_device->internal_object,&memory,true);
            if (!memory.memoryTypeCount || memory.memoryTypeCount>VK_MAX_MEMORY_TYPES)
                return cleanup(VK_ERROR_INITIALIZATION_FAILED);
            VkImageCreateInfo imageInfo{}; imageInfo.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            imageInfo.imageType=VK_IMAGE_TYPE_2D; imageInfo.format=info->imageFormat;
            imageInfo.extent={info->imageExtent.width,info->imageExtent.height,1};
            imageInfo.mipLevels=1; imageInfo.arrayLayers=info->imageArrayLayers; imageInfo.samples=VK_SAMPLE_COUNT_1_BIT;
            imageInfo.tiling=VK_IMAGE_TILING_OPTIMAL; imageInfo.usage=info->imageUsage|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
            imageInfo.sharingMode=info->imageSharingMode;
            if (info->imageSharingMode==VK_SHARING_MODE_CONCURRENT) {
                imageInfo.queueFamilyIndexCount=info->queueFamilyIndexCount;
                imageInfo.pQueueFamilyIndices=info->pQueueFamilyIndices;
            }
            VkImageFormatProperties formatProperties{};
            result=encoder->vkGetPhysicalDeviceImageFormatProperties(device->physical_device->internal_object,
                imageInfo.format,imageInfo.imageType,imageInfo.tiling,imageInfo.usage,0,&formatProperties,true);
            if (result!=VK_SUCCESS) return cleanup(result);
            if (imageInfo.extent.width>formatProperties.maxExtent.width ||
                imageInfo.extent.height>formatProperties.maxExtent.height ||
                imageInfo.arrayLayers>formatProperties.maxArrayLayers ||
                !(formatProperties.sampleCounts&VK_SAMPLE_COUNT_1_BIT)) return cleanup(VK_ERROR_FORMAT_NOT_SUPPORTED);
            std::vector<uint64_t> images;
            for (auto& image:swap->images) {
                result=gfxstream::vk::ResourceTracker::get()->on_vkCreateImage(encoder,VK_SUCCESS,
                    device->internal_object,&imageInfo,nullptr,&image.image);
                if (result!=VK_SUCCESS) return cleanup(result);
                VkMemoryDedicatedRequirements dedicated{}; dedicated.sType=VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS;
                VkMemoryRequirements2 returned{}; returned.sType=VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2; returned.pNext=&dedicated;
                VkImageMemoryRequirementsInfo2 queryInfo{}; queryInfo.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2;
                queryInfo.image=image.image;
                encoder->vkGetImageMemoryRequirements2(device->internal_object,&queryInfo,&returned,true);
                auto requirements=returned.memoryRequirements;
                uint32_t type=0;
                while (type<memory.memoryTypeCount &&
                    (!(requirements.memoryTypeBits&(1u<<type)) ||
                     (memory.memoryTypes[type].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)))) ++type;
                if (type==memory.memoryTypeCount) return cleanup(VK_ERROR_FEATURE_NOT_PRESENT);
                VkMemoryAllocateInfo allocate{}; allocate.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
                allocate.allocationSize=requirements.size; allocate.memoryTypeIndex=type;
                VkMemoryDedicatedAllocateInfo allocationImage{}; allocationImage.sType=VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
                allocationImage.image=image.image;
                if (dedicated.requiresDedicatedAllocation || dedicated.prefersDedicatedAllocation) allocate.pNext=&allocationImage;
                result=gfxstream::vk::ResourceTracker::get()->on_vkAllocateMemory(encoder,VK_SUCCESS,
                    device->internal_object,&allocate,nullptr,&image.memory);
                if (result!=VK_SUCCESS) return cleanup(result);
                result=encoder->vkBindImageMemory(device->internal_object,image.image,image.memory,0,true);
                if (result!=VK_SUCCESS) return cleanup(result);
                images.push_back(get_host_u64_VkImage(image.image));
            }
            createAcquireSlots(*swap);
            // The phone maps images, and later signals acquire semaphores, this device
            // stream created, allocated and bound.
            if (!encoder->cabooseDrainDeferredObjects(true)) return cleanup(VK_ERROR_DEVICE_LOST);
            auto mapped=surface->client.mapSwapchain(swap->native,images,deadline());
            result=apiStatus(status(mapped.body,48)); if (result!=VK_SUCCESS) return cleanup(result);
            *out=guestHandle; return VK_SUCCESS;
        } catch (...) { cleanup(VK_ERROR_INITIALIZATION_FAILED); throw; }
    });
}
static void VKAPI_CALL destroySwapchain(VkDevice device, VkSwapchainKHR handle, const VkAllocationCallbacks*) {
    try {
    auto swap=lookupSwapchain(handle); if (!swap || swap->device!=device) return;
    std::lock_guard<std::recursive_mutex> operation(swap->surface->operationMutex);
    if (!retireSwapchain(*swap)) return;
    std::lock_guard<std::mutex> lock(mutex); swapchains.erase(handle);
    } catch (...) { /* Keep the native and source reservations on uncertain teardown. */ }
}
static bool beforeDestroyDevice(VkDevice device) {
    try {
    std::vector<std::pair<VkSwapchainKHR,std::shared_ptr<DeviceSwapchain>>> retained;
    { std::lock_guard<std::mutex> lock(mutex);
      for (auto& pair:swapchains) if (pair.second->device==device) retained.push_back(pair); }
    for (auto& pair:retained) {
        std::lock_guard<std::recursive_mutex> operation(pair.second->surface->operationMutex);
        if (!retireSwapchain(*pair.second)) return false;
    }
    { std::lock_guard<std::mutex> lock(mutex); for (auto& pair:retained) swapchains.erase(pair.first); }
    return true;
    } catch (...) { return false; }
}
static VkResult VKAPI_CALL getImages(VkDevice device, VkSwapchainKHR handle, uint32_t* count, VkImage* images) {
    return guarded([&]() -> VkResult {
    auto swap=lookupSwapchain(handle);
    if (!swap || swap->device!=device || !count) return VK_ERROR_INITIALIZATION_FAILED;
    std::lock_guard<std::recursive_mutex> operation(swap->surface->operationMutex);
    if (swap->retired || swap->poisoned) return VK_ERROR_OUT_OF_DATE_KHR;
    uint32_t total=swap->images.size(), copied=images?std::min(*count,total):total;
    if (images) for (uint32_t i=0;i<copied;++i) images[i]=swap->images[i].image;
    *count=copied; return copied<total?VK_INCOMPLETE:VK_SUCCESS;
    });
}
// Once the executor is gone, a failed acquire or present is device loss: the application
// recreates its instance and finds whichever executor exists, as after any lost device.
static VkResult executorResult(VkResult result) {
    return result<0 && caboose::completion::executorLost.load(std::memory_order_acquire) ? VK_ERROR_DEVICE_LOST
                                                                                         : result;
}
static VkResult VKAPI_CALL acquireImage(VkDevice device, VkSwapchainKHR handle, uint64_t timeout,
    VkSemaphore semaphore, VkFence fence, uint32_t* index) {
    if (caboose::completion::executorLost.load(std::memory_order_acquire)) return VK_ERROR_DEVICE_LOST;
    return executorResult(guarded([&]() -> VkResult {
        auto swap=lookupSwapchain(handle);
        if (!swap || swap->device!=device || !index || (!semaphore && !fence)) return VK_ERROR_INITIALIZATION_FAILED;
        auto& surface=*swap->surface;
        std::lock_guard<std::recursive_mutex> operation(surface.operationMutex);
        VkResult late=VK_SUCCESS;
        if (orderedPresentFailed(*swap,&late)) return late;
        if (swap->retired || swap->poisoned || surface.client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
        if (surface.client.failed()) return apiStatus(surface.client.failure());
        uint64_t boxedSemaphore=0, boxedFence=0;
        VkSemaphore internalSemaphore=VK_NULL_HANDLE;
        VkFence internalFence=VK_NULL_HANDLE;
        if (semaphore) {
            VK_FROM_HANDLE(gfxstream_vk_semaphore, value, semaphore);
            if (value->vk.base.device!=&gfxstream_vk_device_from_handle(device)->vk ||
                value->vk.type!=VK_SEMAPHORE_TYPE_BINARY || value->vk.temporary) return VK_ERROR_INITIALIZATION_FAILED;
            internalSemaphore=value->internal_object;
            boxedSemaphore=get_host_u64_VkSemaphore(value->internal_object);
        }
        if (fence) {
            VK_FROM_HANDLE(gfxstream_vk_fence, value, fence);
            if (value->vk.base.device!=&gfxstream_vk_device_from_handle(device)->vk || value->vk.temporary)
                return VK_ERROR_INITIALIZATION_FAILED;
            internalFence=value->internal_object;
            boxedFence=get_host_u64_VkFence(value->internal_object);
        }
        if (swap->preRequest) {
            // The image was acquired ahead of time against a private semaphore: wait as
            // long as the application allows. The phone's acquire has no timeout of its
            // own, so an unanswered one stays outstanding for the next call. Long timeouts
            // are waited for a day at a time, keeping deadlines representable.
            constexpr uint64_t kDay=86400ull*1000000000ull;
            uint64_t remaining=timeout;
            for (;;) {
                const uint64_t chunk=std::min(remaining,kDay);
                if (surface.client.awaitAcquireReply(swap->native,
                        std::chrono::steady_clock::now()+std::chrono::nanoseconds(chunk))) break;
                // A revoked surface answers nothing more: recreate, as with any WSI.
                if (surface.client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
                if (timeout!=UINT64_MAX) remaining-=chunk;
                if (!remaining) return timeout==0 ? VK_NOT_READY : VK_TIMEOUT;
            }
            auto reply=surface.client.finishAcquire(swap->native,swap->preRequest,deadline());
            const size_t slotIndex=swap->preSlot;
            swap->preRequest=0;
            auto returned=status(reply.body,56);
            if (returned.nativeError) return VK_ERROR_SURFACE_LOST_KHR;
            auto result=VkResult(returned.vk);
            if (result!=VK_SUCCESS && result!=VK_SUBOPTIMAL_KHR) return result;
            uint32_t acquired=u32(reply.body,76);
            auto& image=swap->images.at(acquired);
            if (image.serial) {
                surface.client.waitReleased(image.serial,deadline());
                if (surface.client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
                surface.client.consumeRelease(image.serial); image.serial=0;
            }
            // Hand the private semaphore's signal to the application's semaphore and fence.
            auto& slot=swap->slots[slotIndex];
            auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
            auto* tracker=gfxstream::vk::ResourceTracker::get();
            const VkPipelineStageFlags stage=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            VkSubmitInfo handoff{}; handoff.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
            handoff.waitSemaphoreCount=1; handoff.pWaitSemaphores=&slot.semaphore; handoff.pWaitDstStageMask=&stage;
            handoff.signalSemaphoreCount=internalSemaphore ? 1 : 0; handoff.pSignalSemaphores=&internalSemaphore;
            if (tracker->on_vkQueueSubmit(encoder,VK_SUCCESS,swap->handoffQueue,1,&handoff,slot.fence)!=VK_SUCCESS)
                return VK_ERROR_DEVICE_LOST;
            slot.fenceSubmitted=true;
            // An empty batch's fence signals once the hand-off before it completed.
            if (internalFence &&
                tracker->on_vkQueueSubmit(encoder,VK_SUCCESS,swap->handoffQueue,0,nullptr,internalFence)!=VK_SUCCESS)
                return VK_ERROR_DEVICE_LOST;
            *index=acquired;
            return result;
        }
        // The presentation engine signals this fence: the guest asks the device about it.
        if (internalFence) caboose::completion::tracker().fenceUntracked(uint64_t(uintptr_t(internalFence)));
        if (surface.query==UINT64_MAX) return VK_ERROR_INITIALIZATION_FAILED;
        uint64_t request=++surface.query;
        // The phone signals a semaphore and fence the device stream created.
        if (!gfxstream::vk::ResourceTracker::getThreadLocalEncoder()->cabooseDrainDeferredObjects(true))
            return VK_ERROR_DEVICE_LOST;
        surface.client.beginAcquire(swap->native,request,boxedSemaphore,boxedFence,timeout,deadline());
        // A transport deadline is never relabelled as a Vulkan acquire timeout.
        auto reply=surface.client.finishAcquire(swap->native,request,deadline());
        auto returned=status(reply.body,56);
        if (u32(reply.body,80)==1 && timeout!=0 && timeout!=UINT64_MAX) return VK_TIMEOUT;
        if (returned.nativeError) return VK_ERROR_SURFACE_LOST_KHR;
        auto result=VkResult(returned.vk);
        if (result==VK_SUCCESS || result==VK_SUBOPTIMAL_KHR) {
            uint32_t acquired=u32(reply.body,76);
            auto& image=swap->images.at(acquired);
            if (image.serial) {
                surface.client.waitReleased(image.serial,deadline());
                if (surface.client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
                surface.client.consumeRelease(image.serial); image.serial=0;
            }
            *index=acquired;
        }
        return result;
    }));
}
static VkResult VKAPI_CALL acquireImage2(VkDevice device, const VkAcquireNextImageInfoKHR* info, uint32_t* index) {
    if (!info || info->sType!=VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR || info->pNext || info->deviceMask!=1)
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    return acquireImage(device,info->swapchain,info->timeout,info->semaphore,info->fence,index);
}
static VkResult VKAPI_CALL present(VkQueue handle, const VkPresentInfoKHR* info) {
    if (caboose::completion::executorLost.load(std::memory_order_acquire)) {
        if (info && info->swapchainCount==1 && info->pResults) info->pResults[0]=VK_ERROR_DEVICE_LOST;
        return VK_ERROR_DEVICE_LOST;
    }
    auto overall=guarded([&]() -> VkResult {
        // Shared waits across multiple swapchains require an atomic native transaction.
        if (!info || info->sType!=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR || info->pNext ||
            info->swapchainCount!=1 || !info->pSwapchains || !info->pImageIndices || info->waitSemaphoreCount>64)
            return VK_ERROR_INITIALIZATION_FAILED;
        VK_FROM_HANDLE(gfxstream_vk_queue, queue, handle);
        auto swap=lookupSwapchain(info->pSwapchains[0]);
        if (!swap || swap->device!=gfxstream_vk_device_to_handle(queue->device)) return VK_ERROR_INITIALIZATION_FAILED;
        std::lock_guard<std::recursive_mutex> operation(swap->surface->operationMutex);
        VkResult late=VK_SUCCESS;
        if (orderedPresentFailed(*swap,&late)) return late;
        if (swap->poisoned || swap->retired || swap->surface->client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
        if (swap->surface->client.failed()) return apiStatus(swap->surface->client.failure());
        if (queue->vk.queue_family_index!=swap->family) return VK_ERROR_INITIALIZATION_FAILED;
        uint32_t index=info->pImageIndices[0];
        if (index>=swap->images.size() || (info->waitSemaphoreCount && !info->pWaitSemaphores))
            return VK_ERROR_INITIALIZATION_FAILED;
        std::vector<uint64_t> waits;
        for (uint32_t i=0;i<info->waitSemaphoreCount;++i) {
            VK_FROM_HANDLE(gfxstream_vk_semaphore, value, info->pWaitSemaphores[i]);
            if (!value || value->vk.base.device!=&queue->device->vk || value->vk.type!=VK_SEMAPHORE_TYPE_BINARY ||
                value->vk.temporary) return VK_ERROR_INITIALIZATION_FAILED;
            waits.push_back(get_host_u64_VkSemaphore(value->internal_object));
        }
        auto& surface=*swap->surface;
        // Native capacity is one frame per surface, two with ordered presents; only a
        // frame's final retirement callback opens the next admission. No guest wait
        // semaphore is touched.
        if (caboose_gfxstream_ordered_present==1) surface.client.waitPresentationRoom(kOrderedFramesInFlight,deadline());
        else surface.client.waitPresentationIdle(deadline());
        if (surface.client.revoked()) return VK_ERROR_OUT_OF_DATE_KHR;
        if (surface.client.failed()) return apiStatus(surface.client.failure());
        if (surface.presentSerial==UINT64_MAX) return VK_ERROR_INITIALIZATION_FAILED;
        uint64_t serial=++surface.presentSerial;
        if (caboose_gfxstream_ordered_present==1) {
            // The phone runs this present only after decoding everything the device stream
            // sent before the mark: no round trip, and its result is checked later.
            auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
            const uint64_t order=encoder->cabooseSendOrderMark(true);
            if (order) {
                surface.client.presentOrdered(swap->native,serial,get_host_u64_VkQueue(queue->internal_object),
                    order,index,swap->family,waits,deadline());
                swap->images[index].serial=serial;
                startPreAcquire(*swap);
                if (info->pResults) info->pResults[0]=VK_SUCCESS;
                return VK_SUCCESS;
            }
        }
        // The phone presents on the queue after the work, and waits for the semaphores,
        // the device stream submitted.
        if (!gfxstream::vk::ResourceTracker::getThreadLocalEncoder()->cabooseDrainDeferredObjects(true))
            return VK_ERROR_DEVICE_LOST;
        auto reply=surface.client.presentIndexed(swap->native,serial,
            get_host_u64_VkQueue(queue->internal_object),index,swap->family,waits,deadline());
        auto result=apiStatus(status(reply.body,48));
        if (u32(reply.body,64)==1) swap->images[index].serial=serial;
        else { swap->poisoned=true; if (result==VK_SUCCESS) result=VK_ERROR_SURFACE_LOST_KHR; }
        if (info->pResults) info->pResults[0]=result;
        return result;
    });
    overall=executorResult(overall);
    if (info && info->swapchainCount==1 && info->pResults) info->pResults[0]=overall;
    return overall;
}
static void install(vk_device_dispatch_table& table) {
    if (!indexed()) return;
    table.CreateSwapchainKHR=createSwapchain; table.DestroySwapchainKHR=destroySwapchain;
    table.GetSwapchainImagesKHR=getImages; table.AcquireNextImageKHR=acquireImage;
    table.AcquireNextImage2KHR=acquireImage2; table.QueuePresentKHR=present;
    table.GetDeviceGroupPresentCapabilitiesKHR=[](VkDevice, VkDeviceGroupPresentCapabilitiesKHR*) -> VkResult {
        return VK_ERROR_FEATURE_NOT_PRESENT;
    };
    table.GetDeviceGroupSurfacePresentModesKHR=[](VkDevice, VkSurfaceKHR, VkDeviceGroupPresentModeFlagsKHR*) -> VkResult {
        return VK_ERROR_FEATURE_NOT_PRESENT;
    };
}
