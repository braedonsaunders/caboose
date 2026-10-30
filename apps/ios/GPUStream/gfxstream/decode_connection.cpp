// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "decode_connection.h"
#include "socket_stream.h"
#include "packet_framing.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"
#include "render_thread_info.h"
#include "vk_decoder_context.h"
#include "gfxstream/host/GfxApiLogger.h"
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "decode_timing_aggregate.h"
#include <chrono>
#include <cstdio>
#endif

namespace caboose::gpuv2 {
#ifdef CABOOSE_GPU_MEMORY_AUDIT
namespace {
std::atomic_uint64_t timingStreams{0};
std::atomic_uint timingRecords{0};
DecodeTimingBudget<64> streamAggregateBudget;
DecodeTimingBudget<128> periodAggregateBudget;

uint64_t steadyNowMicroseconds() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

void printAggregateLine(const char* prefix, unsigned ordinal, uint64_t stream,
                        uint64_t elapsed_us, const DecodeTimingSnapshot& snap,
                        DecodeStage stage, int result) {
    std::fprintf(stderr,
        "%s ordinal=%u stream=%llu elapsed_us=%llu stage=%u result=%d "
        "decode_count=%llu decode_sum_us=%llu decode_max_us=%llu "
        "flush20025_count=%llu flush20025_sum_us=%llu flush20025_max_us=%llu "
        "read_count=%llu read_sum_us=%llu read_max_us=%llu read_bytes=%llu "
        "flush_count=%llu flush_sum_us=%llu flush_max_us=%llu\n",
        prefix, ordinal, static_cast<unsigned long long>(stream),
        static_cast<unsigned long long>(elapsed_us),
        static_cast<unsigned>(stage), result,
        static_cast<unsigned long long>(snap.decode_all.count),
        static_cast<unsigned long long>(snap.decode_all.sum_us),
        static_cast<unsigned long long>(snap.decode_all.max_us),
        static_cast<unsigned long long>(snap.decode_20025.count),
        static_cast<unsigned long long>(snap.decode_20025.sum_us),
        static_cast<unsigned long long>(snap.decode_20025.max_us),
        static_cast<unsigned long long>(snap.read_wait.count),
        static_cast<unsigned long long>(snap.read_wait.sum_us),
        static_cast<unsigned long long>(snap.read_wait.max_us),
        static_cast<unsigned long long>(snap.read_bytes),
        static_cast<unsigned long long>(snap.flush.count),
        static_cast<unsigned long long>(snap.flush.sum_us),
        static_cast<unsigned long long>(snap.flush.max_us));
}
}
#endif
#ifdef CABOOSE_GPU_DECODER_TESTING
namespace { thread_local DecodeDiagnostic testingDiagnostic; }
DecodeDiagnostic lastDecodeDiagnosticForTesting() { return testingDiagnostic; }
#endif
int decodeConnection(int fd, size_t max_packet, size_t max_reply_buffer,
                     gfxstream::host::RenderThreadInfo& thread_info,
                     std::atomic_bool& stop, bool synchronousOnly, uint64_t* decoderEntries,
                     DecodeDiagnostic* diagnostic) {
#ifdef CABOOSE_GPU_DECODER_TESTING
    if (!diagnostic) diagnostic = &testingDiagnostic;
    struct SaveDiagnostic {
        DecodeDiagnostic* value;
        ~SaveDiagnostic() { testingDiagnostic = *value; }
    } save{diagnostic};
#endif
    if (diagnostic) *diagnostic = {};
    if (fd < 0 || max_packet < 8 || max_packet > 400u * 1024u * 1024u ||
        max_reply_buffer < 4096 || !thread_info.m_vkInfo || !thread_info.getProcessResources()) return EINVAL;
    SocketStream stream(fd, max_reply_buffer);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
    const bool auditTiming = gfxstream::host::FrameBuffer::getFB() &&
                             gfxstream::host::FrameBuffer::getFB()->getFeatures().CabooseMemoryAudit.enabled();
    const uint64_t timingStream = auditTiming ? timingStreams.fetch_add(1) + 1 : 0;
    const uint64_t streamStartUs = auditTiming ? steadyNowMicroseconds() : 0;
    DecodeTimingAggregator timingAggregate(streamStartUs);
    auto maybeFlushPeriod = [&](uint64_t nowUs) {
        if (!auditTiming) return;
        DecodeTimingSnapshot periodSnap{};
        uint64_t periodElapsedUs = 0;
        if (timingAggregate.pollPeriod(nowUs, periodSnap, periodElapsedUs)) {
            const unsigned ordinal = periodAggregateBudget.take();
            if (ordinal < 128) {
                printAggregateLine("CABOOSE_GPU_DECODE_PERIOD", ordinal, timingStream,
                                   periodElapsedUs, periodSnap, DecodeStage::decoder, 0);
            } else if (ordinal == 128) {
                std::fprintf(stderr, "CABOOSE_GPU_DECODE_PERIOD limit=128\n");
            }
        }
    };
#endif
    auto finish = [&](DecodeStage stage, int result) {
        if (diagnostic) {
            diagnostic->stage = stage;
            diagnostic->socketError = stream.error();
            diagnostic->eof = stream.eof();
            diagnostic->stopped = stop.load();
        }
#ifdef CABOOSE_GPU_MEMORY_AUDIT
        if (auditTiming) {
            const uint64_t nowUs = steadyNowMicroseconds();
            const uint64_t elapsedUs = nowUs >= streamStartUs ? nowUs - streamStartUs : 0;
            const unsigned ordinal = streamAggregateBudget.take();
            if (ordinal < 64) {
                printAggregateLine("CABOOSE_GPU_DECODE_STREAM", ordinal, timingStream,
                                   elapsedUs, timingAggregate.total(), stage, result);
            } else if (ordinal == 64) {
                std::fprintf(stderr, "CABOOSE_GPU_DECODE_STREAM limit=64\n");
            }
        }
#endif
        return result;
    };
    uint32_t flags;
    if (!stream.readFully(&flags, sizeof(flags))) return finish(DecodeStage::flags, stop ? 0 : stream.error());
    // Pinned upstream RenderThread consumes but does not interpret this word.
    (void)flags;
    gfxstream::host::GfxApiLogger logger;
    gfxstream::host::vk::VkDecoderContext context{};
    context.gfxApiLogger = &logger;
    context.shouldExit = &stop;

    try {
        std::vector<unsigned char> pending;
        auto snapshot = [&] {
            if (!diagnostic) return;
            diagnostic->buffered = pending.size();
            diagnostic->headerPresent = pending.size() >= 8;
            diagnostic->opcode = diagnostic->declared = 0;
            if (diagnostic->headerPresent) {
                std::memcpy(&diagnostic->opcode, pending.data(), 4);
                std::memcpy(&diagnostic->declared, pending.data() + 4, 4);
            }
        };
        auto readMore = [&](size_t request) -> bool {
            const size_t old = pending.size();
            pending.resize(old + request);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            const uint64_t readStartUs = auditTiming ? steadyNowMicroseconds() : 0;
#endif
            const size_t got = stream.read(pending.data() + old, request);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            if (auditTiming) {
                const uint64_t readEndUs = steadyNowMicroseconds();
                timingAggregate.recordRead(got, readEndUs >= readStartUs ? readEndUs - readStartUs : 0);
                maybeFlushPeriod(readEndUs);
            }
#endif
            pending.resize(old + got);
            snapshot();
            return got != 0;
        };
        // This must be the same immutable feature used by VkDecoder at construction.
        const bool sequenced = gfxstream::host::FrameBuffer::getFB()->getFeatures()
                                   .VulkanQueueSubmitWithCommands.enabled();
        while (!stop.load()) {
            snapshot();
            if (diagnostic) { diagnostic->frameSize = 0; diagnostic->consumed = 0; diagnostic->frame = {}; }
            if (synchronousOnly && pending.size() >= 8) {
                uint32_t opcode = 0;
                std::memcpy(&opcode, pending.data(), sizeof(opcode));
                if (forbiddenV4Opcode(opcode)) return finish(DecodeStage::profile, ENOTSUP);
            }
            const auto frame = inspectFrame(pending.data(), pending.size(), max_packet, sequenced,
                                            diagnostic ? &diagnostic->frame : nullptr);
            if (diagnostic) diagnostic->frameSize = frame.size;
            if (frame.status == FrameStatus::invalid) return finish(DecodeStage::framing, EPROTO);
            if (frame.status == FrameStatus::unsupported) return finish(DecodeStage::unsupportedFrame, ENOTSUP);
            if (frame.status == FrameStatus::need_more) {
                if (frame.size <= pending.size() || frame.size > max_packet) return finish(DecodeStage::framing, EPROTO);
                if (!readMore(frame.size - pending.size())) {
                    if (stop) return finish(DecodeStage::stopped, 0);
                    if (stream.error()) return finish(DecodeStage::input, stream.error());
                    if (stream.eof()) return finish(DecodeStage::eof, pending.empty() ? 0 : EPROTO);
                    return finish(DecodeStage::input, EIO);
                }
                continue;
            }
            if (diagnostic) diagnostic->stage = DecodeStage::decoder;
            if (decoderEntries) ++*decoderEntries;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            uint32_t frameOpcode = 0;
            if (auditTiming && frame.size >= sizeof(frameOpcode)) {
                std::memcpy(&frameOpcode, pending.data(), sizeof(frameOpcode));
            }
            const auto decodeStart = auditTiming ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
#endif
            const size_t consumed = thread_info.m_vkInfo->m_vkDec.decode(
                pending.data(), frame.size, &stream, thread_info.getProcessResources().get(), context);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            if (auditTiming) {
                const auto decodeEnd = std::chrono::steady_clock::now();
                const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                    decodeEnd - decodeStart).count();
                timingAggregate.recordDecode(frameOpcode, elapsed > 0 ? static_cast<uint64_t>(elapsed) : 0);
                if (elapsed >= 50000) {
                    unsigned ordinal = timingRecords.load();
                    while (ordinal <= 64 && !timingRecords.compare_exchange_weak(ordinal, ordinal + 1)) {}
                    if (ordinal < 64) {
                        // This pinned unsequenced command has two numeric ordering fields
                        // after its opaque handle. Never record the handle or other payload.
                        uint32_t needSync = 0, sequence = 0;
                        const bool hostSync = !sequenced && frameOpcode == 20324 && frame.size == 24;
                        if (hostSync) {
                            std::memcpy(&needSync, pending.data() + 16, 4);
                            std::memcpy(&sequence, pending.data() + 20, 4);
                        }
                        std::fprintf(stderr, "CABOOSE_GPU_DECODE_TIMING stream=%llu opcode=%u elapsed_us=%lld host_sync=%u need_sync=%u sequence=%u\n",
                            static_cast<unsigned long long>(timingStream), frameOpcode,
                            static_cast<long long>(elapsed), hostSync ? 1u : 0u, needSync, sequence);
                    } else if (ordinal == 64) {
                        std::fprintf(stderr, "CABOOSE_GPU_DECODE_TIMING limit=64\n");
                    }
                }
            }
#endif
            if (diagnostic) diagnostic->consumed = consumed;
            if (stream.error()) return finish(DecodeStage::decoder, stream.error());
            // Never retry a command after entering the decoder: a retry can
            // repeat side effects, including writes from earlier flush ranges.
            if (consumed != frame.size) return finish(DecodeStage::consumption, EPROTO);
            pending.erase(pending.begin(), pending.begin() + consumed);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            const uint64_t flushStartUs = auditTiming ? steadyNowMicroseconds() : 0;
#endif
            const int flushResult = stream.flush();
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            if (auditTiming) {
                const uint64_t flushEndUs = steadyNowMicroseconds();
                timingAggregate.recordFlush(flushEndUs >= flushStartUs ? flushEndUs - flushStartUs : 0);
                maybeFlushPeriod(flushEndUs);
            }
#endif
            if (flushResult < 0) return finish(DecodeStage::flush, stream.error() ? stream.error() : EIO);
            if (diagnostic) {
                diagnostic->lastOpcodePresent = diagnostic->headerPresent;
                diagnostic->lastOpcode = diagnostic->opcode;
                ++diagnostic->completed;
            }
        }
    } catch (const std::bad_alloc&) { return finish(DecodeStage::allocation, ENOMEM); }
      catch (...) { finish(DecodeStage::exception, EIO); throw; }
    return finish(DecodeStage::stopped, 0);
}
}
