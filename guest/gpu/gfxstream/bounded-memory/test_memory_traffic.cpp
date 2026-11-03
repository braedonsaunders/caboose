// SPDX-License-Identifier: MIT
#include "memory_traffic.h"
#include <cassert>
#include <string>
using namespace caboose::memory::traffic;

static bool has(const std::string& line, const char* field) { return line.find(field) != std::string::npos; }

int main() {
    Counters counters;
    // The first call opens the window; nothing is reported before it ends.
    assert(counters.take(1000).empty());
    counters.flushed(application, 4096);
    counters.flushed(coherent, 100);
    counters.flushed(coherent, 28);
    counters.invalidated(coherent, 64);
    counters.invalidated(application, 1 << 20);
    counters.marked(copyImageToBuffer, 5000);
    counters.marked(copyQueryResults, 16);
    counters.sent(9000);
    counters.received(2000);
    counters.considered(true, 16384);
    counters.considered(false, 1 << 22);
    counters.staged(8192);
    counters.piece(unchangedPiece);
    counters.piece(unchangedPiece);
    counters.piece(namedPiece);
    assert(counters.take(5999).empty());
    const auto line = counters.take(6000);
    assert(has(line, "CABOOSE_GPU_MEMORY_TRAFFIC elapsed_ms=5000 sent_bytes=9000 received_bytes=2000 "));
    assert(has(line, " app_flushed_bytes=4096 app_flushes=1 coherent_flushed_bytes=128 coherent_flushes=2 "));
    assert(has(line, " app_invalidated_bytes=1048576 app_invalidates=1 coherent_invalidated_bytes=64 coherent_invalidates=1 "));
    assert(has(line, " largest_invalidate_bytes=1048576 "));
    assert(has(line, " marked_copy_image_bytes=5000 marked_copy_buffer_bytes=0 marked_query_bytes=16 "));
    assert(has(line, " coherent_watched_bytes=16384 coherent_whole_bytes=4194304 staging_flushed_bytes=8192 "));
    assert(has(line, " pieces_unchanged=2 pieces_named=1 pieces_stored=0"));
    // Once per window, and the counts start again.
    assert(counters.take(6000).empty());
    counters.sent(1);
    const auto next = counters.take(11000);
    assert(has(next, "elapsed_ms=5000 sent_bytes=1 received_bytes=0 app_flushed_bytes=0 "));
    assert(has(next, "largest_invalidate_bytes=0 "));
    assert(has(next, "coherent_watched_bytes=0 coherent_whole_bytes=0 staging_flushed_bytes=0 pieces_unchanged=0 "));
    // A window in which nothing moved writes nothing.
    assert(counters.take(16000).empty());
    // Coherent upkeep is the driver's origin while it lasts, and nests.
    assert(currentOrigin() == application);
    {
        CoherentUpkeep outer;
        assert(currentOrigin() == coherent);
        { CoherentUpkeep inner; assert(currentOrigin() == coherent); }
        assert(currentOrigin() == coherent);
    }
    assert(currentOrigin() == application);
    return 0;
}
