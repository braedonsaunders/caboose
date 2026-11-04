// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "decode_connection.h"
#include "media_latch.h"
#include "media_session.h"
#include "socket_stream.h"
#include "packet_framing.h"
#include "completion_feed.h"
#include "executor_gate.h"
#include "shader_store.h"
#include "upload_store.h"
#include "frame_buffer.h"
#include "gfxstream/host/features.h"
#include "render_thread_info.h"
#include "vk_decoder_context.h"
#include "gfxstream/host/GfxApiLogger.h"
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <vector>
#ifdef CABOOSE_GPU_MEMORY_AUDIT
#include "decode_timing_aggregate.h"
#include <chrono>
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
        "gfxpipe20065_count=%llu gfxpipe20065_sum_us=%llu gfxpipe20065_max_us=%llu "
        "cmppipe20021_count=%llu cmppipe20021_sum_us=%llu cmppipe20021_max_us=%llu "
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
        static_cast<unsigned long long>(snap.decode_20065.count),
        static_cast<unsigned long long>(snap.decode_20065.sum_us),
        static_cast<unsigned long long>(snap.decode_20065.max_us),
        static_cast<unsigned long long>(snap.decode_20021.count),
        static_cast<unsigned long long>(snap.decode_20021.sum_us),
        static_cast<unsigned long long>(snap.decode_20021.max_us),
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
DecodeProgress*& currentDecodeProgress() {
    thread_local DecodeProgress* progress = nullptr;
    return progress;
}
int decodeConnection(int fd, size_t max_packet, size_t max_reply_buffer,
                     gfxstream::host::RenderThreadInfo& thread_info,
                     std::atomic_bool& stop, bool synchronousOnly, uint64_t* decoderEntries,
                     DecodeDiagnostic* diagnostic, CompletionFeed* completions) {
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
    // Each command passes the suspension gate (docs/gpu-live.md, "Suspending an executor").
    auto& gate = ExecutorGate::instance();
    ExecutorGate::Thread gateThread(gate);
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
        if (timingAggregate.pollPeriod(nowUs, periodSnap, periodElapsedUs, 1000000ull)) {
            // Every second for a stream that decoded at least 1% of it (a busy stream's time
            // splits into decode, waiting for the guest's next data, and the rest); the
            // budget holds only the quiet streams' lines.
            const bool busy = periodSnap.decode_all.sum_us * 100 >= periodElapsedUs;
            const unsigned ordinal = busy ? 0 : periodAggregateBudget.take();
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
    // A media stream (docs/gpu-media.md) names itself in place of the client flags; it is
    // decoded by the platform's media decoder, not the Vulkan decoder.
    if (flags == media::kStreamFlags)
        return finish(DecodeStage::stopped, media::runMediaSession(fd, stop, media::platformDecoders()));
    // Pinned upstream RenderThread consumes but does not interpret this word.
    const uint32_t contextId = static_cast<uint32_t>(thread_info.getPuid());
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
        DecodeProgress* progress = currentDecodeProgress();
        auto passGate = [&] {
            if (progress) progress->stage = 4;
            return gate.pass(stop);
        };
        auto readMore = [&](size_t request) -> bool {
            if (progress) progress->stage = 3;
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
        bool decodedAny = false;
        while (!stop.load()) {
            snapshot();
            if (diagnostic) { diagnostic->frameSize = 0; diagnostic->consumed = 0; diagnostic->frame = {}; }
            // Caboose completion feed, shader inventory and video LATCH packets are not Vulkan commands:
            // they are handled here, in stream order, never by the decoder.
            if (pending.size() >= 8) {
                uint32_t opcode = 0, declared = 0;
                std::memcpy(&opcode, pending.data(), sizeof(opcode));
                std::memcpy(&declared, pending.data() + 4, sizeof(declared));
                if (opcode == media::kLatchOpcode) {
                    if (declared < media::kLatchHead || declared > max_packet) return finish(DecodeStage::framing, EPROTO);
                    if (pending.size() < declared) {
                        if (!readMore(declared - pending.size())) {
                            if (stop) return finish(DecodeStage::stopped, 0);
                            if (stream.error()) return finish(DecodeStage::input, stream.error());
                            return finish(DecodeStage::eof, EPROTO);
                        }
                        continue;
                    }
                    if (!passGate()) return finish(DecodeStage::stopped, 0);
                    if (executeLatch(contextId, pending.data(), declared) != 0) return finish(DecodeStage::framing, EPROTO);
                    pending.erase(pending.begin(), pending.begin() + declared);
                    decodedAny = true;
                    continue;
                }
                // SHADER_INVENTORY: the keys of the modules the phone's store holds, so the
                // process can name them by token (docs/gpu-live.md, "Shader cache").
                if (opcode == kShaderInventoryOpcode) {
                    if (declared != kShaderInventoryPacketBytes) return finish(DecodeStage::framing, EPROTO);
                    if (pending.size() < declared) {
                        if (!readMore(declared - pending.size())) {
                            if (stop) return finish(DecodeStage::stopped, 0);
                            if (stream.error()) return finish(DecodeStage::input, stream.error());
                            return finish(DecodeStage::eof, EPROTO);
                        }
                        continue;
                    }
                    if (!parseShaderInventoryPacket(pending.data(), declared))
                        return finish(DecodeStage::framing, EPROTO);
                    if (!passGate()) return finish(DecodeStage::stopped, 0);
                    const auto store = currentShaderStore();
                    const auto reply = encodeShaderInventoryReply(store ? store->inventory() : std::vector<ShaderKey>{});
                    stream.writeFully(reply.data(), reply.size());
                    if (stream.error()) return finish(DecodeStage::flush, stream.error());
                    pending.erase(pending.begin(), pending.begin() + declared);
                    decodedAny = true;
                    continue;
                }
                // UPLOAD_INVENTORY: the prefixes of the pieces the phone's upload store holds and
                // how many the process may still ask it to store (docs/gpu-live.md, "Upload cache").
                if (opcode == kUploadInventoryOpcode) {
                    if (declared != kUploadInventoryPacketBytes) return finish(DecodeStage::framing, EPROTO);
                    if (pending.size() < declared) {
                        if (!readMore(declared - pending.size())) {
                            if (stop) return finish(DecodeStage::stopped, 0);
                            if (stream.error()) return finish(DecodeStage::input, stream.error());
                            return finish(DecodeStage::eof, EPROTO);
                        }
                        continue;
                    }
                    if (!parseUploadInventoryPacket(pending.data(), declared))
                        return finish(DecodeStage::framing, EPROTO);
                    if (!passGate()) return finish(DecodeStage::stopped, 0);
                    const auto store = currentUploadStore();
                    const auto reply = store ? encodeUploadInventoryReply(store->inventory(), store->allowance())
                                             : encodeUploadInventoryReply({}, 0);
                    stream.writeFully(reply.data(), reply.size());
                    if (stream.error()) return finish(DecodeStage::flush, stream.error());
                    pending.erase(pending.begin(), pending.begin() + declared);
                    decodedAny = true;
                    continue;
                }
                if (CompletionFeed::isFeedOpcode(opcode)) {
                    if (!completions || sequenced) return finish(DecodeStage::profile, ENOTSUP);
                    const size_t size = CompletionFeed::packetSize(opcode);
                    if (declared != size) return finish(DecodeStage::framing, EPROTO);
                    if (pending.size() < size) {
                        if (!readMore(size - pending.size())) {
                            if (stop) return finish(DecodeStage::stopped, 0);
                            if (stream.error()) return finish(DecodeStage::input, stream.error());
                            return finish(DecodeStage::eof, EPROTO);
                        }
                        continue;
                    }
                    if (opcode != CompletionFeed::kFeedOpcode && !passGate())
                        return finish(DecodeStage::stopped, 0);
                    if (opcode == CompletionFeed::kOrderOpcode) {
                        uint64_t serial = 0;
                        if (!CompletionFeed::parseOrder(pending.data(), size, &serial))
                            return finish(DecodeStage::framing, EPROTO);
                        completions->ordered(serial);
                        pending.erase(pending.begin(), pending.begin() + size);
                        decodedAny = true;
                        continue;
                    }
                    if (opcode == CompletionFeed::kWaitSerialOpcode) {
                        uint64_t serial = 0;
                        if (!CompletionFeed::parseWaitSerial(pending.data(), size, &serial))
                            return finish(DecodeStage::framing, EPROTO);
                        {
                            // Waiting for the GPU runs no command: a suspension need not wait.
                            ExecutorGate::Idle barrierIdle(gate);
                            const int waited = completions->waitSerial(serial);
                            if (waited == EPROTO) return finish(DecodeStage::framing, EPROTO);
                            if (waited != 0) return finish(DecodeStage::stopped, 0);
                        }
                        if (!passGate()) return finish(DecodeStage::stopped, 0);
                        pending.erase(pending.begin(), pending.begin() + size);
                        decodedAny = true;
                        continue;
                    }
                    if (opcode == CompletionFeed::kWatchOpcode) {
                        uint64_t queue = 0, serial = 0;
                        if (!CompletionFeed::parseWatch(pending.data(), size, &queue, &serial))
                            return finish(DecodeStage::framing, EPROTO);
                        completions->watch(queue, serial);
                        pending.erase(pending.begin(), pending.begin() + size);
                        decodedAny = true;
                        continue;
                    }
                    // A feed stream carries the feed command alone, as its first command.
                    if (decodedAny || pending.size() != size ||
                        !CompletionFeed::parseFeed(pending.data(), size))
                        return finish(DecodeStage::framing, EPROTO);
                    // The feed only writes records: it never holds a suspension back.
                    ExecutorGate::Idle feedIdle(gate);
                    return finish(DecodeStage::stopped, completions->run(fd, stop));
                }
            }
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
            if (!passGate()) return finish(DecodeStage::stopped, 0);
            if (diagnostic) diagnostic->stage = DecodeStage::decoder;
            if (decoderEntries) ++*decoderEntries;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            uint32_t frameOpcode = 0;
            if (auditTiming && frame.size >= sizeof(frameOpcode)) {
                std::memcpy(&frameOpcode, pending.data(), sizeof(frameOpcode));
            }
            const auto decodeStart = auditTiming ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
#endif
            if (progress) {
                uint32_t op = 0;
                if (frame.size >= 4) std::memcpy(&op, pending.data(), 4);
                progress->opcode = op;
                progress->stage = 1;
            }
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
            decodedAny = true;
            if (stream.error()) return finish(DecodeStage::decoder, stream.error());
            // Never retry a command after entering the decoder: a retry can
            // repeat side effects, including writes from earlier flush ranges.
            if (consumed != frame.size) return finish(DecodeStage::consumption, EPROTO);
            pending.erase(pending.begin(), pending.begin() + consumed);
#ifdef CABOOSE_GPU_MEMORY_AUDIT
            const uint64_t flushStartUs = auditTiming ? steadyNowMicroseconds() : 0;
#endif
            if (progress) progress->stage = 2;
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
      catch (const std::exception& fault) {
        // The decoder refused a command it could not run (gfxstream's GuestInputFault: an
        // unknown or mistyped handle, an unknown structure, a malformed stream) without
        // running it. That ends this guest process's device, never the runtime.
        uint32_t opcode = 0;
        if (diagnostic && diagnostic->headerPresent) opcode = diagnostic->opcode;
        if (DecodeProgress* progress = currentDecodeProgress()) opcode = progress->opcode.load();
        std::fprintf(stderr, "CABOOSE_GPU_GUEST_FAULT context=%u opcode=%u reason=\"%s\"\n",
                     contextId, opcode, fault.what());
        return finish(DecodeStage::guestInput, kGuestFaultResult);
    } catch (...) {
        std::fprintf(stderr, "CABOOSE_GPU_GUEST_FAULT context=%u reason=\"unknown exception\"\n", contextId);
        return finish(DecodeStage::guestInput, kGuestFaultResult);
    }
    return finish(DecodeStage::stopped, 0);
}
}
