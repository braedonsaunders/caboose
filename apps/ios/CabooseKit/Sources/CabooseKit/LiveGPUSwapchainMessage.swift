import Foundation

/// Indexed controls are parsed independently of driver availability. The v3
/// runtime must never negotiate the v4 acquire capability merely by importing this codec.
struct LiveGPUSwapchainCreate: Equatable, Sendable {
    let request: UInt64
    let device: UInt64
    let oldSwapchain: UInt64
    let flags: UInt32
    let minImageCount: UInt32
    let format: UInt32
    let colorSpace: UInt32
    let width: UInt32
    let height: UInt32
    let arrayLayers: UInt32
    let usage: UInt32
    let preTransform: UInt32
    let compositeAlpha: UInt32
    let presentMode: UInt32
    let clipped: Bool
    let sharingMode: UInt32
    let families: [UInt32]
}
struct LiveGPUSwapchainAcquire: Equatable, Sendable {
    let swapchain: UInt64
    let request: UInt64
    let semaphore: UInt64
    let fence: UInt64
    let timeoutNanoseconds: UInt64
    let deviceMask: UInt32
}
struct LiveGPUIndexedPresent: Equatable, Sendable {
    let swapchain: UInt64
    let serial: UInt64
    let queue: UInt64
    let index: UInt32
    let family: UInt32
    let layout: UInt32
    let waits: [UInt64]
}
enum LiveGPUAcquireLocalReason: UInt32, Sendable { case none, deadline, cancelled, other }

enum LiveGPUSwapchainMessage: Equatable, Sendable {
    case create(LiveGPUSwapchainCreate)
    case created(request: UInt64, swapchain: UInt64, status: LiveGPUSurfaceStatus, count: UInt32)
    case map(swapchain: UInt64, images: [UInt64])
    case mapped(swapchain: UInt64, status: LiveGPUSurfaceStatus)
    case acquire(LiveGPUSwapchainAcquire)
    case acquired(swapchain: UInt64, request: UInt64, status: LiveGPUSurfaceStatus,
                  index: UInt32?, reason: LiveGPUAcquireLocalReason)
    case cancelAcquire(swapchain: UInt64, request: UInt64)
    case retire(swapchain: UInt64)
    case retired(swapchain: UInt64, status: LiveGPUSurfaceStatus)
    case present(LiveGPUIndexedPresent)
    case revokeSurface
    case presentRetired(swapchain: UInt64, serial: UInt64)

    var kind: LiveGPUEnvelope.Kind {
        switch self {
        case .create: return .swapchainCreate
        case .created: return .swapchainCreated
        case .map: return .swapchainMap
        case .mapped: return .swapchainMapped
        case .acquire: return .swapchainAcquire
        case .acquired: return .swapchainAcquired
        case .cancelAcquire: return .swapchainCancelAcquire
        case .retire: return .swapchainRetire
        case .retired: return .swapchainRetired
        case .present: return .swapchainPresent
        case .revokeSurface: return .surfaceRevokeRequest
        case .presentRetired: return .presentRetired
        }
    }
    /// Length includes the common 40-byte identity. Reject overlarge arrays before buffering.
    static func validateLength(_ n: Int, kind: LiveGPUEnvelope.Kind) throws {
        let valid: Bool
        switch kind {
        case .swapchainCreate: valid = n >= 120 && n <= 376 && (n - 120) % 4 == 0
        case .swapchainCreated: valid = n == 80
        case .swapchainMap: valid = n >= 64 && n <= 2104 && (n - 56) % 8 == 0
        case .swapchainMapped, .swapchainRetired: valid = n == 64
        case .swapchainAcquire, .swapchainAcquired: valid = n == 88
        case .swapchainCancelAcquire, .presentRetired: valid = n == 56
        case .swapchainRetire: valid = n == 48
        case .swapchainPresent: valid = n >= 80 && n <= 592 && (n - 80) % 8 == 0
        case .surfaceRevokeRequest: valid = n == 40
        default: valid = false
        }
        try check(valid, "indexed payload length")
    }
    /// Input excludes the common identity, already checked by the surface codec.
    static func decode(kind: LiveGPUEnvelope.Kind, fields: Data) throws -> Self {
        try validateLength(fields.count + 40, kind: kind)
        var r = Reader(fields)
        let value: Self
        switch kind {
        case .swapchainCreate:
            let request = try r.u64(), device = try r.u64(), old = try r.u64()
            let f = try (0..<14).map { _ in try r.u32() }
            try check(request > 0 && device > 0, "create identity")
            try check([1, 2, 4, 5, 6, 7].allSatisfy { f[$0] > 0 }, "create parameters")
            try check(f[11] <= 1 && f[12] <= 1 && f[13] <= 64, "create enum/count")
            try check(r.remaining == Int(f[13]) * 4, "create family length")
            let families = try (0..<f[13]).map { _ in try r.u32() }
            try check(Set(families).count == families.count, "duplicate families")
            try check((f[12] == 0 && families.isEmpty) || (f[12] == 1 && families.count >= 2), "sharing families")
            value = .create(.init(request: request, device: device, oldSwapchain: old, flags: f[0],
                minImageCount: f[1], format: f[2], colorSpace: f[3], width: f[4], height: f[5],
                arrayLayers: f[6], usage: f[7], preTransform: f[8], compositeAlpha: f[9],
                presentMode: f[10], clipped: f[11] == 1, sharingMode: f[12], families: families))
        case .swapchainCreated:
            let request = try r.u64(), swapchain = try r.u64(), status = try r.status(), count = try r.u32()
            try check(request > 0 && (try r.u32()) == 0, "created identity/reserved")
            if status.querySucceeded { try check(swapchain > 0 && (1...256).contains(count), "actual image count") }
            else {
                try check(status.nativeErrno > 0 || (status.vkResult != nil && status.vkResult != 0), "creation requires actual result")
                try check(swapchain == 0 && count == 0, "failed create has resources")
            }
            value = .created(request: request, swapchain: swapchain, status: status, count: count)
        case .swapchainMap:
            let swapchain = try r.u64(), count = try r.u32(), reserved = try r.u32()
            try check(swapchain > 0 && (1...256).contains(count) && reserved == 0 && r.remaining == Int(count) * 8, "map fields")
            let images = try (0..<count).map { _ in try r.u64() }
            try check(images.allSatisfy { $0 > 0 } && Set(images).count == images.count, "source image identities")
            value = .map(swapchain: swapchain, images: images)
        case .swapchainMapped, .swapchainRetired:
            let swapchain = try r.u64(), status = try r.status()
            try check(swapchain > 0, "swapchain identity")
            value = kind == .swapchainMapped ? .mapped(swapchain: swapchain, status: status) : .retired(swapchain: swapchain, status: status)
        case .swapchainAcquire:
            let swapchain = try r.u64(), request = try r.u64(), semaphore = try r.u64(), fence = try r.u64(), timeout = try r.u64()
            let mask = try r.u32(), reserved = try r.u32()
            try check(swapchain > 0 && request > 0 && (semaphore > 0 || fence > 0) && mask == 1 && reserved == 0, "acquire fields")
            value = .acquire(.init(swapchain: swapchain, request: request, semaphore: semaphore,
                                  fence: fence, timeoutNanoseconds: timeout, deviceMask: mask))
        case .swapchainAcquired:
            let swapchain = try r.u64(), request = try r.u64(), status = try r.status()
            let hasIndex = try r.u32(), index = try r.u32(), rawReason = try r.u32(), reserved = try r.u32()
            guard let reason = LiveGPUAcquireLocalReason(rawValue: rawReason) else { throw invalid("acquire reason") }
            let success = status.nativeErrno == 0 && (status.vkResult == 0 || status.vkResult == 1000001003)
            try check(swapchain > 0 && request > 0 && reserved == 0, "acquired identity/reserved")
            try check(hasIndex == (success ? 1 : 0) && (success ? index < 256 : index == 0), "acquired index")
            try check(status.nativeErrno > 0 || status.vkResult != nil, "acquire requires actual result")
            try check((reason == .none && status.nativeErrno == 0) ||
                (reason != .none && status.nativeErrno > 0 && status.vkResult == nil), "acquire result provenance")
            value = .acquired(swapchain: swapchain, request: request, status: status,
                              index: success ? index : nil, reason: reason)
        case .swapchainCancelAcquire:
            let swapchain = try r.u64(), request = try r.u64()
            try check(swapchain > 0 && request > 0, "cancel identity")
            value = .cancelAcquire(swapchain: swapchain, request: request)
        case .swapchainRetire:
            let swapchain = try r.u64(); try check(swapchain > 0, "retire identity")
            value = .retire(swapchain: swapchain)
        case .swapchainPresent:
            let swapchain = try r.u64(), serial = try r.u64(), queue = try r.u64()
            let index = try r.u32(), family = try r.u32(), layout = try r.u32(), count = try r.u32()
            try check(swapchain > 0 && serial > 0 && queue > 0 && index < 256 && layout == 1 && count <= 64,
                      "indexed present fields")
            try check(r.remaining == Int(count) * 8, "indexed waits length")
            let waits = try (0..<count).map { _ in try r.u64() }
            try check(waits.allSatisfy { $0 > 0 } && Set(waits).count == waits.count, "indexed waits")
            value = .present(.init(swapchain: swapchain, serial: serial, queue: queue, index: index,
                                  family: family, layout: layout, waits: waits))
        case .presentRetired:
            let swapchain = try r.u64(), serial = try r.u64()
            try check(swapchain > 0 && serial > 0, "retired frame identity")
            value = .presentRetired(swapchain: swapchain, serial: serial)
        case .surfaceRevokeRequest: value = .revokeSurface
        default: throw invalid("not an indexed control")
        }
        try check(r.remaining == 0, "trailing indexed fields")
        return value
    }
    func encodedFields() throws -> Data {
        var w = Writer()
        switch self {
        case .create(let c):
            try Self.check(c.families.count <= 64, "family limit")
            for v in [c.request, c.device, c.oldSwapchain] { w.u64(v) }
            for v in [c.flags, c.minImageCount, c.format, c.colorSpace, c.width, c.height, c.arrayLayers,
                      c.usage, c.preTransform, c.compositeAlpha, c.presentMode, c.clipped ? 1 : 0,
                      c.sharingMode, UInt32(c.families.count)] { w.u32(v) }
            for v in c.families { w.u32(v) }
        case let .created(request, swapchain, status, count):
            w.u64(request); w.u64(swapchain); w.status(status); w.u32(count); w.u32(0)
        case let .map(swapchain, images):
            try Self.check(images.count <= 256, "image limit")
            w.u64(swapchain); w.u32(UInt32(images.count)); w.u32(0)
            for v in images { w.u64(v) }
        case let .mapped(swapchain, status), let .retired(swapchain, status): w.u64(swapchain); w.status(status)
        case .acquire(let a):
            for v in [a.swapchain, a.request, a.semaphore, a.fence, a.timeoutNanoseconds] { w.u64(v) }
            w.u32(a.deviceMask); w.u32(0)
        case let .acquired(swapchain, request, status, index, reason):
            w.u64(swapchain); w.u64(request); w.status(status)
            w.u32(index == nil ? 0 : 1); w.u32(index ?? 0); w.u32(reason.rawValue); w.u32(0)
        case let .cancelAcquire(swapchain, request): w.u64(swapchain); w.u64(request)
        case .retire(let swapchain): w.u64(swapchain)
        case .present(let p):
            try Self.check(p.waits.count <= 64, "wait limit")
            for v in [p.swapchain, p.serial, p.queue] { w.u64(v) }
            for v in [p.index, p.family, p.layout, UInt32(p.waits.count)] { w.u32(v) }
            for v in p.waits { w.u64(v) }
        case .presentRetired(let swapchain, let serial): w.u64(swapchain); w.u64(serial)
        case .revokeSurface: break
        }
        try Self.check(try Self.decode(kind: kind, fields: w.data) == self, "noncanonical indexed control")
        return w.data
    }
    private static func invalid(_ reason: String) -> LiveGPUBindingError { .protocolViolation(reason) }
    private static func check(_ valid: Bool, _ reason: String) throws { if !valid { throw invalid(reason) } }
    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = Data(data) }
        var remaining: Int { data.count - offset }
        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            try check(remaining >= n, "truncated indexed fields")
            defer { offset += n }
            return (0..<n).reduce(T(0)) { $0 | T(data[offset + $1]) << ($1 * 8) }
        }
        mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
        mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
        mutating func status() throws -> LiveGPUSurfaceStatus {
            let error = Int32(bitPattern: try u32()), has = try u32(), result = Int32(bitPattern: try u32()), reserved = try u32()
            try check(error >= 0 && has <= 1 && reserved == 0 && (has == 1 || result == 0), "indexed status")
            return .init(nativeErrno: error, vkResult: has == 1 ? result : nil)
        }
    }
    private struct Writer {
        var data = Data()
        mutating func integer<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        mutating func u32(_ value: UInt32) { integer(value) }
        mutating func u64(_ value: UInt64) { integer(value) }
        mutating func status(_ s: LiveGPUSurfaceStatus) {
            u32(UInt32(bitPattern: s.nativeErrno)); u32(s.vkResult == nil ? 0 : 1)
            u32(UInt32(bitPattern: s.vkResult ?? 0)); u32(0)
        }
    }
}
