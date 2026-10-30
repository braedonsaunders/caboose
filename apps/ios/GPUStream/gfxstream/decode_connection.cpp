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

namespace caboose::gpuv2 {
int decodeConnection(int fd, size_t max_packet, size_t max_reply_buffer,
                     gfxstream::host::RenderThreadInfo& thread_info,
                     std::atomic_bool& stop, bool synchronousOnly, uint64_t* decoderEntries) {
    if (fd < 0 || max_packet < 8 || max_packet > 400u * 1024u * 1024u ||
        max_reply_buffer < 4096 || !thread_info.m_vkInfo || !thread_info.getProcessResources()) return EINVAL;
    SocketStream stream(fd, max_reply_buffer);
    uint32_t flags;
    if (!stream.readFully(&flags, sizeof(flags))) return stop ? 0 : stream.error();
    // Pinned upstream RenderThread consumes but does not interpret this word.
    (void)flags;
    gfxstream::host::GfxApiLogger logger;
    gfxstream::host::vk::VkDecoderContext context{};
    context.gfxApiLogger = &logger;
    context.shouldExit = &stop;

    try {
        std::vector<unsigned char> pending;
        auto readMore = [&](size_t request) -> bool {
            const size_t old = pending.size();
            pending.resize(old + request);
            const size_t got = stream.read(pending.data() + old, request);
            pending.resize(old + got);
            return got != 0;
        };
        // This must be the same immutable feature used by VkDecoder at construction.
        const bool sequenced = gfxstream::host::FrameBuffer::getFB()->getFeatures()
                                   .VulkanQueueSubmitWithCommands.enabled();
        while (!stop.load()) {
            if (synchronousOnly && pending.size() >= 8) {
                uint32_t opcode = 0;
                std::memcpy(&opcode, pending.data(), sizeof(opcode));
                if (forbiddenV4Opcode(opcode)) return ENOTSUP;
            }
            const auto frame = inspectFrame(pending.data(), pending.size(), max_packet, sequenced);
            if (frame.status == FrameStatus::invalid) return EPROTO;
            if (frame.status == FrameStatus::unsupported) return ENOTSUP;
            if (frame.status == FrameStatus::need_more) {
                if (frame.size <= pending.size() || frame.size > max_packet) return EPROTO;
                if (!readMore(frame.size - pending.size())) {
                    if (stop) return 0;
                    if (stream.error()) return stream.error();
                    if (stream.eof()) return pending.empty() ? 0 : EPROTO;
                    return EIO;
                }
                continue;
            }
            if (decoderEntries) ++*decoderEntries;
            const size_t consumed = thread_info.m_vkInfo->m_vkDec.decode(
                pending.data(), frame.size, &stream, thread_info.getProcessResources().get(), context);
            if (stream.error()) return stream.error();
            // Never retry a command after entering the decoder: a retry can
            // repeat side effects, including writes from earlier flush ranges.
            if (consumed != frame.size) return EPROTO;
            pending.erase(pending.begin(), pending.begin() + consumed);
            if (stream.flush() < 0) return stream.error() ? stream.error() : EIO;
        }
    } catch (const std::bad_alloc&) { return ENOMEM; }
    return 0;
}
}
