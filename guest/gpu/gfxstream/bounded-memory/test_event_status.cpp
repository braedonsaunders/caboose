// SPDX-License-Identifier: MIT
#include "event_status.h"
#include <cassert>
using caboose::memory::EventStatusReplies;
using caboose::memory::QueryReply;

static std::shared_ptr<QueryReply> answer(const std::shared_ptr<QueryReply>& reply, int32_t result) {
    reply->result = result;
    reply->done.store(true);
    return reply;
}

int main() {
    EventStatusReplies events;
    bool send = false;
    // First poll: reset, and a request goes out; while it is outstanding no other does.
    assert(events.poll(0xE1, &send) == EventStatusReplies::kReset && send);
    auto first = std::make_shared<QueryReply>();
    events.requested(0xE1, first);
    assert(events.poll(0xE1, &send) == EventStatusReplies::kReset && !send);
    // Its answer is reported; a reset answer asks again.
    answer(first, EventStatusReplies::kReset);
    assert(events.poll(0xE1, &send) == EventStatusReplies::kReset && send);
    auto second = std::make_shared<QueryReply>();
    events.requested(0xE1, second);
    answer(second, EventStatusReplies::kSet);
    // Set stays set without more requests until the event is changed.
    assert(events.poll(0xE1, &send) == EventStatusReplies::kSet && !send);
    assert(events.poll(0xE1, &send) == EventStatusReplies::kSet && !send);
    events.forget(0xE1);
    assert(events.poll(0xE1, &send) == EventStatusReplies::kReset && send);
    // A stale reply of a request sent before the change is never reported.
    auto stale = std::make_shared<QueryReply>();
    events.requested(0xE1, stale);
    events.forget(0xE1);
    answer(stale, EventStatusReplies::kSet);
    assert(events.poll(0xE1, &send) == EventStatusReplies::kReset && send);
    // Device loss is reported as the device answered it.
    auto lost = std::make_shared<QueryReply>();
    events.requested(0xE2, lost);
    answer(lost, -4);
    assert(events.poll(0xE2, &send) == -4);
    return 0;
}
