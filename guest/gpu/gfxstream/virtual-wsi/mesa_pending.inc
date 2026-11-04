// SPDX-License-Identifier: MIT
// Included in caboose_surface after the synchronous compatibility path. Only copied
// protocol IDs are used by the pump; guest wrappers are used on API threads only.
static VkResult preparePendingSwapchain(DeviceSwapchain& swap) {
    VK_FROM_HANDLE(gfxstream_vk_device, device, swap.device);
    swap.hostDevice=get_host_u64_VkDevice(device->internal_object);
    swap.hostPhysical=get_host_u64_VkPhysicalDevice(device->physical_device->internal_object);
    auto* tracker=gfxstream::vk::ResourceTracker::get();
    auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
    std::vector<Retirement::Key> objects{{Retirement::Kind::Device,swap.hostDevice}};
    for (auto& image:swap.images) {
        VkSemaphoreCreateInfo info{}; info.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        auto result=tracker->on_vkCreateSemaphore(encoder,VK_SUCCESS,device->internal_object,
                                                  &info,nullptr,&image.presentWait);
        if (result!=VK_SUCCESS) return result;
        auto hostImage=get_host_u64_VkImage(image.image);
        swap.hostImages.push_back(hostImage);
        objects.push_back({Retirement::Kind::Image,hostImage});
        objects.push_back({Retirement::Kind::Memory,get_host_u64_VkDeviceMemory(image.memory)});
        objects.push_back({Retirement::Kind::Semaphore,get_host_u64_VkSemaphore(image.presentWait)});
    }
    const auto generation=caboose::completion::executorGeneration.load(std::memory_order_acquire);
    syncRetirementGeneration(generation);
    swap.lease=caboose::memory::presentationRetirement.reserve(generation,objects);
    return swap.lease ? VK_SUCCESS : VK_ERROR_OUT_OF_HOST_MEMORY;
}

static VkResult enqueuePendingFrame(DeviceSwapchain& swap, gfxstream_vk_queue* queue,
                                   uint32_t index, const std::vector<VkSemaphore>& waits) {
    auto& image=swap.images[index];
    if (!image.held || image.pending || swap.pending.size()>=swap.images.size())
        return VK_ERROR_INITIALIZATION_FAILED;
    if (swap.cancelled || swap.surface->destroyed || windowResized(swap)) return VK_ERROR_OUT_OF_DATE_KHR;
    if (caboose_gfxstream_ordered_present!=1) return VK_ERROR_FEATURE_NOT_PRESENT;
    auto* encoder=gfxstream::vk::ResourceTracker::getThreadLocalEncoder();
    // Resolve creation/bind replies before publishing their numeric handles to a second
    // transport. This is device-stream ordering, never a wait for a surface bind.
    if (!encoder->cabooseDrainDeferredObjects(true)) return VK_ERROR_DEVICE_LOST;
    std::vector<VkPipelineStageFlags> stages(waits.size(),VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    VkSubmitInfo handoff{}; handoff.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
    handoff.waitSemaphoreCount=uint32_t(waits.size()); handoff.pWaitSemaphores=waits.data();
    handoff.pWaitDstStageMask=stages.data();
    handoff.signalSemaphoreCount=1; handoff.pSignalSemaphores=&image.presentWait;
    auto result=gfxstream::vk::ResourceTracker::get()->on_vkQueueSubmit(
        encoder,VK_SUCCESS,queue->internal_object,1,&handoff,VK_NULL_HANDLE);
    if (result!=VK_SUCCESS) return result;
    const auto order=encoder->cabooseSendOrderMark(true);
    if (!order) return VK_ERROR_DEVICE_LOST;
    swap.pending.push_back({get_host_u64_VkQueue(queue->internal_object),order,index,
                           {get_host_u64_VkSemaphore(image.presentWait)}});
    image.held=false; image.pending=true;
    startSurfaceWorker(swap.surface); swap.surface->changed.notify_all();
    return VK_SUCCESS;
}

static void releaseRemoteSwap(DeviceSwapchain& swap) {
    if (swap.lease) caboose::memory::presentationRetirement.release(*swap.lease);
    swap.phase=RemotePhase::Retired;
}
static void beginRemoteCreate(DeviceSwapchain& swap, const Bytes& raw) {
    auto caps=providerCaps(raw);
    const auto& info=swap.params;
    if ((caps.values[2]!=UINT32_MAX && (caps.values[2]!=info.imageExtent.width || caps.values[3]!=info.imageExtent.height)) ||
        presentFamily(caps)!=swap.family) { swap.poisoned=true; swap.cancelled=true; swap.phase=RemotePhase::Dormant; return; }
    bool format=false;
    for (const auto& f:caps.formats)
        if (f[0]==uint32_t(info.imageFormat) && f[1]==uint32_t(info.imageColorSpace)) format=true;
    if (!format) { swap.poisoned=true; swap.cancelled=true; swap.phase=RemotePhase::Dormant; return; }
    const uint32_t low=std::max(1u,caps.values[0]), high=caps.values[1] ? caps.values[1] : std::max(low,3u);
    const uint32_t minimum=std::clamp(std::min(info.minImageCount,3u),low,high);
    uint32_t alpha=info.compositeAlpha;
    if (!(caps.values[11]&alpha))
        alpha=(caps.values[11]&VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : caps.values[11]&(~caps.values[11]+1);
    const uint32_t usage=swap.imageUsage&caps.values[12];
    if (!alpha || !usage) { swap.poisoned=true; swap.cancelled=true; swap.phase=RemotePhase::Dormant; return; }
    auto& surface=*swap.surface;
    Bytes request; put64(request,++surface.query); put64(request,swap.hostDevice); put64(request,0);
    for (uint32_t word:{0u,minimum,uint32_t(info.imageFormat),uint32_t(info.imageColorSpace),
         info.imageExtent.width,info.imageExtent.height,1u,usage,uint32_t(VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR),
         alpha,uint32_t(VK_PRESENT_MODE_FIFO_KHR),info.clipped ? 1u : 0u,uint32_t(VK_SHARING_MODE_EXCLUSIVE),0u})
        put32(request,word);
    surface.client.beginCreateSwapchain(request,std::chrono::steady_clock::now()+std::chrono::milliseconds(10));
    swap.nativeAttempted=true; swap.phase=RemotePhase::Create;
}

static void pumpRemoteSurface(Surface& surface) {
    auto& client=surface.client;
    const auto sendBy=std::chrono::steady_clock::now()+std::chrono::milliseconds(10);
    // Process cancellation before binding: an unsubmitted image is owned only locally.
    for (auto& swap:surface.remoteSwaps)
        if (swap->cancelled && swap->phase==RemotePhase::Dormant) releaseRemoteSwap(*swap);
    if (!surface.bound) {
        if (surface.destroyed && !client.bindPending()) return;
        if (!tryBind(surface)) {
            // A refused bind is terminal for the accepted swapchain work, rather than
            // filling its image ring while an infinite acquire waits for a retry.
            if (!client.bindPending() && !surface.attempted && surface.bindAttempts) {
                for (auto& swap:surface.remoteSwaps) { swap->poisoned=true; swap->cancelled=true; }
            }
            return;
        }
    }
    client.pump();
    std::shared_ptr<DeviceSwapchain> setup, retiring;
    for (auto& swap:surface.remoteSwaps) {
        if (swap->phase==RemotePhase::Query || swap->phase==RemotePhase::Create || swap->phase==RemotePhase::Map) setup=swap;
        if (swap->phase==RemotePhase::Retiring) retiring=swap;
    }
    if (setup) {
        Record reply;
        if (setup->phase==RemotePhase::Query && client.takeQuery(&reply)) {
            if (apiStatus(status(reply.body,48))!=VK_SUCCESS) { setup->poisoned=true; setup->cancelled=true; setup->phase=RemotePhase::Dormant; }
            else {
                surface.caps=reply.body; surface.capsPhysical=setup->hostPhysical;
                surface.capsTime=std::chrono::steady_clock::now();
                if (setup->cancelled) setup->phase=RemotePhase::Dormant;
                else beginRemoteCreate(*setup,reply.body);
            }
        } else if (setup->phase==RemotePhase::Create && client.takeCreatedSwapchain(&reply)) {
            if (apiStatus(status(reply.body,56))!=VK_SUCCESS) {
                setup->nativeAttempted=false; setup->poisoned=true; setup->cancelled=true; setup->phase=RemotePhase::Dormant;
            } else {
                setup->native=u64(reply.body,48);
                client.beginMapSwapchain(setup->native,setup->hostImages,sendBy,setup->mailbox ? 3u : 1u);
                setup->phase=RemotePhase::Map;
            }
        } else if (setup->phase==RemotePhase::Map && client.takeMappedSwapchain(&reply)) {
            if (apiStatus(status(reply.body,48))!=VK_SUCCESS) { setup->poisoned=true; setup->cancelled=true; }
            else for (size_t i=0;i<setup->images.size();++i)
                if (setup->images[i].held || setup->images[i].pending) client.acquireLocally(setup->native,uint32_t(i));
            setup->phase=RemotePhase::Ready;
        }
    }
    if (retiring) {
        Record reply;
        if (client.takeRetiredSwapchain(&reply) && apiStatus(status(reply.body,48))==VK_SUCCESS)
            releaseRemoteSwap(*retiring);
    }
    for (auto& swap:surface.remoteSwaps) {
        if (swap->phase==RemotePhase::Dormant && !swap->cancelled && !swap->pending.empty() && !setup) {
            if (!client.queryPending()) client.beginQuery(++surface.query,swap->hostPhysical,sendBy);
            swap->phase=RemotePhase::Query; setup=swap;
        }
        if (swap->phase!=RemotePhase::Ready) continue;
        if (swap->cancelled && swap->pending.empty() && !client.presentationsInFlight(swap->native)) {
            if (!retiring) { client.beginRetireSwapchain(swap->native,sendBy); swap->phase=RemotePhase::Retiring; retiring=swap; }
            continue;
        }
        if (!swap->pending.empty() && client.presentationsInFlight()<kGuestFramesInFlight) {
            auto& frame=swap->pending.front();
            const uint64_t serial=++surface.presentSerial;
            client.presentOrdered(swap->native,serial,frame.queue,frame.order,frame.index,swap->family,frame.waits,sendBy);
            auto& image=swap->images[frame.index]; image.serial=serial; image.pending=false;
            swap->pending.pop_front();
        }
    }
}

// Constructed when the first pump starts, after the API-side encoder and registries.
// Its destructor joins pumps before static Vulkan/ledger state can be destroyed.
class SurfaceWorkers {
    struct Worker { std::shared_ptr<std::atomic<bool>> done; std::thread thread; };
    std::mutex mutex_;
    std::vector<Worker> workers_;
public:
    std::atomic<bool> stopping{false};
    ~SurfaceWorkers() {
        stopping.store(true,std::memory_order_release);
        for (auto& worker:workers_) if (worker.thread.joinable()) worker.thread.join();
    }
    template<class F> void start(F work) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it=workers_.begin();it!=workers_.end();) {
            if (!it->done->load(std::memory_order_acquire)) { ++it; continue; }
            it->thread.join(); it=workers_.erase(it);
        }
        if (workers_.size()>=Retirement::kMaxLeases) throw std::bad_alloc();
        auto done=std::make_shared<std::atomic<bool>>(false);
        // Reserve before starting a thread, so vector growth cannot strand a joinable thread.
        workers_.reserve(Retirement::kMaxLeases);
        workers_.push_back({done,std::thread([work=std::move(work),done] {
            work(); done->store(true,std::memory_order_release);
        })});
    }
};
static SurfaceWorkers& surfaceWorkers() { static SurfaceWorkers workers; return workers; }

static void startSurfaceWorker(const std::shared_ptr<Surface>& surface) {
    if (surface->workerStarted) return;
    auto& workers=surfaceWorkers();
    workers.start([surface,&workers] {
        while (!workers.stopping.load(std::memory_order_acquire)) {
            bool finished=false;
            {
                std::unique_lock<std::recursive_mutex> lock(surface->operationMutex);
                const auto generation=caboose::completion::executorGeneration.load(std::memory_order_acquire);
                if (generation!=surface->generation || caboose::completion::executorLost.load(std::memory_order_acquire)) {
                    syncRetirementGeneration(generation);
                    for (auto& swap:surface->remoteSwaps) { swap->poisoned=true; swap->cancelled=true; releaseRemoteSwap(*swap); }
                    if (surface->instanceLease) caboose::memory::presentationRetirement.release(*surface->instanceLease);
                    finished=true;
                } else {
                    try {
                        pumpRemoteSurface(*surface);
                        surface->remoteSwaps.erase(std::remove_if(surface->remoteSwaps.begin(),surface->remoteSwaps.end(),
                            [](const auto& swap){return swap->phase==RemotePhase::Retired;}),surface->remoteSwaps.end());
                        if (surface->destroyed && surface->remoteSwaps.empty()) {
                            if (!surface->bound && !surface->client.bindPending()) finished=true;
                            else if (surface->bound) {
                                surface->client.beginRetire(std::chrono::steady_clock::now()+std::chrono::milliseconds(10));
                                finished=surface->client.retired();
                            }
                            if (finished && surface->instanceLease)
                                caboose::memory::presentationRetirement.release(*surface->instanceLease);
                        }
                    } catch (...) {
                        // No retirement proof: retain bounded numeric records until the
                        // executor generation ends. Never turn a socket error into a free.
                        surface->poisoned=true;
                        for (auto& swap:surface->remoteSwaps) swap->poisoned=true;
                    }
                }
                surface->changed.notify_all();
            }
            if (!workers.stopping.load(std::memory_order_acquire))
                gfxstream::vk::ResourceTracker::getThreadLocalEncoder()->cabooseFlushPresentationRetirements();
            if (finished) {
                if (std::getenv("CABOOSE_GFXSTREAM_RETIREMENT_DIAGNOSTICS"))
                    std::fprintf(stderr,"CABOOSE_GPU_PRESENTATION_RETIRED leases=%zu records=%zu\n",
                        caboose::memory::presentationRetirement.leaseCount(),
                        caboose::memory::presentationRetirement.recordCount());
                break;
            }
            std::unique_lock<std::recursive_mutex> lock(surface->operationMutex);
            surface->changed.wait_for(lock,std::chrono::milliseconds(1));
        }
    });
    surface->workerStarted=true;
}
