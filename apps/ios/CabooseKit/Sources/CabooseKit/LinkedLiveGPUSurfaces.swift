#if canImport(CabooseGPULive) && canImport(UIKit)
import Foundation
import UIKit
import CabooseGPULive

/// Only the consumer worker waits. Main receives an asynchronous operation and
/// never waits for worker/native retirement, avoiding a main/decoder lock cycle.
private final class LiveGPUMainResult<T>: @unchecked Sendable {
    private var result: Result<T, Error>?
    private let ready = DispatchSemaphore(value: 0)
    func perform(_ operation: @escaping @MainActor () throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        DispatchQueue.main.async { [self] in
            result = Result { try MainActor.assumeIsolated { try operation() } }
            ready.signal()
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
        let lease = try liveGPUOnMain { [owners] in try owners.claim(identity: identity, windowID: window) }
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
        guard result == 0, let pointer else {
            try liveGPUOnMain { [owners] in owners.release(lease) }
            return .init(status: .init(nativeErrno: result > 0 ? result : EIO, vkResult: nil), resource: nil)
        }
        let resource = LinkedLiveGPUSurface(pointer: pointer, bind: bind, lease: lease, owners: owners)
        let attached = try liveGPUOnMain {
            guard lease.isValid, let layer = lease.layer else { return ECANCELED }
            return caboose_gpu_surface_attach(pointer, layer)
        }
        if attached != 0 {
            do { try resource.retire() }
            catch {
                return .init(status: .init(nativeErrno: attached, vkResult: nil), resource: resource)
            }
            return .init(status: .init(nativeErrno: attached, vkResult: nil), resource: nil)
        }
        return .init(status: .init(nativeErrno: 0, vkResult: nil), resource: resource)
    }
}

private final class LinkedLiveGPUSurface: LiveGPUSurfaceResource, @unchecked Sendable {
    private var pointer: OpaquePointer?
    private let bind: caboose_gpu_surface_bind_info
    private let lease: LiveGPULayerLease
    private let owners: LiveGPUPresentationOwners
    // Native owns a raw callback context. Keep it alive independently of UI ARC
    // until successful GPU retirement and main detach; failure quarantines it.
    private var nativeLifetime: LinkedLiveGPUSurface?
    private let callbackLock = NSLock()
    private var callbacks: [UInt64: @Sendable (LiveGPUSurfaceMessage.Body) -> Void] = [:]
    init(pointer: OpaquePointer, bind: caboose_gpu_surface_bind_info,
         lease: LiveGPULayerLease, owners: LiveGPUPresentationOwners) {
        self.pointer = pointer; self.bind = bind; self.lease = lease; self.owners = owners
        nativeLifetime = self
    }
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
        guard lease.isValid, let pointer else { return (.init(nativeErrno: ECANCELED, vkResult: nil), nil) }
        var snapshot: OpaquePointer?
        var status = caboose_gpu_query_status()
        let code = caboose_gpu_surface_query(pointer, physicalDevice, &snapshot, &status)
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
        guard let current = pointer else { return }
        let code = caboose_gpu_surface_retire(current)
        guard code == 0 else { throw LiveGPUBindingError.native(operation: "surface retire", code: code) }
        try liveGPUOnMain { [self] in
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
#endif
