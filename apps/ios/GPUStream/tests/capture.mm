// Standalone C API capture replay for failure diagnostics, independent of Swift Testing.
#include "caboose_gpu_stream.h"
#import <QuartzCore/CAMetalLayer.h>
#include <fstream>
#include <iostream>
#include <vector>

int main(int argc, char** argv)
{
    if (argc != 3) { std::cerr << "usage: check-capture FILE FRAMES\n"; return 2; }
    @autoreleasepool
    {
        std::ifstream capture(argv[1], std::ios::binary);
        if (!capture) { std::cerr << "Cannot open capture\n"; return 2; }
        auto* player = cgpu_player_create((__bridge void*)[CAMetalLayer layer], nullptr, nullptr);
        if (!player) { return 1; }
        std::vector<char> bytes(64 * 1024);
        bool accepted = true;
        while (capture.read(bytes.data(), bytes.size()) || capture.gcount() > 0)
        {
            if (cgpu_player_feed(player, bytes.data(), capture.gcount()) != 0) { accepted = false; break; }
        }
        cgpu_player_finish(player);
        const auto state = cgpu_player_wait(player);
        const auto frames = cgpu_player_frames(player);
        std::vector<char> error(cgpu_player_copy_error(player, nullptr, 0) + 1);
        cgpu_player_copy_error(player, error.data(), error.size());
        const bool passed = accepted && state == CGPU_STATE_FINISHED && frames == std::stoull(argv[2]);
        std::cout << "Standalone capture: state=" << state << " frames=" << frames << " error=" << error.data() << '\n';
        cgpu_player_destroy(player);
        return passed ? 0 : 1;
    }
}
