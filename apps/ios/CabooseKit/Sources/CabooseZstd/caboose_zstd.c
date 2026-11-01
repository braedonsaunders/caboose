// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "caboose_zstd.h"
#include "vendor/zstddeclib.c"

struct caboose_zstd_stream { ZSTD_DCtx* context; int failed; };

caboose_zstd_stream* caboose_zstd_stream_create(void) {
    caboose_zstd_stream* stream = (caboose_zstd_stream*)calloc(1, sizeof(*stream));
    if (!stream) return NULL;
    stream->context = ZSTD_createDCtx();
    if (!stream->context ||
        ZSTD_isError(ZSTD_DCtx_setParameter(stream->context, ZSTD_d_windowLogMax, 23))) {
        caboose_zstd_stream_free(stream);
        return NULL;
    }
    return stream;
}

void caboose_zstd_stream_free(caboose_zstd_stream* stream) {
    if (!stream) return;
    if (stream->context) ZSTD_freeDCtx(stream->context);
    free(stream);
}

int caboose_zstd_stream_decode(caboose_zstd_stream* stream, const void* in, size_t size,
                               void* out, size_t expected) {
    if (!stream || stream->failed || (!in && size) || (!out && expected)) return -1;
    ZSTD_inBuffer input = {in, size, 0};
    ZSTD_outBuffer output = {out, expected, 0};
    size_t hint = 0;
    while (input.pos < input.size) {
        const size_t before = input.pos, written = output.pos;
        hint = ZSTD_decompressStream(stream->context, &output, &input);
        if (ZSTD_isError(hint)) { stream->failed = 1; return -1; }
        if (input.pos == before && output.pos == written) break;
    }
    // A record ends where a flush ended a block: every byte of it consumed, exactly the
    // declared size produced, nothing more pending, and the decoder asking for exactly the
    // next block's 3-byte header. Anything else (a stray byte, a cut block) is an error.
    unsigned char extra;
    ZSTD_outBuffer probe = {&extra, 1, 0};
    ZSTD_inBuffer none = {NULL, 0, 0};
    const size_t pending = ZSTD_decompressStream(stream->context, &probe, &none);
    if (input.pos != input.size || output.pos != expected || hint != 3 ||
        ZSTD_isError(pending) || probe.pos != 0) {
        stream->failed = 1;
        return -1;
    }
    return 0;
}
