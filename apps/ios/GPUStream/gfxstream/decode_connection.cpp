// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "decode_connection.h"
#include "socket_stream.h"
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
                     std::atomic_bool& stop) {
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
        while (!stop.load()) {
            if (pending.size() < 8) {
                if (!readMore(8 - pending.size())) return stop ? 0 : stream.error();
                continue;
            }
            uint32_t length;
            std::memcpy(&length, pending.data() + 4, sizeof(length));
            if (length < 8 || length > max_packet) return EMSGSIZE;
            if (pending.size() < length) {
                if (!readMore(length - pending.size())) return stop ? 0 : stream.error();
                continue;
            }
            const size_t consumed = thread_info.m_vkInfo->m_vkDec.decode(
                pending.data(), pending.size(), &stream, thread_info.getProcessResources().get(), context);
            if (stream.error()) return stream.error();
            if (consumed > pending.size()) return EPROTO;
            if (consumed) {
                pending.erase(pending.begin(), pending.begin() + consumed);
                if (stream.flush() < 0) return stream.error() ? stream.error() : EIO;
                continue;
            }
            // The pinned decoder's non-direct mapped-memory flush can append
            // bytes beyond its advertised length. Zero progress may also mean
            // an unknown opcode; cap retained data and let EOF/cancellation end it.
            if (pending.size() == max_packet) return EPROTO;
            const size_t room = max_packet - pending.size();
            if (!readMore(room < 65536 ? room : 65536)) return stop ? 0 : stream.error();
        }
    } catch (const std::bad_alloc&) { return ENOMEM; }
    return 0;
}
}
