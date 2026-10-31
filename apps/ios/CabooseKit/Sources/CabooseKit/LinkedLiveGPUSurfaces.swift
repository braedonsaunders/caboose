#if canImport(CabooseGPULive) && canImport(UIKit)
import Foundation
import Metal
import UIKit
import CabooseGPULive

/// Only the consumer worker waits. Main receives an asynchronous operation and
/// never waits for worker/native retirement, avoiding a main/decoder lock cycle.
private final class LiveGPUMainResult<T>: @unchecked Sendable {
    private var result: Result<T, Error>?
    private let ready = DispatchSemaphore(value: 0)
    func perform(_ operation: @escaping @MainActor () throws -> T) throws -> T {
        try performAsync { complete in complete(Result { try operation() }) }
    }
    func performAsync(_ operation: @escaping @MainActor (@escaping @MainActor (Result<T, Error>) -> Void) -> Void) throws -> T {
        precondition(!Thread.isMainThread)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                operation { value in result = value; ready.signal() }
            }
        }
        ready.wait()
        return try result!.get()
    }
}
private func liveGPUOnMain<T>(_ operation: @escaping @MainActor () throws -> T) throws -> T {
    try LiveGPUMainResult<T>().perform(operation)
}

final class LinkedLiveGPUSurfaces: LiveGPUSurfaceBackend, @unchecked Sendable {
    private let owners: LiveGPUPresentationOwners
    init(owners: LiveGPUPresentationOwners) { self.owners = owners }
    func bind(identity: LiveGPUSurfaceIdentity, processToken: UInt64, window: UInt64,
              instance: UInt64, width: UInt32, height: UInt32) throws -> LiveGPUSurfaceBinding {
        let lease: LiveGPULayerLease
        do {
            lease = try LiveGPUMainResult<LiveGPULayerLease>().performAsync { [owners] complete in
                owners.requestClaim(identity: identity, windowID: window, complete: complete)
            }
        } catch {
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            if let value = error as? LiveGPUBindingError, case .native(_, let code) = value {
                LiveGPUMemoryAudit.bindStage(.claim, code: code)
            }
            #endif
            throw error
        }
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.bindStage(.claim, code: 0)
        #endif
        guard (width == 0 && height == 0) ||
              (width == UInt32(lease.extent.width) && height == UInt32(lease.extent.height)) else {
            try liveGPUOnMain { [owners] in owners.release(lease) }
            return .init(status: .init(nativeErrno: EAGAIN, vkResult: nil), resource: nil)
        }
        var bind = caboose_gpu_surface_bind_info()
        bind.identity.process_token = processToken; bind.identity.window_id = window
        bind.identity.generation = identity.generation
        withUnsafeMutableBytes(of: &bind.identity.compositor_epoch) { identity.epoch.copyBytes(to: $0) }
        withUnsafeMutableBytes(of: &bind.identity.grant) { identity.grant.copyBytes(to: $0) }
        bind.boxed_instance = instance
        // The actual visible owner supplies the initial extent. A surface query
        // precedes the game's first swapchain image; no guest buffer is invented.
        bind.width = UInt32(lease.extent.width); bind.height = UInt32(lease.extent.height)
        var pointer: OpaquePointer?
        let result = caboose_gpu_surface_prepare(&bind, &pointer)
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.bindStage(.prepare, code: result)
        #endif
        guard result == 0, let pointer else {
            try liveGPUOnMain { [owners] in owners.release(lease) }
            return .init(status: .init(nativeErrno: result > 0 ? result : EIO, vkResult: nil), resource: nil)
        }
        let resource = LinkedLiveGPUSurface(pointer: pointer, bind: bind, lease: lease, owners: owners)
        let attached = try liveGPUOnMain {
            guard lease.isValid, let layer = lease.layer else { return ECANCELED }
            return caboose_gpu_surface_attach(pointer, layer)
        }
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.bindStage(.attach, code: attached)
        #endif
        if attached != 0 {
            do { try resource.retire() }
            catch {
                #if DEBUG && canImport(CabooseGPUMemoryAudit)
                if let value = error as? LiveGPUBindingError, case .native(_, let code) = value {
                    LiveGPUMemoryAudit.bindStage(.retireFailedAttach, code: code)
                }
                #endif
                return .init(status: .init(nativeErrno: attached, vkResult: nil), resource: resource)
            }
            return .init(status: .init(nativeErrno: attached, vkResult: nil), resource: nil)
        }
        resource.startCapture()
        return .init(status: .init(nativeErrno: 0, vkResult: nil), resource: resource)
    }
}

private final class LinkedLiveGPUSurface: LiveGPUIndexedSurfaceResource, @unchecked Sendable {
    private var pointer: OpaquePointer?
    private let bind: caboose_gpu_surface_bind_info
    private let lease: LiveGPULayerLease
    private let owners: LiveGPUPresentationOwners
    // Native owns a raw callback context. Keep it alive independently of UI ARC
    // until successful GPU retirement and main detach; failure quarantines it.
    private var nativeLifetime: LinkedLiveGPUSurface?
    private let callbackLock = NSLock()
    private var callbacks: [UInt64: @Sendable (LiveGPUSurfaceMessage.Body) -> Void] = [:]
    /// Guards capture releases against retirement; native captures stop before retire.
    private let captureLock = NSLock()
    private var capturing = false
    init(pointer: OpaquePointer, bind: caboose_gpu_surface_bind_info,
         lease: LiveGPULayerLease, owners: LiveGPUPresentationOwners) {
        self.pointer = pointer; self.bind = bind; self.lease = lease; self.owners = owners
        nativeLifetime = self
    }

    /// Presented pictures go to the owning view for phone-owned scrolling (docs/display.md,
    /// "Phone-owned scrolling"). A device that cannot share them presents without captures.
    func startCapture() {
        guard let pointer else { return }
        captureLock.withLock {
            capturing = caboose_gpu_surface_set_capture(pointer, { context, _, token, texture in
                guard let context, let texture else { return }
                Unmanaged<LinkedLiveGPUSurface>.fromOpaque(context).takeUnretainedValue()
                    .captured(token: token, texture: texture)
            }, Unmanaged.passUnretained(self).toOpaque()) == 0
        }
    }

    /// Frame worker: the picture is lent until `releaseCapture(token)`.
    private func captured(token: UInt32, texture: UnsafeMutableRawPointer) {
        guard let metal = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue() as? MTLTexture else {
            releaseCapture(token)
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let release: @Sendable () -> Void = { [weak self] in self?.releaseCapture(token) }
                guard self.lease.isValid, let view = self.lease.view else { release(); return }
                view.liveGPUPictureCaptured(metal, release: release)
            }
        }
    }

    private func releaseCapture(_ token: UInt32) {
        captureLock.withLock {
            guard capturing, let pointer else { return }
            _ = caboose_gpu_surface_release_capture(pointer, token)
        }
    }

    private func stopCapture() {
        captureLock.withLock {
            guard capturing, let pointer else { return }
            _ = caboose_gpu_surface_set_capture(pointer, nil, nil)
            capturing = false
        }
    }
    func create(_ request: LiveGPUSwapchainCreate) -> (LiveGPUSurfaceStatus, (any LiveGPUIndexedSwapchain)?) {
        guard lease.isValid, let pointer else { return (.init(nativeErrno: ECANCELED, vkResult: nil), nil) }
        // The game chooses buffer pixels independently of its desktop placement.
        // Native reserves and validates the real surface before any layer mutation.
        let configured: Int32
        do {
            configured = try liveGPUOnMain { [self] in
                lease.configurePresentationExtent(CGSize(width: CGFloat(request.width), height: CGFloat(request.height))) { layer in
                    var identity = bind.identity
                    return caboose_gpu_surface_configure_extent(pointer, &identity, layer, request.width, request.height)
                }
            }
        } catch { return (.init(nativeErrno: EIO, vkResult: nil), nil) }
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.surfaceConfigured(width: request.width, height: request.height, code: configured)
        #endif
        guard configured == 0 else { return (.init(nativeErrno: configured > 0 ? configured : EIO, vkResult: nil), nil) }
        guard lease.isValid else { return (.init(nativeErrno: ECANCELED, vkResult: nil), nil) }
        var info = caboose_gpu_swapchain_create_info()
        info.identity = bind.identity; info.boxed_device = request.device; info.old_swapchain_id = request.oldSwapchain
        info.create_flags = request.flags; info.min_image_count = request.minImageCount
        info.vk_format = request.format; info.color_space = request.colorSpace
        info.width = request.width; info.height = request.height; info.image_array_layers = request.arrayLayers
        info.image_usage = request.usage; info.pre_transform = request.preTransform
        info.composite_alpha = request.compositeAlpha; info.present_mode = request.presentMode
        info.clipped = request.clipped ? 1 : 0; info.sharing_mode = request.sharingMode
        info.queue_family_count = UInt32(request.families.count)
        var output: OpaquePointer?, id: UInt64 = 0, count: UInt32 = 0
        var status = caboose_gpu_query_status()
        let code = request.families.withUnsafeBufferPointer {
            info.queue_families = $0.baseAddress
            return caboose_gpu_virtual_swapchain_create(pointer, &info, &output, &id, &count, &status)
        }
        let actual = indexedStatus(status)
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.swapchainCreated(actual, count: count)
        #endif
        let value = output.map { LinkedLiveGPUIndexedSwapchain(pointer: $0, id: id, count: count,
                                                             identity: bind.identity, parent: self) }
        if code != 0 && actual.querySucceeded { return (.init(nativeErrno: EIO, vkResult: nil), value) }
        return (actual, value)
    }
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
        guard lease.isValid, let pointer else { return (.init(nativeErrno: ECANCELED, vkResult: nil), nil) }
        var snapshot: OpaquePointer?
        var status = caboose_gpu_query_status()
        let code = caboose_gpu_surface_query_variable_extent(pointer, physicalDevice, &snapshot, &status)
        defer { if let snapshot { caboose_gpu_surface_capabilities_release(snapshot) } }
        let actual = LiveGPUSurfaceStatus(nativeErrno: status.native_error,
                                          vkResult: status.has_vulkan_result == 1 ? status.vulkan_result : nil)
        guard code == 0, actual.querySucceeded, let snapshot,
              let view = caboose_gpu_surface_capabilities_get(snapshot)?.pointee else {
            return (actual.querySucceeded ? .init(nativeErrno: EIO, vkResult: nil) : actual, nil)
        }
        guard view.format_count <= 4096, view.present_mode_count <= 4096, view.queue_family_count <= 4096,
              view.format_count == 0 || view.formats != nil,
              view.present_mode_count == 0 || view.present_modes != nil,
              view.queue_family_count == 0 || view.queue_families != nil else {
            return (.init(nativeErrno: EOVERFLOW, vkResult: nil), nil)
        }
        let formats = (0..<Int(view.format_count)).map { i in
            let value = view.formats[i]
            return LiveGPUSurfaceCapabilities.Format(format: value.format, colorSpace: value.color_space)
        }
        let modes = (0..<Int(view.present_mode_count)).map { view.present_modes[$0] }
        let queues = (0..<Int(view.queue_family_count)).map { i in
            let value = view.queue_families[i]
            return LiveGPUSurfaceCapabilities.Queue(family: UInt32(i), flags: value.queue_flags,
                count: value.queue_count, supported: value.present_supported == 1)
        }
        let caps = LiveGPUSurfaceCapabilities(minImageCount: view.min_image_count, maxImageCount: view.max_image_count,
            currentWidth: view.current_width, currentHeight: view.current_height,
            minWidth: view.min_width, minHeight: view.min_height, maxWidth: view.max_width, maxHeight: view.max_height,
            maxImageArrayLayers: view.max_image_array_layers, supportedTransforms: view.supported_transforms,
            currentTransform: view.current_transform, supportedCompositeAlpha: view.supported_composite_alpha,
            supportedUsageFlags: view.supported_usage_flags, formats: formats, modes: modes, queues: queues)
        return (actual, caps)
    }
    func present(_ request: LiveGPUSurfacePresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
        guard lease.isValid, let pointer else {
            return .init(status: .init(nativeErrno: ECANCELED, vkResult: nil), disposition: .rejected)
        }
        var info = caboose_gpu_present_info()
        info.identity = bind.identity
        info.present_serial = request.serial; info.boxed_device = request.device
        info.boxed_queue = request.queue; info.boxed_image = request.image
        info.vk_format = request.format; info.width = request.width; info.height = request.height
        info.vk_image_layout = request.layout; info.queue_family = request.queueFamily
        info.wait_semaphore_count = UInt32(request.waits.count)
        callbackLock.withLock { callbacks[request.serial] = event }
        let result = request.waits.withUnsafeBufferPointer { waits in
            info.boxed_wait_semaphores = waits.baseAddress
            return caboose_gpu_surface_present(pointer, &info, { context, serial, kind, result in
                guard let context else { return }
                Unmanaged<LinkedLiveGPUSurface>.fromOpaque(context).takeUnretainedValue()
                    .receive(serial: serial, kind: kind, result: result)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        let disposition = LiveGPUSurfaceMessage.Disposition(rawValue: result.disposition.rawValue) ?? .uncertain
        callbackLock.withLock {
            if disposition == .rejected { callbacks.removeValue(forKey: request.serial) }
            else { callbacks = callbacks.filter { $0.key == request.serial } }
        }
        return .init(status: Self.status(result), disposition: disposition)
    }
    private static func status(_ result: caboose_gpu_submit_result) -> LiveGPUSurfaceStatus {
        .init(nativeErrno: result.native_error,
              vkResult: result.has_vulkan_result == 1 ? result.vulkan_result : nil)
    }
    private func receive(serial: UInt64, kind: caboose_gpu_present_event, result: caboose_gpu_submit_result) {
        let callback = callbackLock.withLock { callbacks[serial] }
        guard let callback else { return }
        switch kind {
        case CABOOSE_GPU_SOURCE_RELEASED: callback(.sourceReleased(serial: serial))
        case CABOOSE_GPU_DEVICE_LOST:
            callback(.presentResult(serial: serial, status: Self.status(result), disposition: .uncertain, event: .deviceLost))
        default:
            callback(.presentResult(serial: serial, status: Self.status(result), disposition: .uncertain, event: .failedUnretired))
        }
    }
    func retire() throws {
        lease.invalidate()
        stopCapture()
        guard let current = pointer else { return }
        let code = caboose_gpu_surface_retire(current)
        guard code == 0 else {
            try? liveGPUOnMain { [lease] in lease.content?.removeFromSuperview() }
            throw LiveGPUBindingError.native(operation: "surface retire", code: code)
        }
        try liveGPUOnMain { [self] in
            lease.content?.removeFromSuperview()
            var current = pointer
            let code = caboose_gpu_surface_detach(&current)
            guard code == 0, current == nil else {
                throw LiveGPUBindingError.native(operation: "surface detach", code: code > 0 ? code : EIO)
            }
            pointer = nil
            owners.release(lease)
        }
        callbackLock.withLock { callbacks.removeAll() }
        nativeLifetime = nil
    }
}

private func indexedStatus(_ status: caboose_gpu_query_status) -> LiveGPUSurfaceStatus {
    .init(nativeErrno: status.native_error, vkResult: status.has_vulkan_result == 1 ? status.vulkan_result : nil)
}
private final class LinkedLiveGPUIndexedSwapchain: LiveGPUIndexedSwapchain, @unchecked Sendable {
    let id: UInt64
    let imageCount: UInt32
    private var pointer: OpaquePointer?
    private let identity: caboose_gpu_surface_identity
    private let parent: LinkedLiveGPUSurface
    private var nativeLifetime: LinkedLiveGPUIndexedSwapchain?
    private let lock = NSLock()
    private var callbacks: [UInt64: @Sendable (LiveGPUSurfaceMessage.Body) -> Void] = [:]
    init(pointer: OpaquePointer, id: UInt64, count: UInt32,
         identity: caboose_gpu_surface_identity, parent: LinkedLiveGPUSurface) {
        self.pointer = pointer; self.id = id; imageCount = count; self.identity = identity; self.parent = parent
        nativeLifetime = self
    }
    func map(_ images: [UInt64]) -> LiveGPUSurfaceStatus {
        guard let pointer else { return .init(nativeErrno: ESTALE, vkResult: nil) }
        let code = images.withUnsafeBufferPointer { caboose_gpu_virtual_swapchain_map(pointer, $0.baseAddress, UInt32($0.count)) }
        return .init(nativeErrno: code, vkResult: nil)
    }
    func beginAcquire(_ info: LiveGPUSwapchainAcquire) -> (LiveGPUSurfaceStatus, (any LiveGPUAcquireOperation)?) {
        guard let pointer else { return (.init(nativeErrno: ESTALE, vkResult: nil), nil) }
        var native = caboose_gpu_acquire_info()
        native.boxed_binary_semaphore = info.semaphore; native.boxed_fence = info.fence; native.device_mask = info.deviceMask
        var request: OpaquePointer?, status = caboose_gpu_query_status()
        let code = caboose_gpu_acquire_begin(pointer, &native, &request, &status)
        let actual = indexedStatus(status)
        let operation = request.map { LinkedLiveGPUAcquireOperation(pointer: $0, parent: self) }
        if code != 0 && actual.succeeded { return (.init(nativeErrno: EIO, vkResult: nil), operation) }
        return (actual, operation)
    }
    func present(_ request: LiveGPUIndexedPresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission {
        guard let pointer else { return .init(status: .init(nativeErrno: ESTALE, vkResult: nil), disposition: .rejected) }
        var info = caboose_gpu_mapped_present_info()
        info.identity = identity; info.present_serial = request.serial; info.boxed_queue = request.queue
        info.queue_family = request.family; info.image_index = request.index; info.vk_image_layout = request.layout
        info.wait_semaphore_count = UInt32(request.waits.count)
        lock.withLock { callbacks[request.serial] = event }
        let result = request.waits.withUnsafeBufferPointer {
            info.boxed_wait_semaphores = $0.baseAddress
            return caboose_gpu_virtual_swapchain_present(pointer, &info, { context, serial, kind, result in
                guard let context else { return }
                Unmanaged<LinkedLiveGPUIndexedSwapchain>.fromOpaque(context).takeUnretainedValue()
                    .receive(serial: serial, kind: kind, result: result)
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        let disposition = LiveGPUSurfaceMessage.Disposition(rawValue: result.disposition.rawValue) ?? .uncertain
        if disposition == .rejected { _ = lock.withLock { callbacks.removeValue(forKey: request.serial) } }
        return .init(status: .init(nativeErrno: result.native_error,
            vkResult: result.has_vulkan_result == 1 ? result.vulkan_result : nil), disposition: disposition)
    }
    private func receive(serial: UInt64, kind: caboose_gpu_present_event, result: caboose_gpu_submit_result) {
        // Copy the closure before releasing its dictionary entry. The raw native
        // context remains retained through successful swapchain/surface retirement.
        let callback = lock.withLock { callbacks[serial] }
        guard let callback else { return }
        switch kind {
        case CABOOSE_GPU_SOURCE_RELEASED: callback(.sourceReleased(serial: serial))
        case CABOOSE_GPU_PRESENT_RETIRED:
            callback(.swapchain(.presentRetired(swapchain: id, serial: serial)))
            _ = lock.withLock { callbacks.removeValue(forKey: serial) }
        default:
            callback(.presentResult(serial: serial,
                status: .init(nativeErrno: result.native_error, vkResult: result.has_vulkan_result == 1 ? result.vulkan_result : nil),
                disposition: .uncertain, event: kind == CABOOSE_GPU_DEVICE_LOST ? .deviceLost : .failedUnretired))
        }
    }
    func retire() -> LiveGPUSurfaceStatus {
        guard pointer != nil else { return .init(nativeErrno: 0, vkResult: nil) }
        var status = caboose_gpu_query_status()
        let code = caboose_gpu_virtual_swapchain_retire(&pointer, &status)
        let actual = indexedStatus(status)
        if code == 0 && actual.succeeded && pointer == nil {
            lock.withLock { callbacks.removeAll() }; nativeLifetime = nil
            return actual
        }
        return actual.succeeded ? .init(nativeErrno: code > 0 ? code : EIO, vkResult: nil) : actual
    }
}
private final class LinkedLiveGPUAcquireOperation: LiveGPUAcquireOperation, @unchecked Sendable {
    private var pointer: OpaquePointer?
    private let parent: LinkedLiveGPUIndexedSwapchain
    private var nativeLifetime: LinkedLiveGPUAcquireOperation?
    init(pointer: OpaquePointer, parent: LinkedLiveGPUIndexedSwapchain) {
        self.pointer = pointer; self.parent = parent; nativeLifetime = self
    }
    func poll() -> LiveGPUAcquireCompletion {
        let result = caboose_gpu_acquire_poll(pointer)
        var value = LiveGPUAcquireCompletion(status: .init(nativeErrno: result.native_error,
            vkResult: result.has_vulkan_result == 1 ? result.vulkan_result : nil),
            index: result.has_image_index == 1 ? result.image_index : nil,
            reason: LiveGPUAcquireLocalReason(rawValue: result.local_reason) ?? .other)
        value.invalidNativeShape = result.has_image_index > 1 || result.has_vulkan_result > 1 ||
            LiveGPUAcquireLocalReason(rawValue: result.local_reason) == nil ||
            (result.has_vulkan_result == 0 && result.vulkan_result != 0)
        return value
    }
    func cancel() -> Int32 { caboose_gpu_acquire_cancel(pointer) }
    func observeSignal() -> LiveGPUSurfaceStatus { indexedStatus(caboose_gpu_acquire_observe(pointer)) }
    func release() -> Int32 {
        guard pointer != nil else { return EINVAL }
        let code = caboose_gpu_acquire_request_release(&pointer)
        if code == 0 && pointer == nil { nativeLifetime = nil; return 0 }
        return code > 0 ? code : EIO
    }
}
#endif
