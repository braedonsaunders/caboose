// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
namespace caboose::gpuv2::diagnostic {
// Serialized by the caller. This tracks transport closure only, never GPU success.
enum class CloseAction { none, send_final, wait, fail };
class GracefulClose {
public:
    CloseAction inputEof() { input_eof_ = true; return CloseAction::wait; }
    CloseAction outputEof() {
        if (output_eof_) return CloseAction::none;
        output_eof_ = true;
        return CloseAction::send_final;
    }
    CloseAction finalSendComplete(bool error) {
        if (!output_eof_ || final_complete_) return CloseAction::fail;
        final_complete_ = true;
        return error ? CloseAction::fail : CloseAction::wait;
    }
    bool inputClosed() const { return input_eof_; }
private:
    bool input_eof_ = false;
    bool output_eof_ = false;
    bool final_complete_ = false;
};
}
