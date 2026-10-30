// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "decode_connection.h"
#include "socket_stream.h"
#include "render_thread_info_vk.h"
#include "vk_decoder_context.h"
#include "gfxstream/host/GfxApiLogger.h"
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace caboose::gpuv2 {
int decodeConnection(int fd, uint32_t context_id, size_t max_packet, size_t max_reply_buffer,
                     std::shared_ptr<const gfxstream::host::ProcessResources> resources,
                     std::atomic_bool& stop) {
    if (fd < 0 || context_id == 0 || context_id == UINT32_MAX || max_packet < 8 || max_packet > 400u * 1024u * 1024u ||
        max_reply_buffer < 4096 || !resources) return EINVAL;
    SocketStream stream(fd, max_reply_buffer);
    uint32_t flags;
    if (!stream.readFully(&flags, sizeof(flags))) return stop ? 0 : stream.error();
    // Pinned upstream RenderThread consumes but does not interpret this word.
    (void)flags;
    gfxstream::host::GfxApiLogger logger;
    gfxstream::host::vk::VkDecoderContext context{};
    context.gfxApiLogger = &logger;
    context.shouldExit = &stop;
    if (gfxstream::host::vk::RenderThreadInfoVk::get()) return EBUSY;
    gfxstream::host::vk::RenderThreadInfoVk thread_info;
    thread_info.ctx_id = context_id;
    thread_info.m_processResources = resources;
    try {
        while (!stop.load()) {
            uint32_t header[2];
            if (!stream.readFully(header, sizeof(header))) return stop ? 0 : stream.error();
            const size_t length = header[1];
            if (length < sizeof(header) || length > max_packet) return EMSGSIZE;
            std::vector<unsigned char> packet(length);
            std::memcpy(packet.data(), header, sizeof(header));
            if (!stream.readFully(packet.data() + sizeof(header), length - sizeof(header)))
                return stop ? 0 : stream.error();
            const size_t consumed = thread_info.m_vkDec.decode(packet.data(), packet.size(), &stream,
                                                   resources.get(), context);
            if (stream.error()) return stream.error();
            if (consumed != packet.size()) return EPROTO;
            if (stream.flush() < 0) return stream.error() ? stream.error() : EIO;
        }
    } catch (const std::bad_alloc&) { return ENOMEM; }
    return 0;
}
}
