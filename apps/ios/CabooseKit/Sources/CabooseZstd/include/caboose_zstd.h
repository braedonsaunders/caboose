// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>

// One zstd stream decoded record by record (docs/gpu-live.md, "Optional bounded command
// compression", algorithm 2): each record ends at a flush point of the same stream.
typedef struct caboose_zstd_stream caboose_zstd_stream;

// A decoder whose window is at most 2^23 bytes; NULL when out of memory.
caboose_zstd_stream* caboose_zstd_stream_create(void);
void caboose_zstd_stream_free(caboose_zstd_stream* stream);
// Decodes one whole record into `out`: 0 when it consumed all `size` input bytes and produced
// exactly `expected` bytes with nothing further pending, -1 otherwise (the stream is then
// unusable). `out` holds at least `expected` bytes.
int caboose_zstd_stream_decode(caboose_zstd_stream* stream, const void* in, size_t size,
                               void* out, size_t expected);
