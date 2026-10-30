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
#include <chrono>
#include <cstdio>
#endif

namespace caboose::gpuv2 {
#ifdef CABOOSE_GPU_MEMORY_AUDIT
namespace {
std::atomic_uint64_t timingStreams{0};
std::atomic_uint timingRecords{0};
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
    auto finish = [&](DecodeStage stage, int result) {
        if (diagnostic) {
            diagnostic->stage = stage;
            diagnostic->socketError = stream.error();
            diagnostic->eof = stream.eof();
            diagnostic->stopped = stop.load();
        }
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
            const size_t got = stream.read(pending.data() + old, request);
            pending.resize(old + got);
            snapshot();
            return got != 0;
        };
        // This must be the same immutable feature used by VkDecoder at construction.
        const bool sequenced = gfxstream::host::FrameBuffer::getFB()->getFeatures()
                                   .VulkanQueueSubmitWithCommands.enabled();
#ifdef CABOOSE_GPU_MEMORY_AUDIT
        const bool auditTiming = gfxstream::host::FrameBuffer::getFB()->getFeatures().CabooseMemoryAudit.enabled();
        const uint64_t timingStream = auditTiming ? timingStreams.fetch_add(1) + 1 : 0;
#endif
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
            const auto decodeStart = auditTiming ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
#endif
            const size_t consumed = thread_info.m_vkInfo->m_vkDec.decode(
                pending.data(), frame.size, &stream, thread_info.getProcessResources().get(), context);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            if (auditTiming) {
                const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - decodeStart).count();
                if (elapsed >= 50000) {
                    unsigned ordinal = timingRecords.load();
                    while (ordinal <= 64 && !timingRecords.compare_exchange_weak(ordinal, ordinal + 1)) {}
                    if (ordinal < 64) {
                        uint32_t opcode = 0;
                        std::memcpy(&opcode, pending.data(), sizeof(opcode));
                        // This pinned unsequenced command has two numeric ordering fields
                        // after its opaque handle. Never record the handle or other payload.
                        uint32_t needSync = 0, sequence = 0;
                        const bool hostSync = !sequenced && opcode == 20324 && frame.size == 24;
                        if (hostSync) {
                            std::memcpy(&needSync, pending.data() + 16, 4);
                            std::memcpy(&sequence, pending.data() + 20, 4);
                        }
                        std::fprintf(stderr, "CABOOSE_GPU_DECODE_TIMING stream=%llu opcode=%u elapsed_us=%lld host_sync=%u need_sync=%u sequence=%u\n",
                            static_cast<unsigned long long>(timingStream), opcode,
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
            if (stream.flush() < 0) return finish(DecodeStage::flush, stream.error() ? stream.error() : EIO);
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
