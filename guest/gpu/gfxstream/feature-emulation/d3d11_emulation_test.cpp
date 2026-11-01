// SPDX-License-Identifier: MIT
// Tests for d3d11_emulation.h (README.md). With a directory argument, also writes the SPIR-V
// modules it rewrites there, for spirv-val.
#include "d3d11_emulation.h"

#include <cassert>
#include <cstdio>
#include <string>

using namespace caboose::features;

namespace {

// A tiny SPIR-V assembler: ids are numbered by the caller.
struct Module {
    std::vector<uint32_t> words{spirv::kMagic, 0x00010000, 0, 0, 0};
    void op(uint16_t code, std::vector<uint32_t> operands) {
        words.push_back(uint32_t(operands.size() + 1) << 16 | code);
        words.insert(words.end(), operands.begin(), operands.end());
    }
    std::vector<uint32_t> finish(uint32_t bound, uint32_t version) {
        words[1] = version;
        words[3] = bound;
        return words;
    }
};

uint32_t word(const char* s) {  // up to four characters, zero padded
    uint32_t w = 0;
    for (int i = 0; i < 4 && s[i]; ++i) w |= uint32_t(uint8_t(s[i])) << (8 * i);
    return w;
}

enum : uint32_t {
    kVoid = 1, kFn, kFloat, kUint, kTwo, kArray, kOutArray, kOutFloat, kVec4, kOutVec4,
    kCull, kPos, kZero, kOne, kMain, kLabel, kChain, kBound
};

// A vertex shader writing cull distance 0 through an access chain, and its position.
std::vector<uint32_t> cullingVertexShader(uint32_t version) {
    Module m;
    m.op(17, {1});      // OpCapability Shader
    m.op(17, {33});     // OpCapability CullDistance
    m.op(14, {0, 1});   // OpMemoryModel Logical GLSL450
    m.op(15, {0, kMain, word("main"), 0, kCull, kPos});
    m.op(71, {kCull, 11, 4});  // BuiltIn CullDistance
    m.op(71, {kPos, 11, 0});   // BuiltIn Position
    m.op(19, {kVoid});
    m.op(33, {kFn, kVoid});
    m.op(22, {kFloat, 32});
    m.op(21, {kUint, 32, 0});
    m.op(43, {kUint, kTwo, 2});
    m.op(28, {kArray, kFloat, kTwo});
    m.op(32, {kOutArray, 3, kArray});
    m.op(32, {kOutFloat, 3, kFloat});
    m.op(23, {kVec4, kFloat, 4});
    m.op(32, {kOutVec4, 3, kVec4});
    m.op(59, {kOutArray, kCull, 3});
    m.op(59, {kOutVec4, kPos, 3});
    m.op(43, {kUint, kZero, 0});
    m.op(43, {kFloat, kOne, 0x3f800000});
    m.op(54, {kVoid, kMain, 0, kFn});
    m.op(248, {kLabel});
    m.op(65, {kOutFloat, kChain, kCull, kZero});
    m.op(62, {kChain, kOne});
    m.op(253, {});
    m.op(56, {});
    return m.finish(kBound, version);
}

// The instructions of `code` with opcode `op`, as word vectors.
std::vector<std::vector<uint32_t>> find(const std::vector<uint32_t>& code, uint16_t op) {
    std::vector<std::vector<uint32_t>> found;
    for (size_t at = 5; at < code.size(); at += code[at] >> 16)
        if ((code[at] & 0xffff) == op) found.emplace_back(code.begin() + at, code.begin() + at + (code[at] >> 16));
    return found;
}

void write(const std::string& path, const std::vector<uint32_t>& code) {
    FILE* f = fopen(path.c_str(), "wb");
    assert(f);
    fwrite(code.data(), 4, code.size(), f);
    fclose(f);
}

void testCullDistances(const char* outDir) {
    for (uint32_t version : {0x00010000u, 0x00010400u}) {
        std::vector<uint32_t> in = cullingVertexShader(version);
        std::vector<uint32_t> out = withoutCullDistances(in.data(), in.size());
        assert(!out.empty());
        // The capability and the cull distance decoration are gone; Position stays.
        for (auto& c : find(out, 17)) assert(c[1] != 33);
        auto decorations = find(out, 71);
        assert(decorations.size() == 1 && decorations[0][1] == kPos);
        // The variable is private, initialised with a new null constant of its type.
        uint32_t privateArray = 0, privateFloat = 0, null = 0;
        for (auto& p : find(out, 32)) {
            if (p[2] == 6 && p[3] == kArray) privateArray = p[1];
            if (p[2] == 6 && p[3] == kFloat) privateFloat = p[1];
        }
        for (auto& n : find(out, 46))
            if (n[1] == kArray) null = n[2];
        assert(privateArray >= kBound && privateFloat >= kBound && null >= kBound);
        assert(out[3] == kBound + 3);
        bool sawVariable = false;
        for (auto& v : find(out, 59)) {
            if (v[2] != kCull) continue;
            sawVariable = true;
            assert(v.size() == 5 && v[1] == privateArray && v[3] == 6 && v[4] == null);
        }
        assert(sawVariable);
        // The access chain into it yields a private pointer.
        auto chains = find(out, 65);
        assert(chains.size() == 1 && chains[0][1] == privateFloat);
        // The entry point lists the variable only from SPIR-V 1.4.
        auto entry = find(out, 15);
        assert(entry.size() == 1);
        bool listed = false;
        for (size_t i = 4; i < entry[0].size(); ++i) listed |= entry[0][i] == kCull;
        assert(listed == (version >= 0x00010400u));
        assert(entry[0].back() == kPos);
        // Rewriting again changes nothing.
        assert(withoutCullDistances(out.data(), out.size()).empty());
        if (outDir) {
            std::string suffix = version >= 0x00010400u ? "-1.4" : "-1.0";
            write(std::string(outDir) + "/cull-in" + suffix + ".spv", in);
            write(std::string(outDir) + "/cull-out" + suffix + ".spv", out);
        }
    }
    // Existing private pointer types and null constants are reused.
    {
        std::vector<uint32_t> in = cullingVertexShader(0x00010000u);
        // Insert "%40 = OpTypePointer Private %arr" and "%41 = OpConstantNull %arr" after the array type.
        std::vector<uint32_t> with(in.begin(), in.begin() + 5);
        for (size_t at = 5; at < in.size(); at += in[at] >> 16) {
            with.insert(with.end(), in.begin() + at, in.begin() + at + (in[at] >> 16));
            if ((in[at] & 0xffff) == 28) {
                with.insert(with.end(), {4u << 16 | 32, 40, 6, kArray, 3u << 16 | 46, kArray, 41});
            }
        }
        with[3] = 42;
        std::vector<uint32_t> out = withoutCullDistances(with.data(), with.size());
        assert(!out.empty() && out[3] == 43);  // only the private float pointer is new
        for (auto& v : find(out, 59))
            if (v[2] == kCull) assert(v[1] == 40 && v[4] == 41);
    }
    // Modules without cull distances, and what is not SPIR-V, are left alone.
    {
        std::vector<uint32_t> in = cullingVertexShader(0x00010000u);
        for (size_t at = 5; at < in.size(); at += in[at] >> 16)
            if ((in[at] & 0xffff) == 71 && in[at + 3] == 4) in[at + 3] = 3;  // ClipDistance
        assert(withoutCullDistances(in.data(), in.size()).empty());
        uint32_t junk[] = {1, 2, 3, 4, 5, 6};
        assert(withoutCullDistances(junk, 6).empty());
        assert(withoutCullDistances(nullptr, 0).empty());
        std::vector<uint32_t> cut = cullingVertexShader(0x00010000u);
        cut.pop_back();
        cut.back() = 0xffff0000u;  // an instruction running past the end
        assert(withoutCullDistances(cut.data(), cut.size()).empty());
    }
}

// A zeroed structure of type `T` with its sType and pNext.
template <class T>
T make(VkStructureType type, const void* next = nullptr) {
    T value{};
    value.sType = type;
    value.pNext = next;
    return value;
}

VkPipelineShaderStageCreateInfo stage(VkShaderStageFlagBits bit) {
    auto s = make<VkPipelineShaderStageCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO);
    s.stage = bit;
    return s;
}

void testPipelines() {
    VkPipelineShaderStageCreateInfo vsFs[] = {stage(VK_SHADER_STAGE_VERTEX_BIT), stage(VK_SHADER_STAGE_FRAGMENT_BIT)};
    VkPipelineShaderStageCreateInfo vsGsFs[] = {stage(VK_SHADER_STAGE_VERTEX_BIT), stage(VK_SHADER_STAGE_GEOMETRY_BIT),
                                                stage(VK_SHADER_STAGE_FRAGMENT_BIT)};
    auto provoking = make<VkPipelineRasterizationProvokingVertexStateCreateInfoEXT>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT);
    auto clipOff = make<VkPipelineRasterizationDepthClipStateCreateInfoEXT>(
        VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT, &provoking);
    clipOff.depthClipEnable = VK_FALSE;
    auto clipOn = make<VkPipelineRasterizationDepthClipStateCreateInfoEXT>(
        VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT, nullptr);
    clipOn.depthClipEnable = VK_TRUE;
    auto stream = make<VkPipelineRasterizationStateStreamCreateInfoEXT>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_STREAM_CREATE_INFO_EXT, &clipOn);
    auto rsOff = make<VkPipelineRasterizationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, &clipOff);
    rsOff.depthClampEnable = VK_TRUE;  // as DXVK sets it
    auto rsOn = make<VkPipelineRasterizationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, &stream);
    rsOn.depthClampEnable = VK_TRUE;
    auto rsPlain = make<VkPipelineRasterizationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
    VkDynamicState states[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE,
                               VK_DYNAMIC_STATE_SCISSOR};
    auto dynamic = make<VkPipelineDynamicStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
    dynamic.dynamicStateCount = 3;
    dynamic.pDynamicStates = states;
    auto tess = make<VkPipelineTessellationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO);

    auto pipeline = [&](uint32_t count, const VkPipelineShaderStageCreateInfo* stages,
                        const VkPipelineRasterizationStateCreateInfo* rs) {
        auto info = make<VkGraphicsPipelineCreateInfo>(VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
        info.stageCount = count;
        info.pStages = stages;
        info.pRasterizationState = rs;
        info.pDynamicState = &dynamic;
        info.pTessellationState = &tess;
        return info;
    };
    std::vector<VkGraphicsPipelineCreateInfo> infos = {
        pipeline(2, vsFs, &rsOff), pipeline(2, vsFs, &rsOn), pipeline(3, vsGsFs, &rsPlain), pipeline(2, vsFs, &rsPlain)};
    const std::vector<VkGraphicsPipelineCreateInfo> original = infos;
    PipelineCopies copies;

    // A phone with both features changes nothing.
    assert(!adjustGraphicsPipelines(infos, PipelineEmulation{}, copies));
    assert(memcmp(infos.data(), original.data(), sizeof(infos[0]) * infos.size()) == 0);

    assert(adjustGraphicsPipelines(infos, PipelineEmulation{true, true}, copies));
    // Depth clip off clamps; the clip structure leaves the chain, the others stay.
    assert(infos[0].pRasterizationState != &rsOff);
    assert(infos[0].pRasterizationState->depthClampEnable == VK_TRUE);
    assert(infos[0].pRasterizationState->pNext == &provoking);
    // Depth clip on clips; the structure before it is copied to skip it.
    const auto* rs1 = infos[1].pRasterizationState;
    assert(rs1->depthClampEnable == VK_FALSE);
    auto* streamCopy = static_cast<const VkPipelineRasterizationStateStreamCreateInfoEXT*>(rs1->pNext);
    assert(streamCopy != &stream && streamCopy->sType == stream.sType && streamCopy->pNext == nullptr);
    assert(stream.pNext == &clipOn);  // the application's structures are untouched
    // The geometry pipeline keeps its vertex stage, discards rasterization, and loses the
    // dynamic rasterizer discard and tessellation state.
    assert(infos[2].stageCount == 1 && infos[2].pStages[0].stage == VK_SHADER_STAGE_VERTEX_BIT);
    assert(infos[2].pRasterizationState->rasterizerDiscardEnable == VK_TRUE);
    assert(infos[2].pTessellationState == nullptr);
    assert(infos[2].pDynamicState->dynamicStateCount == 2);
    for (uint32_t i = 0; i < 2; ++i)
        assert(infos[2].pDynamicState->pDynamicStates[i] != VK_DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE);
    // A pipeline needing neither is untouched, and so are the originals.
    assert(memcmp(&infos[3], &original[3], sizeof(infos[3])) == 0);
    assert(rsOff.depthClampEnable == VK_TRUE && rsOff.pNext == &clipOff && dynamic.dynamicStateCount == 3);

    // Only what the phone lacks is approximated.
    infos = original;
    assert(adjustGraphicsPipelines(infos, PipelineEmulation{false, true}, copies));
    assert(infos[0].pRasterizationState == &rsOff && infos[2].stageCount == 1);
    infos = original;
    assert(adjustGraphicsPipelines(infos, PipelineEmulation{true, false}, copies));
    assert(infos[2].stageCount == 3 && infos[0].pRasterizationState->depthClampEnable == VK_TRUE);

    // A clip structure after one the driver cannot copy is left in place, with the clamp set.
    VkBaseInStructure unknown{VkStructureType(1000999000), reinterpret_cast<const VkBaseInStructure*>(&clipOn)};
    auto rsUnknown = make<VkPipelineRasterizationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, &unknown);
    std::vector<VkGraphicsPipelineCreateInfo> one = {pipeline(2, vsFs, &rsUnknown)};
    assert(adjustGraphicsPipelines(one, PipelineEmulation{true, false}, copies));
    assert(one[0].pRasterizationState->pNext == &unknown && one[0].pRasterizationState->depthClampEnable == VK_FALSE);
}

void testInlineModules() {
    std::vector<uint32_t> code = cullingVertexShader(0x00010000u);
    auto module = make<VkShaderModuleCreateInfo>(VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
    module.codeSize = code.size() * 4;
    module.pCode = code.data();
    VkPipelineShaderStageCreateInfo stages[] = {stage(VK_SHADER_STAGE_VERTEX_BIT), stage(VK_SHADER_STAGE_GEOMETRY_BIT),
                                                stage(VK_SHADER_STAGE_FRAGMENT_BIT)};
    stages[0].pNext = &module;
    auto info = make<VkGraphicsPipelineCreateInfo>(VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
    info.stageCount = 3;
    info.pStages = stages;
    PipelineCopies copies;

    // Cull distances alone: every stage stays, the vertex stage's module is rewritten.
    std::vector<VkGraphicsPipelineCreateInfo> infos = {info};
    assert(adjustGraphicsPipelines(infos, PipelineEmulation{false, false, true}, copies));
    assert(infos[0].stageCount == 3 && infos[0].pStages != stages);
    auto* rewritten = inlineModule(infos[0].pStages[0]);
    assert(rewritten && rewritten != &module && rewritten->pCode != code.data());
    std::vector<uint32_t> expected = withoutCullDistances(code.data(), code.size());
    assert(rewritten->codeSize == expected.size() * 4);
    assert(memcmp(rewritten->pCode, expected.data(), rewritten->codeSize) == 0);
    assert(module.pCode == code.data());  // the application's module is untouched

    // With the geometry stage dropped too, the remaining vertex stage is still rewritten.
    infos = {info};
    assert(adjustGraphicsPipelines(infos, PipelineEmulation{false, true, true}, copies));
    assert(infos[0].stageCount == 1 && inlineModule(infos[0].pStages[0])->pCode != code.data());

    // A module without cull distances is left alone.
    for (size_t at = 5; at < code.size(); at += code[at] >> 16)
        if ((code[at] & 0xffff) == 71 && code[at + 3] == 4) code[at + 3] = 3;
    infos = {info};
    assert(!adjustGraphicsPipelines(infos, PipelineEmulation{false, false, true}, copies));
    assert(infos[0].pStages == stages);
}

void testNullDescriptors() {
    NullObjects none;
    NullObjects objects;
    objects.buffer = reinterpret_cast<VkBuffer>(uintptr_t(0x10));
    objects.bufferView = reinterpret_cast<VkBufferView>(uintptr_t(0x20));
    objects.imageView = reinterpret_cast<VkImageView>(uintptr_t(0x30));
    VkBuffer real = reinterpret_cast<VkBuffer>(uintptr_t(0x99));

    VkDescriptorBufferInfo nullBuffer{VK_NULL_HANDLE, 256, 64};
    assert(!replaceNull(nullBuffer, none) && nullBuffer.buffer == VK_NULL_HANDLE);
    assert(replaceNull(nullBuffer, objects));
    assert(nullBuffer.buffer == objects.buffer && nullBuffer.offset == 0 && nullBuffer.range == VK_WHOLE_SIZE);
    VkDescriptorBufferInfo bound{real, 256, 64};
    assert(!replaceNull(bound, objects) && bound.buffer == real && bound.offset == 256 && bound.range == 64);

    VkDescriptorImageInfo image{VK_NULL_HANDLE, VK_NULL_HANDLE, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    assert(!replaceNull(VK_DESCRIPTOR_TYPE_SAMPLER, image, objects));
    assert(replaceNull(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, image, objects));
    assert(image.imageView == objects.imageView && image.imageLayout == VK_IMAGE_LAYOUT_GENERAL);
    assert(!replaceNull(VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, image, objects));

    VkBufferView view = VK_NULL_HANDLE;
    assert(!replaceNull(view, none) && replaceNull(view, objects) && view == objects.bufferView);
    assert(!replaceNull(view, objects));

    VkBuffer buffers[] = {real, VK_NULL_HANDLE, VK_NULL_HANDLE};
    VkDeviceSize offsets[] = {4, 8, 12}, sizes[] = {100, 0, 50};
    assert(!replaceNullVertexBuffers(3, buffers, offsets, sizes, none));
    assert(replaceNullVertexBuffers(3, buffers, offsets, sizes, objects));
    assert(buffers[0] == real && offsets[0] == 4 && sizes[0] == 100);
    assert(buffers[1] == objects.buffer && offsets[1] == 0 && sizes[1] == VK_WHOLE_SIZE);
    assert(buffers[2] == objects.buffer && offsets[2] == 0 && sizes[2] == VK_WHOLE_SIZE);
    buffers[1] = VK_NULL_HANDLE;
    assert(replaceNullVertexBuffers(3, buffers, offsets, nullptr, objects) && buffers[1] == objects.buffer);
    assert(!replaceNullVertexBuffers(3, buffers, offsets, nullptr, objects));
}

void testBindStatus() {
    VkResult first = VK_ERROR_UNKNOWN, second = VK_ERROR_UNKNOWN;
    auto status1 = make<VkBindMemoryStatus>(VK_STRUCTURE_TYPE_BIND_MEMORY_STATUS);
    status1.pResult = &first;
    auto other = make<VkBindBufferMemoryDeviceGroupInfo>(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_DEVICE_GROUP_INFO);
    auto status2 = make<VkBindMemoryStatus>(VK_STRUCTURE_TYPE_BIND_MEMORY_STATUS, &other);
    status2.pResult = &second;
    VkBindBufferMemoryInfo binds[3] = {make<VkBindBufferMemoryInfo>(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO, &status1),
                                       make<VkBindBufferMemoryInfo>(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO),
                                       make<VkBindBufferMemoryInfo>(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO, &status2)};
    answerBindStatus(3, binds, VK_SUCCESS);
    assert(first == VK_SUCCESS && second == VK_SUCCESS);
    answerBindStatus(2, binds, VK_ERROR_OUT_OF_DEVICE_MEMORY);
    assert(first == VK_ERROR_OUT_OF_DEVICE_MEMORY && second == VK_SUCCESS);
    answerBindStatus(1, static_cast<const VkBindImageMemoryInfo*>(nullptr), VK_SUCCESS);
}

void testIgnoredDescriptorPointers() {
    // DXVK's union: one array seen as image, buffer and texel buffer descriptors.
    union Descriptor {
        VkDescriptorImageInfo image;
        VkDescriptorBufferInfo buffer;
        VkBufferView texel;
    } data[2] = {};
    auto write = [&](VkDescriptorType type) {
        auto w = make<VkWriteDescriptorSet>(VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
        w.descriptorType = type;
        w.descriptorCount = 2;
        w.pImageInfo = &data[0].image;
        w.pBufferInfo = &data[0].buffer;
        w.pTexelBufferView = &data[0].texel;
        clearIgnoredDescriptorPointers(w);
        return w;
    };
    for (VkDescriptorType type : {VK_DESCRIPTOR_TYPE_SAMPLER, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                  VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                                  VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT}) {
        auto w = write(type);
        assert(w.pImageInfo == &data[0].image && !w.pBufferInfo && !w.pTexelBufferView);
    }
    for (VkDescriptorType type : {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                                  VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC}) {
        auto w = write(type);
        assert(!w.pImageInfo && w.pBufferInfo == &data[0].buffer && !w.pTexelBufferView);
    }
    for (VkDescriptorType type : {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER}) {
        auto w = write(type);
        assert(!w.pImageInfo && !w.pBufferInfo && w.pTexelBufferView == &data[0].texel);
    }
    auto inlineBlock = write(VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK);
    assert(!inlineBlock.pImageInfo && !inlineBlock.pBufferInfo && !inlineBlock.pTexelBufferView);
}

}  // namespace

int main(int argc, char** argv) {
    testCullDistances(argc > 1 ? argv[1] : nullptr);
    testPipelines();
    testInlineModules();
    testNullDescriptors();
    testBindStatus();
    testIgnoredDescriptorPointers();
    std::puts("d3d11 emulation tests passed");
}
