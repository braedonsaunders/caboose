// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "graceful_close.h"
#include <cassert>
using caboose::gpuv2::diagnostic::CloseAction;
using caboose::gpuv2::diagnostic::GracefulClose;
int main() {
    // Inbound half-close first: final send follows only after output drains.
    GracefulClose a;
    assert(a.inputEof() == CloseAction::wait && a.inputClosed());
    assert(a.outputEof() == CloseAction::send_final);
    assert(a.outputEof() == CloseAction::none);
    assert(a.finalSendComplete(false) == CloseAction::wait);
    assert(a.finalSendComplete(false) == CloseAction::fail);
    // Output can drain before peer EOF; a send callback is still not a receipt.
    GracefulClose b;
    assert(b.outputEof() == CloseAction::send_final);
    assert(b.finalSendComplete(false) == CloseAction::wait);
    assert(!b.inputClosed());
    assert(b.inputEof() == CloseAction::wait);
    GracefulClose c;
    assert(c.finalSendComplete(false) == CloseAction::fail);
    GracefulClose d;
    assert(d.outputEof() == CloseAction::send_final);
    assert(d.finalSendComplete(true) == CloseAction::fail);
    // Cancellation before EOF suppresses both future actions.
    GracefulClose e;
    e.cancel();
    assert(e.inputEof() == CloseAction::none);
    assert(e.outputEof() == CloseAction::none);
    // A callback already in flight after cancellation must not start teardown twice.
    GracefulClose f;
    assert(f.outputEof() == CloseAction::send_final);
    f.cancel();
    assert(f.finalSendComplete(false) == CloseAction::none);
    assert(f.finalSendComplete(true) == CloseAction::none);
}
