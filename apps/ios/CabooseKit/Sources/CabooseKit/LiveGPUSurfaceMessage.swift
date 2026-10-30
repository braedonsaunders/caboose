import Foundation

/// Process-scoped surface controls carry compositor authority, never a UIKit pointer.
/// Parsing these records grants no layer access and makes no presentation claim.
struct LiveGPUSurfaceIdentity: Equatable, Sendable {
    let epoch: Data
    let grant: Data
    let generation: UInt64
}

struct LiveGPUSurfaceStatus: Equatable, Sendable {
    let nativeErrno: Int32
    let vkResult: Int32?
    var succeeded: Bool { nativeErrno == 0 && (vkResult == nil || vkResult == 0) }
    var querySucceeded: Bool { nativeErrno == 0 && vkResult == 0 }
}

struct LiveGPUSurfaceCapabilities: Equatable, Sendable {
    // The thirteen VkSurfaceCapabilitiesKHR uint32 fields, in specification order.
    let minImageCount: UInt32
    let maxImageCount: UInt32
    let currentWidth: UInt32
    let currentHeight: UInt32
    let minWidth: UInt32
    let minHeight: UInt32
    let maxWidth: UInt32
    let maxHeight: UInt32
    let maxImageArrayLayers: UInt32
    let supportedTransforms: UInt32
    let currentTransform: UInt32
    let supportedCompositeAlpha: UInt32
    let supportedUsageFlags: UInt32
    struct Format: Equatable, Sendable { let format: UInt32; let colorSpace: UInt32 }
    struct Queue: Equatable, Sendable {
        let family: UInt32
        let flags: UInt32
        let count: UInt32
        let supported: Bool
    }
    let formats: [Format]
    let modes: [UInt32]
    let queues: [Queue]
}

struct LiveGPUSurfacePresent: Equatable, Sendable {
    let serial: UInt64
    let device: UInt64
    let queue: UInt64
    let image: UInt64
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let layout: UInt32
    let queueFamily: UInt32
    let waits: [UInt64]
}

struct LiveGPUSurfaceMessage: Equatable, Sendable {
    enum Disposition: UInt32, Sendable { case rejected, queued, uncertain }
    enum Event: UInt32, Sendable { case submission, deviceLost, failedUnretired }
    enum Body: Equatable, Sendable {
        case bind(window: UInt64, instance: UInt64, width: UInt32, height: UInt32)
        case bound(LiveGPUSurfaceStatus)
        case query(request: UInt64, physicalDevice: UInt64)
        case capabilities(request: UInt64, status: LiveGPUSurfaceStatus, value: LiveGPUSurfaceCapabilities?)
        case present(LiveGPUSurfacePresent)
        case presentResult(serial: UInt64, status: LiveGPUSurfaceStatus, disposition: Disposition, event: Event)
        case sourceReleased(serial: UInt64)
        case retire
        case retired(LiveGPUSurfaceStatus)
    }
    let identity: LiveGPUSurfaceIdentity
    let body: Body

    var kind: LiveGPUEnvelope.Kind {
        switch body {
        case .bind: return .surfaceBind
        case .bound: return .surfaceBound
        case .query: return .surfaceQuery
        case .capabilities: return .surfaceCaps
        case .present: return .present
        case .presentResult: return .presentResult
        case .sourceReleased: return .sourceReleased
        case .retire: return .surfaceRetire
        case .retired: return .surfaceRetired
        }
    }

    /// Header validation rejects impossible sizes before retaining any body bytes.
    static func validateLength(_ length: Int, kind: LiveGPUEnvelope.Kind) throws {
        let valid: Bool
        switch kind {
        case .surfaceBind: valid = length == 64
        case .surfaceBound, .surfaceQuery, .surfaceRetired: valid = length == 56
        case .surfaceCaps: valid = length == 64 || (length >= 128 && length <= 128 + 4096 * 28 && length % 4 == 0)
        case .present: valid = length >= 96 && length <= 96 + 64 * 8 && (length - 96) % 8 == 0
        case .presentResult: valid = length == 72
        case .sourceReleased: valid = length == 48
        case .surfaceRetire: valid = length == 40
        default: valid = false
        }
        try require(valid, "surface payload length")
    }

    static func decode(kind: LiveGPUEnvelope.Kind, payload: Data) throws -> Self {
        try validateLength(payload.count, kind: kind)
        var r = Reader(payload)
        let identity = LiveGPUSurfaceIdentity(epoch: try r.bytes(16), grant: try r.bytes(16), generation: try r.u64())
        try require(identity.epoch.contains { $0 != 0 } && identity.grant.contains { $0 != 0 } && identity.generation > 0,
                    "surface identity")
        let body: Body
        switch kind {
        case .surfaceBind:
            let window = try r.u64(), instance = try r.u64(), width = try r.u32(), height = try r.u32()
            try require(window > 0 && instance > 0 && ((width == 0) == (height == 0)), "surface bind fields")
            body = .bind(window: window, instance: instance, width: width, height: height)
        case .surfaceBound: body = .bound(try r.status())
        case .surfaceQuery:
            let request = try r.u64(), physical = try r.u64()
            try require(request > 0 && physical > 0, "surface query fields")
            body = .query(request: request, physicalDevice: physical)
        case .surfaceCaps:
            let request = try r.u64(), status = try r.status()
            try require(request > 0, "surface query request")
            var caps: LiveGPUSurfaceCapabilities?
            if status.querySucceeded {
                let fields = try (0..<13).map { _ in try r.u32() }
                let nf = try r.u32(), nm = try r.u32(), nq = try r.u32()
                try require(nf <= 4096 && nm <= 4096 && nq <= 4096, "surface capability count")
                try require(r.remaining == Int(nf) * 8 + Int(nm) * 4 + Int(nq) * 16, "surface capability arrays")
                let formats = try (0..<nf).map { _ in
                    LiveGPUSurfaceCapabilities.Format(format: try r.u32(), colorSpace: try r.u32())
                }
                let modes = try (0..<nm).map { _ in try r.u32() }
                var families = Set<UInt32>()
                let queues = try (0..<nq).map { _ -> LiveGPUSurfaceCapabilities.Queue in
                    let family = try r.u32(), flags = try r.u32(), count = try r.u32(), supported = try r.u32()
                    try require(supported <= 1 && count > 0 && families.insert(family).inserted, "surface queue capabilities")
                    return .init(family: family, flags: flags, count: count, supported: supported == 1)
                }
                caps = .init(minImageCount: fields[0], maxImageCount: fields[1], currentWidth: fields[2], currentHeight: fields[3],
                             minWidth: fields[4], minHeight: fields[5], maxWidth: fields[6], maxHeight: fields[7],
                             maxImageArrayLayers: fields[8], supportedTransforms: fields[9], currentTransform: fields[10],
                             supportedCompositeAlpha: fields[11], supportedUsageFlags: fields[12], formats: formats, modes: modes, queues: queues)
            }
            try require(status.querySucceeded || status.nativeErrno != 0 || (status.vkResult != nil && status.vkResult != 0), "capabilities require an actual result")
            body = .capabilities(request: request, status: status, value: caps)
        case .present:
            let serial = try r.u64(), device = try r.u64(), queue = try r.u64(), image = try r.u64()
            let format = try r.u32(), width = try r.u32(), height = try r.u32(), layout = try r.u32(), family = try r.u32(), count = try r.u32()
            try require(serial > 0 && device > 0 && queue > 0 && image > 0 && format > 0 && width > 0 && height > 0, "present fields")
            // Explicit virtual WSI uses actual GENERAL. Ordinary PRESENT_SRC is never rewritten here.
            try require(layout == 1 && count <= 64 && r.remaining == Int(count) * 8, "present layout or wait set")
            let waits = try (0..<count).map { _ in try r.u64() }
            try require(waits.allSatisfy { $0 != 0 } && Set(waits).count == waits.count, "invalid binary wait set")
            body = .present(.init(serial: serial, device: device, queue: queue, image: image, format: format,
                                  width: width, height: height, layout: layout, queueFamily: family, waits: waits))
        case .presentResult:
            let serial = try r.u64(), status = try r.status()
            guard let disposition = Disposition(rawValue: try r.u32()), let event = Event(rawValue: try r.u32()) else {
                throw invalid("present result enum")
            }
            try require(serial > 0, "present result serial")
            try require(event != .deviceLost || status.vkResult == -4, "device loss requires actual driver result")
            body = .presentResult(serial: serial, status: status, disposition: disposition, event: event)
        case .sourceReleased:
            let serial = try r.u64(); try require(serial > 0, "released serial")
            body = .sourceReleased(serial: serial)
        case .surfaceRetire: body = .retire
        case .surfaceRetired: body = .retired(try r.status())
        default: throw invalid("not a surface message")
        }
        try require(r.remaining == 0, "trailing surface bytes")
        return .init(identity: identity, body: body)
    }

    func encoded() throws -> Data {
        var w = Writer()
        w.data.append(identity.epoch); w.data.append(identity.grant); w.u64(identity.generation)
        switch body {
        case let .bind(window, instance, width, height):
            w.u64(window); w.u64(instance); w.u32(width); w.u32(height)
        case let .bound(status), let .retired(status): w.status(status)
        case let .query(request, physicalDevice): w.u64(request); w.u64(physicalDevice)
        case let .capabilities(request, status, caps):
            w.u64(request); w.status(status)
            try Self.require(status.querySucceeded == (caps != nil), "capabilities status and data disagree")
            if let c = caps {
                try Self.require(c.formats.count <= 4096 && c.modes.count <= 4096 && c.queues.count <= 4096, "surface capability count")
                for value in [c.minImageCount, c.maxImageCount, c.currentWidth, c.currentHeight, c.minWidth, c.minHeight,
                              c.maxWidth, c.maxHeight, c.maxImageArrayLayers, c.supportedTransforms, c.currentTransform,
                              c.supportedCompositeAlpha, c.supportedUsageFlags] { w.u32(value) }
                w.u32(UInt32(c.formats.count)); w.u32(UInt32(c.modes.count)); w.u32(UInt32(c.queues.count))
                for f in c.formats { w.u32(f.format); w.u32(f.colorSpace) }
                for m in c.modes { w.u32(m) }
                for q in c.queues { w.u32(q.family); w.u32(q.flags); w.u32(q.count); w.u32(q.supported ? 1 : 0) }
            }
        case let .present(p):
            try Self.require(p.waits.count <= 64, "present wait count")
            for value in [p.serial, p.device, p.queue, p.image] { w.u64(value) }
            for value in [p.format, p.width, p.height, p.layout, p.queueFamily, UInt32(p.waits.count)] { w.u32(value) }
            for wait in p.waits { w.u64(wait) }
        case let .presentResult(serial, status, disposition, event):
            w.u64(serial); w.status(status); w.u32(disposition.rawValue); w.u32(event.rawValue)
        case let .sourceReleased(serial): w.u64(serial)
        case .retire: break
        }
        // One parser defines the accepted wire shape for both directions.
        let decoded = try Self.decode(kind: kind, payload: w.data)
        try Self.require(decoded == self, "noncanonical surface message")
        return w.data
    }

    private static func invalid(_ reason: String) -> LiveGPUBindingError { .protocolViolation(reason) }
    private static func require(_ condition: Bool, _ reason: String) throws { if !condition { throw invalid(reason) } }
    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = Data(data) }
        var remaining: Int { data.count - offset }
        mutating func bytes(_ count: Int) throws -> Data {
            try require(count <= remaining, "truncated surface fields")
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
        mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let count = MemoryLayout<T>.size
            try require(count <= remaining, "truncated surface fields")
            defer { offset += count }
            return (0..<count).reduce(T(0)) { $0 | T(data[offset + $1]) << ($1 * 8) }
        }
        mutating func status() throws -> LiveGPUSurfaceStatus {
            let error = Int32(bitPattern: try u32()), present = try u32(), result = Int32(bitPattern: try u32()), reserved = try u32()
            try require(error >= 0 && present <= 1 && reserved == 0 && (present != 0 || result == 0), "surface status fields")
            return .init(nativeErrno: error, vkResult: present == 1 ? result : nil)
        }
    }
    private struct Writer {
        var data = Data()
        mutating func u32(_ value: UInt32) { integer(value) }
        mutating func u64(_ value: UInt64) { integer(value) }
        mutating func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        mutating func status(_ value: LiveGPUSurfaceStatus) {
            u32(UInt32(bitPattern: value.nativeErrno)); u32(value.vkResult == nil ? 0 : 1)
            u32(UInt32(bitPattern: value.vkResult ?? 0)); u32(0)
        }
    }
}
