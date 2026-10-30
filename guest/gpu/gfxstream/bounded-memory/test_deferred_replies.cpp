// SPDX-License-Identifier: MIT
#include "deferred_replies.h"
#include <cassert>
#include <cstring>
#include <vector>
using namespace caboose::memory;

namespace {
struct Stream {
    std::vector<int32_t> replies;
    size_t next = 0;
    bool invalidated = false;
    bool tryRead(void* out, size_t size) {
        if (size != sizeof(int32_t) || next == replies.size()) return false;
        std::memcpy(out, &replies[next++], size);
        return true;
    }
    void invalidate() { invalidated = true; }
};
} // namespace

int main() {
    Stream stream{{0, 0, -4, 0, 7}};
    uint32_t pending = 0;
    assert(drainDeferredReplies(pending, &stream) && stream.next == 0);

    // Drains exactly the pending replies, in order, tolerating reported failures.
    pending = 3;
    assert(drainDeferredReplies(pending, &stream) && pending == 0 && stream.next == 3);
    assert(!stream.invalidated);

    // Later replies are left for their own command.
    pending = 1;
    assert(drainDeferredReplies(pending, &stream) && stream.next == 4);

    // A short stream is a transport failure: nothing stays pending.
    pending = 3;
    assert(!drainDeferredReplies(pending, &stream) && pending == 0 && stream.invalidated);

    // Per-encoder counts drain only their own encoder's replies.
    DeferredReplies table;
    int a = 0, b = 0;
    Stream first{{0, 0, 0, 0}}, second{{0}};
    assert(table.drain(&a, &first) && first.next == 0);
    table.add(&a, 2, 100); table.add(&b, 1, 100); table.add(&a, 1, 100); table.add(&a, 0, 100);
    assert(table.pending() == 4);
    assert(table.drain(&b, &second) && second.next == 1 && table.pending() == 3);

    // Reserving within the byte limit keeps replies pending; past it drains them.
    assert(table.reserve(&a, &first, 800, 1000) && first.next == 0 && table.pending() == 3);
    assert(table.reserve(&a, &first, 801, 1000) && first.next == 3 && table.pending() == 0);
    table.add(&a, 1, 10);
    assert(table.drain(&a, &first) && first.next == 4);
    assert(table.drain(&a, &first) && first.next == 4);
    return 0;
}
