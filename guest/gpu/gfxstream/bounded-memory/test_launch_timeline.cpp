// SPDX-License-Identifier: MIT
#include "launch_timeline.h"
#include <cassert>
#include <string>
using namespace caboose::launch;

static bool has(const std::string& text, const char* part) { return text.find(part) != std::string::npos; }

int main() {
    Timeline t;
    // Nothing has happened: the first call opens the window and writes nothing.
    assert(t.take(100).empty());
    t.command(Timeline::kCreateInstance, 300, 150);
    t.command(Timeline::kCreateInstance, 300, 160);  // a second instance: the first one stays
    t.command(Timeline::kCreateDevice, 400, 220);
    t.command(Timeline::kCreateShaderModule, 5000, 400);
    t.command(Timeline::kCreateShaderModule, 7000, 410);
    t.command(Timeline::kCreateGraphicsPipelines, 900, 500);
    t.command(20019, 16, 510);
    // Milestones are written once, as soon as they are taken, before the window ends.
    const std::string early = t.take(600);
    assert(has(early, "CABOOSE_GPU_LAUNCH event=first_instance ms=150\n"));
    assert(has(early, "CABOOSE_GPU_LAUNCH event=first_device ms=220\n"));
    assert(has(early, "CABOOSE_GPU_LAUNCH event=first_shader_module ms=400\n"));
    assert(has(early, "CABOOSE_GPU_LAUNCH event=first_pipeline ms=500\n"));
    assert(!has(early, "first_present") && !has(early, "window_ms"));
    assert(t.take(700).empty());
    t.presented(9000);
    t.presented(9500);
    // The window's line once it has lasted ten seconds.
    const std::string window = t.take(10100);
    assert(has(window, "CABOOSE_GPU_LAUNCH event=first_present ms=9000\n"));
    assert(has(window, "CABOOSE_GPU_LAUNCH ms=10100 window_ms=10000 modules=2 module_bytes=12000 pipelines=1 presents=2 "
                       "commands=7 command_bytes=13916 total_modules=2 total_pipelines=1 total_presents=2\n"));
    // A window with nothing in it writes nothing; counts start again, totals do not.
    assert(t.take(20200).empty());
    t.command(Timeline::kCreateComputePipelines, 100, 21000);
    const std::string next = t.take(30300);
    assert(has(next, " window_ms=10100 modules=0 module_bytes=0 pipelines=1 presents=0 commands=1 command_bytes=100 "
                     "total_modules=2 total_pipelines=2 total_presents=2\n"));
    // A window that started in the first fifteen minutes is written; none that starts later.
    t.presented(Timeline::kForMs + 1000);
    assert(has(t.take(Timeline::kForMs + 1000), " presents=1 "));
    t.presented(Timeline::kForMs + 20000);
    assert(t.take(Timeline::kForMs + 30000).empty());
    // Lines name the process they are of.
    Timeline named;
    named.command(Timeline::kCreateDevice, 1, 5);
    assert(has(named.take(10, " pid=7 process=game.exe"), "CABOOSE_GPU_LAUNCH pid=7 process=game.exe event=first_device ms=5\n"));
    // This process's age is positive and grows.
    const int64_t first = sinceStartMs();
    assert(first >= 0 && sinceStartMs() >= first);
    return 0;
}
