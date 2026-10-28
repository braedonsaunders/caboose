import AudioToolbox
import Foundation
#if os(iOS)
import AVFAudio
#endif

/// Plays the computer's sound: Xpra's `audio-data` packets carry an MP3 stream, cut at
/// arbitrary points. AudioFileStream finds the frames and AudioQueue decodes and plays
/// them, so the system routes the sound like any other app's (speaker, AirPods, AirPlay).
///
/// Everything runs on one serial queue, off the main actor. Latency stays bounded: data that
/// arrives while more than `maximumQueued` buffers are waiting is dropped, so a stall never
/// turns into a growing delay between the picture and the sound.
public final class AudioStream: @unchecked Sendable {
    public static let codec = "mp3"

    private let queue = DispatchQueue(label: "caboose.audio", qos: .userInteractive)
    private var stream: AudioFileStreamID?
    private var output: AudioQueueRef?
    private var free: [AudioQueueBufferRef] = []
    private var queued = 0
    private var started = false
    private static let bufferSize: UInt32 = 32 * 1024
    private static let maximumPackets = 512
    private static let maximumQueued = 8
    private static let prerollBuffers = 2

    /// Running counts, for the diagnostics line.
    public struct Stats: Sendable, CustomStringConvertible {
        public var chunks = 0, bytes = 0, packets = 0, enqueued = 0, dropped = 0
        public var format = "none", openStatus: OSStatus = 0, outputStatus: OSStatus = 0, startStatus: OSStatus = 0, parseStatus: OSStatus = 0
        public var started = false
        public var description: String {
            "chunks=\(chunks) bytes=\(bytes) packets=\(packets) enqueued=\(enqueued) dropped=\(dropped) format=\(format) " +
                "open=\(openStatus) output=\(outputStatus) parse=\(parseStatus) start=\(startStatus) started=\(started)"
        }
    }
    private var counters = Stats()
    public var stats: Stats { queue.sync { counters } }

    public init() {}

    deinit {
        if let output { AudioQueueDispose(output, true) }
        if let stream { AudioFileStreamClose(stream) }
    }

    /// Feeds the next piece of the stream; safe to call from any thread.
    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            counters.chunks += 1
            counters.bytes += data.count
            if stream == nil { open() }
            guard let stream, queued <= Self.maximumQueued else { counters.dropped += 1; return }
            data.withUnsafeBytes { bytes in
                counters.parseStatus = AudioFileStreamParseBytes(stream, UInt32(bytes.count), bytes.baseAddress, [])
            }
        }
    }

    /// Stops playback and forgets the stream; the next `append` starts a new one.
    public func stop() {
        queue.async { [self] in
            if let output { AudioQueueDispose(output, true) }
            if let stream { AudioFileStreamClose(stream) }
            output = nil
            stream = nil
            free = []
            queued = 0
            started = false
        }
    }

    private func open() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        counters.openStatus = AudioFileStreamOpen(context, { context, stream, property, _ in
            let player = Unmanaged<AudioStream>.fromOpaque(context).takeUnretainedValue()
            if property == kAudioFileStreamProperty_ReadyToProducePackets { player.makeOutput(stream) }
        }, { context, byteCount, packetCount, bytes, descriptions in
            let player = Unmanaged<AudioStream>.fromOpaque(context).takeUnretainedValue()
            guard let descriptions else { return }
            player.enqueue(bytes, byteCount: byteCount, packets: UnsafeBufferPointer(start: descriptions, count: Int(packetCount)))
        }, kAudioFileMP3Type, &stream)
    }

    private func makeOutput(_ stream: AudioFileStreamID) {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &format) == noErr else { return }
        counters.format = "\(Int(format.mSampleRate))Hz/\(format.mChannelsPerFrame)ch"
        let context = Unmanaged.passUnretained(self).toOpaque()
        var queueRef: AudioQueueRef?
        let status = AudioQueueNewOutput(&format, { context, queueRef, buffer in
            let player = Unmanaged<AudioStream>.fromOpaque(context!).takeUnretainedValue()
            player.queue.async { player.recycle(buffer) }
        }, context, nil, nil, 0, &queueRef)
        counters.outputStatus = status
        guard status == noErr, let queueRef else { return }
        output = queueRef
    }

    /// Called on `queue` (from AudioFileStreamParseBytes) with whole MP3 packets.
    private func enqueue(_ bytes: UnsafeRawPointer, byteCount: UInt32, packets: UnsafeBufferPointer<AudioStreamPacketDescription>) {
        guard let output else { return }
        var index = 0
        while index < packets.count {
            guard let buffer = takeBuffer(output) else { return }
            var used: UInt32 = 0
            var count = 0
            while index < packets.count, count < Self.maximumPackets {
                let packet = packets[index]
                guard used + packet.mDataByteSize <= buffer.pointee.mAudioDataBytesCapacity else { break }
                memcpy(buffer.pointee.mAudioData + Int(used), bytes + Int(packet.mStartOffset), Int(packet.mDataByteSize))
                buffer.pointee.mPacketDescriptions?[count] = AudioStreamPacketDescription(
                    mStartOffset: Int64(used), mVariableFramesInPacket: packet.mVariableFramesInPacket, mDataByteSize: packet.mDataByteSize)
                used += packet.mDataByteSize
                count += 1
                index += 1
            }
            guard count > 0 else { free.append(buffer); return }
            buffer.pointee.mAudioDataByteSize = used
            buffer.pointee.mPacketDescriptionCount = UInt32(count)
            counters.packets += count
            if AudioQueueEnqueueBuffer(output, buffer, 0, nil) == noErr { queued += 1; counters.enqueued += 1 } else { free.append(buffer) }
        }
        if !started, queued >= Self.prerollBuffers {
            Self.activateSession()
            counters.startStatus = AudioQueueStart(output, nil)
            started = counters.startStatus == noErr
            counters.started = started
        }
    }

    /// AudioQueue will not start in an inactive session on iOS; make sure it is active.
    private static func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    private func takeBuffer(_ output: AudioQueueRef) -> AudioQueueBufferRef? {
        if let buffer = free.popLast() { return buffer }
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBufferWithPacketDescriptions(output, Self.bufferSize, UInt32(Self.maximumPackets), &buffer) == noErr else { return nil }
        return buffer
    }

    private func recycle(_ buffer: AudioQueueBufferRef) {
        queued = max(0, queued - 1)
        free.append(buffer)
    }
}
