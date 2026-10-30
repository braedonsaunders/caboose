// Translate the unmodified pinned compositor vertex module with a layout that
// includes an unused immutable multi-plane fragment sampler before its UBO.
#include "spirv_msl.hpp"
#include "compositor_vertex_shader.h"
#include <cstdio>
#include <cstdlib>
#include <exception>
int main(int argc, char** argv) {
    if (argc != 5) return 2;
    unsigned planes = std::atoi(argv[1]); bool sampler_first = std::atoi(argv[2]); unsigned count = std::atoi(argv[3]); unsigned decoy = std::atoi(argv[4]);
    if (planes < 1 || planes > 3 || count < 1 || count > 2) return 2;
    try {
        spirv_cross::CompilerMSL c(kCompositorVertexShader);
        auto options = c.get_msl_options(); options.argument_buffers = true;
        options.pad_argument_buffer_resources = true; options.set_msl_version(2, 3);
        c.set_msl_options(options);
        spirv_cross::MSLResourceBinding image{}; image.stage = spv::ExecutionModelVertex;
        image.desc_set = 0; image.binding = 0; image.basetype = spirv_cross::SPIRType::SampledImage;
        image.count = count; image.msl_texture = 0; image.msl_sampler = planes * count;
        spirv_cross::MSLResourceBinding buffer{}; buffer.stage = spv::ExecutionModelVertex;
        buffer.desc_set = 0; buffer.binding = 1; buffer.basetype = spirv_cross::SPIRType::Void;
        buffer.count = 1; buffer.msl_buffer = planes * count + count;
        spirv_cross::MSLConstexprSampler sampler{}; sampler.ycbcr_conversion_enable = planes > 1; sampler.planes = planes;
        if (decoy == 1) image.stage = spv::ExecutionModelFragment;
        if (decoy == 2) image.desc_set = 1;
        if (sampler_first) c.remap_constexpr_sampler_by_binding(0, 0, sampler);
        c.add_msl_resource_binding(image); c.add_msl_resource_binding(buffer);
        if (!sampler_first) c.remap_constexpr_sampler_by_binding(0, 0, sampler);
        auto msl = c.compile(); std::printf("planes=%u sampler_first=%d count=%u decoy=%u msl_bytes=%zu\n", planes, sampler_first, count, decoy, msl.size());
        return 0;
    } catch (const std::exception& e) { std::fprintf(stderr, "planes=%u sampler_first=%d count=%u decoy=%u error=%s\n", planes, sampler_first, count, decoy, e.what()); return 1; }
}
