// SPDX-License-Identifier: MIT
//
// Device features Direct3D 11 needs that the phone's GPU lacks, offered by the Caboose driver
// so that DXVK creates a Direct3D 11 device on the phone (README.md). Each is offered only
// when the phone lacks it, and approximated in the driver; none reaches the phone:
//
// - geometryShader. A graphics pipeline with a geometry stage is created from its vertex
//   stage alone with rasterization discarded: its draws produce nothing.
// - shaderCullDistance. A shader's cull distance variables become private variables, in
//   vkCreateShaderModule and in a pipeline stage's own shader module: writes to them are
//   dropped, and primitives are not culled by them.
// - VK_EXT_depth_clip_enable. A pipeline's depth clip state becomes its depth clamp: clipping
//   off clamps depth, clipping on clips it, as Direct3D's DepthClipEnable does.
// - VK_EXT_robustness2's nullDescriptor and robustBufferAccess2, offered with the extension
//   itself when the phone lacks it, or alone when it has the extension without them. A null buffer, buffer view or image view in a descriptor, and a
//   null vertex or index buffer, become objects the driver keeps per device, cleared to zero
//   when the device is created: a 64 KiB buffer, a view of it and a 2D view of a 1x1 image.
//   robustBufferAccess2 is reported and the phone gets robustBufferAccess.
//
// DXVK also requires VK_KHR_maintenance5, VK_KHR_maintenance6 and VK_KHR_load_store_op_none,
// which pass through from the phone; a bind's VkBindMemoryStatus is answered here.
#pragma once

#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <vulkan/vulkan.h>

namespace caboose::features {

inline constexpr const char* kDepthClipEnable = "VK_EXT_depth_clip_enable";

// Feature structures held back from the phone's feature query because it lacks their
// extension, and filled in by the driver after it.
struct HeldFeatures {
    VkPhysicalDeviceDepthClipEnableFeaturesEXT* depthClip = nullptr;
    VkPhysicalDeviceRobustness2FeaturesEXT* robustness2 = nullptr;
};

inline constexpr const char* kRobustness2 = "VK_EXT_robustness2";
inline constexpr const char* kRobustness2KHR = "VK_KHR_robustness2";
// What a driver offering VK_EXT_robustness2 itself reports: the largest alignments allowed.
inline constexpr VkDeviceSize kRobustStorageBufferAccessSizeAlignment = 4;
inline constexpr VkDeviceSize kRobustUniformBufferAccessSizeAlignment = 256;

// VK_KHR_maintenance6, which DXVK requires, lets each bind of a vkBind*Memory2 call report
// its own result through a VkBindMemoryStatus. The driver sends binds without waiting for
// the phone: every one reports the call's result.
template <class BindInfo>
inline void answerBindStatus(uint32_t count, const BindInfo* infos, VkResult result) {
    for (uint32_t i = 0; infos && i < count; ++i)
        for (auto* s = static_cast<const VkBaseInStructure*>(infos[i].pNext); s; s = s->pNext)
            if (s->sType == VK_STRUCTURE_TYPE_BIND_MEMORY_STATUS) {
                VkResult* out = reinterpret_cast<const VkBindMemoryStatus*>(s)->pResult;
                if (out) *out = result;
            }
}

// ---------------------------------------------------------------------------------------
// Null descriptors
// ---------------------------------------------------------------------------------------

// The objects that stand in for null resources on one device (internal handles).
struct NullObjects {
    VkBuffer buffer = VK_NULL_HANDLE;
    VkBufferView bufferView = VK_NULL_HANDLE;
    VkImageView imageView = VK_NULL_HANDLE;
};
inline constexpr VkDeviceSize kNullBufferSize = 64 * 1024;
inline constexpr VkFormat kNullFormat = VK_FORMAT_R8G8B8A8_UNORM;

// Each replaces a null resource with its stand-in; true if it did.
inline bool replaceNull(VkDescriptorBufferInfo& info, const NullObjects& objects) {
    if (info.buffer != VK_NULL_HANDLE || objects.buffer == VK_NULL_HANDLE) return false;
    info.buffer = objects.buffer;
    info.offset = 0;
    info.range = VK_WHOLE_SIZE;
    return true;
}
inline bool replaceNull(VkDescriptorType type, VkDescriptorImageInfo& info, const NullObjects& objects) {
    if (type == VK_DESCRIPTOR_TYPE_SAMPLER) return false;
    if (info.imageView != VK_NULL_HANDLE || objects.imageView == VK_NULL_HANDLE) return false;
    info.imageView = objects.imageView;
    info.imageLayout = VK_IMAGE_LAYOUT_GENERAL;
    return true;
}
inline bool replaceNull(VkBufferView& view, const NullObjects& objects) {
    if (view != VK_NULL_HANDLE || objects.bufferView == VK_NULL_HANDLE) return false;
    view = objects.bufferView;
    return true;
}

// Null vertex buffers in `buffers` become the stand-in buffer, bound from its start to its
// end (`sizes` may be null). True if any did.
inline bool replaceNullVertexBuffers(uint32_t count, VkBuffer* buffers, VkDeviceSize* offsets,
                                     VkDeviceSize* sizes, const NullObjects& objects) {
    if (objects.buffer == VK_NULL_HANDLE) return false;
    bool replaced = false;
    for (uint32_t i = 0; i < count; ++i) {
        if (buffers[i] != VK_NULL_HANDLE) continue;
        buffers[i] = objects.buffer;
        offsets[i] = 0;
        if (sizes) sizes[i] = VK_WHOLE_SIZE;
        replaced = true;
    }
    return replaced;
}

// ---------------------------------------------------------------------------------------
// Cull distances
// ---------------------------------------------------------------------------------------

namespace spirv {
inline constexpr uint32_t kMagic = 0x07230203;
inline constexpr uint16_t kOpEntryPoint = 15, kOpCapability = 17, kOpTypePointer = 32,
                          kOpConstantNull = 46, kOpVariable = 59, kOpAccessChain = 65,
                          kOpInBoundsAccessChain = 66, kOpPtrAccessChain = 67, kOpDecorate = 71,
                          kOpCopyObject = 83;
inline constexpr uint32_t kDecorationBuiltIn = 11, kBuiltInCullDistance = 4,
                          kCapabilityCullDistance = 33, kStorageInput = 1, kStorageOutput = 3,
                          kStoragePrivate = 6;
}  // namespace spirv

// A SPIR-V module whose cull distance variables are private variables initialised to zero,
// so it needs no cull distance support; empty when `code` has none or is not SPIR-V this
// understands. Covers cull distances declared as variables of their own (DXVK's); a cull
// distance member of a block is left alone.
inline std::vector<uint32_t> withoutCullDistances(const uint32_t* code, size_t words) {
    using namespace spirv;
    if (!code || words < 5 || code[0] != kMagic) return {};
    struct Instruction {
        size_t at;
        uint16_t op, count;
    };
    std::vector<Instruction> all;
    for (size_t at = 5; at < words;) {
        uint16_t count = uint16_t(code[at] >> 16), op = uint16_t(code[at] & 0xffff);
        if (count == 0 || at + count > words) return {};
        all.push_back({at, op, count});
        at += count;
    }
    // The variables to rewrite: decorated as cull distances.
    std::unordered_map<uint32_t, size_t> definitions;  // result id -> instruction
    for (size_t i = 0; i < all.size(); ++i) {
        const Instruction& in = all[i];
        if (in.op == kOpTypePointer && in.count == 4) definitions[code[in.at + 1]] = i;
        if (in.op == kOpVariable && in.count >= 4) definitions[code[in.at + 2]] = i;
    }
    std::unordered_set<uint32_t> cull;
    for (const Instruction& in : all) {
        if (in.op != kOpDecorate || in.count < 4) continue;
        if (code[in.at + 2] != kDecorationBuiltIn || code[in.at + 3] != kBuiltInCullDistance) continue;
        auto def = definitions.find(code[in.at + 1]);
        if (def == definitions.end() || all[def->second].op != kOpVariable) continue;
        uint32_t storage = code[all[def->second].at + 3];
        if (storage == kStorageInput || storage == kStorageOutput) cull.insert(code[in.at + 1]);
    }
    if (cull.empty()) return {};

    // Pointers derived from a rewritten variable, whose types become private pointers.
    std::unordered_set<uint32_t> derived(cull.begin(), cull.end());
    auto isChain = [](uint16_t op) {
        return op == kOpAccessChain || op == kOpInBoundsAccessChain || op == kOpPtrAccessChain ||
               op == kOpCopyObject;
    };
    for (bool grew = true; grew;) {
        grew = false;
        for (const Instruction& in : all)
            if (isChain(in.op) && in.count >= 4 && derived.count(code[in.at + 3]))
                grew |= derived.insert(code[in.at + 2]).second;
    }

    uint32_t bound = code[3];
    // Pointer types by (storage, pointee), and each pointer type's (storage, pointee).
    auto key = [](uint32_t storage, uint32_t pointee) { return (uint64_t(pointee) << 8) | storage; };
    std::unordered_map<uint64_t, uint32_t> pointerIds;
    std::unordered_map<uint32_t, std::pair<uint32_t, uint32_t>> pointers;
    std::unordered_map<uint32_t, uint32_t> nulls;  // type -> its OpConstantNull
    for (const Instruction& in : all) {
        if (in.op == kOpTypePointer && in.count == 4) {
            pointerIds[key(code[in.at + 2], code[in.at + 3])] = code[in.at + 1];
            pointers[code[in.at + 1]] = {code[in.at + 2], code[in.at + 3]};
        }
        if (in.op == kOpConstantNull && in.count == 3) nulls.emplace(code[in.at + 1], code[in.at + 2]);
    }
    // New instructions, each placed right after the instruction (by index) it follows.
    std::unordered_map<size_t, std::vector<uint32_t>> after;
    std::unordered_map<uint32_t, uint32_t> privateOf;  // old pointer type -> private one
    auto privatePointer = [&](uint32_t pointerType) -> bool {
        if (privateOf.count(pointerType)) return true;
        auto old = pointers.find(pointerType);
        if (old == pointers.end()) return false;
        uint32_t pointee = old->second.second;
        auto found = pointerIds.find(key(kStoragePrivate, pointee));
        uint32_t id = found != pointerIds.end() ? found->second : bound++;
        if (found == pointerIds.end()) {
            pointerIds[key(kStoragePrivate, pointee)] = id;
            auto& out = after[definitions[pointerType]];
            out.insert(out.end(), {(4u << 16) | kOpTypePointer, id, kStoragePrivate, pointee});
        }
        privateOf[pointerType] = id;
        return true;
    };
    std::unordered_map<uint32_t, uint32_t> initOf;  // variable -> its zero initialiser
    for (const Instruction& in : all) {
        const uint32_t* w = code + in.at;
        if (in.op == kOpVariable && cull.count(w[2])) {
            if (!privatePointer(w[1])) return {};
            uint32_t pointee = pointers[w[1]].second;
            auto found = nulls.find(pointee);
            if (found == nulls.end()) {
                found = nulls.emplace(pointee, bound++).first;
                auto& out = after[definitions[w[1]]];
                out.insert(out.end(), {(3u << 16) | kOpConstantNull, pointee, found->second});
            }
            initOf[w[2]] = found->second;
        } else if (isChain(in.op) && in.count >= 4 && derived.count(w[2])) {
            if (!privatePointer(w[1])) return {};
        }
    }

    // Private variables are listed by entry points only from SPIR-V 1.4.
    const bool listPrivate = code[1] >= 0x00010400;
    std::vector<uint32_t> out(code, code + 5);
    out.reserve(words + 32);
    for (size_t i = 0; i < all.size(); ++i) {
        const Instruction& in = all[i];
        const uint32_t* w = code + in.at;
        std::vector<uint32_t> copy(w, w + in.count);
        bool keep = true;
        if (in.op == kOpCapability) {
            keep = w[1] != kCapabilityCullDistance;
        } else if (in.op == kOpDecorate) {
            keep = !(cull.count(w[1]) && w[2] == kDecorationBuiltIn);
        } else if (in.op == kOpEntryPoint && !listPrivate) {
            // Interface ids follow the execution model, the entry point and its name, a
            // string ending in the first word with a zero byte.
            size_t first = 3;
            while (first < copy.size()) {
                uint32_t word = copy[first++];
                if (!(word & 0xff000000u) || !(word & 0xff0000u) || !(word & 0xff00u) || !(word & 0xffu)) break;
            }
            std::vector<uint32_t> kept(copy.begin(), copy.begin() + first);
            for (size_t j = first; j < copy.size(); ++j)
                if (!cull.count(copy[j])) kept.push_back(copy[j]);
            copy = kept;
        } else if (in.op == kOpVariable && cull.count(w[2])) {
            copy = {0, privateOf[w[1]], w[2], kStoragePrivate, initOf[w[2]]};
        } else if (isChain(in.op) && in.count >= 4 && derived.count(w[2])) {
            copy[1] = privateOf[w[1]];
        }
        if (keep) {
            copy[0] = (uint32_t(copy.size()) << 16) | in.op;
            out.insert(out.end(), copy.begin(), copy.end());
        }
        auto extra = after.find(i);
        if (extra != after.end()) out.insert(out.end(), extra->second.begin(), extra->second.end());
    }
    out[3] = bound;
    return out;
}

// ---------------------------------------------------------------------------------------
// Pipelines
// ---------------------------------------------------------------------------------------

// What the driver approximates in pipelines for a phone that lacks it.
struct PipelineEmulation {
    bool depthClip = false;       // VK_EXT_depth_clip_enable
    bool geometryShader = false;  // geometryShader
    bool cullDistance = false;    // shaderCullDistance
};

// Storage for the copies `adjustGraphicsPipelines` points pipelines at.
struct PipelineCopies {
    std::vector<VkPipelineRasterizationStateCreateInfo> rasterization;
    std::vector<std::vector<VkPipelineShaderStageCreateInfo>> stages;
    std::vector<VkPipelineDynamicStateCreateInfo> dynamic;
    std::vector<std::vector<VkDynamicState>> dynamicStates;
    std::vector<VkShaderModuleCreateInfo> modules;
    std::vector<std::vector<uint32_t>> code;
    // Copies of the pNext structures before a removed one, by size.
    std::vector<std::vector<uint8_t>> chain;
};

// The size of a rasterization state extension structure the driver may copy, or 0.
inline size_t rasterizationStructSize(VkStructureType type) {
    switch (type) {
        case VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_STREAM_CREATE_INFO_EXT:
            return sizeof(VkPipelineRasterizationStateStreamCreateInfoEXT);
        case VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT:
            return sizeof(VkPipelineRasterizationDepthClipStateCreateInfoEXT);
        case VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_CONSERVATIVE_STATE_CREATE_INFO_EXT:
            return sizeof(VkPipelineRasterizationConservativeStateCreateInfoEXT);
        case VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_LINE_STATE_CREATE_INFO_KHR:
            return sizeof(VkPipelineRasterizationLineStateCreateInfoKHR);
        case VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT:
            return sizeof(VkPipelineRasterizationProvokingVertexStateCreateInfoEXT);
        default:
            return 0;
    }
}

// `first` without the structure of `type`, copying the structures before it into `copies`.
// Returns `first` unchanged when the structure is absent or follows one it cannot copy.
inline const void* chainWithout(const void* first, VkStructureType type,
                                std::vector<std::vector<uint8_t>>& copies) {
    std::vector<const VkBaseInStructure*> before;
    const VkBaseInStructure* found = nullptr;
    for (auto* s = static_cast<const VkBaseInStructure*>(first); s; s = s->pNext) {
        if (s->sType == type) {
            found = s;
            break;
        }
        if (!rasterizationStructSize(s->sType)) return first;
        before.push_back(s);
    }
    if (!found) return first;
    const void* next = found->pNext;
    for (auto it = before.rbegin(); it != before.rend(); ++it) {
        size_t size = rasterizationStructSize((*it)->sType);
        copies.emplace_back(reinterpret_cast<const uint8_t*>(*it), reinterpret_cast<const uint8_t*>(*it) + size);
        reinterpret_cast<VkBaseInStructure*>(copies.back().data())->pNext =
            static_cast<const VkBaseInStructure*>(next);
        next = copies.back().data();
    }
    return next;
}

// The shader module a stage carries in its own pNext chain, first in it, as DXVK places it.
inline const VkShaderModuleCreateInfo* inlineModule(const VkPipelineShaderStageCreateInfo& stage) {
    auto* first = static_cast<const VkBaseInStructure*>(stage.pNext);
    if (!first || first->sType != VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO) return nullptr;
    return reinterpret_cast<const VkShaderModuleCreateInfo*>(first);
}

// Adjusts `infos` for what the phone lacks, pointing changed pipelines at copies kept in
// `copies`; true if any changed. A pipeline with a geometry stage keeps only its vertex
// stage and discards rasterization; a depth clip state becomes the depth clamp; a stage's
// own shader module loses its cull distances.
inline bool adjustGraphicsPipelines(std::vector<VkGraphicsPipelineCreateInfo>& infos,
                                    PipelineEmulation emulation, PipelineCopies& copies) {
    copies = PipelineCopies();
    size_t stageTotal = 0;
    for (const VkGraphicsPipelineCreateInfo& info : infos) stageTotal += info.pStages ? info.stageCount : 0;
    // Pointers into these stay valid: they never grow past what is reserved here.
    copies.rasterization.reserve(infos.size());
    copies.stages.reserve(infos.size());
    copies.dynamic.reserve(infos.size());
    copies.dynamicStates.reserve(infos.size());
    copies.modules.reserve(stageTotal);
    copies.code.reserve(stageTotal);
    bool changed = false;
    for (VkGraphicsPipelineCreateInfo& info : infos) {
        bool geometry = false;
        for (uint32_t s = 0; emulation.geometryShader && info.pStages && s < info.stageCount; ++s)
            geometry |= info.pStages[s].stage == VK_SHADER_STAGE_GEOMETRY_BIT;
        auto* clip = static_cast<const VkPipelineRasterizationDepthClipStateCreateInfoEXT*>(nullptr);
        if (emulation.depthClip && info.pRasterizationState) {
            for (auto* s = static_cast<const VkBaseInStructure*>(info.pRasterizationState->pNext); s; s = s->pNext)
                if (s->sType == VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT)
                    clip = reinterpret_cast<const VkPipelineRasterizationDepthClipStateCreateInfoEXT*>(s);
        }
        // Stages kept, with the cull distances of their own shader modules rewritten.
        std::vector<VkPipelineShaderStageCreateInfo> stages;
        bool stagesChanged = geometry;
        for (uint32_t s = 0; info.pStages && s < info.stageCount; ++s) {
            VkPipelineShaderStageCreateInfo stage = info.pStages[s];
            if (geometry && stage.stage != VK_SHADER_STAGE_VERTEX_BIT) continue;
            const VkShaderModuleCreateInfo* module = emulation.cullDistance ? inlineModule(stage) : nullptr;
            if (module) {
                std::vector<uint32_t> code = withoutCullDistances(module->pCode, module->codeSize / 4);
                if (!code.empty()) {
                    copies.code.push_back(std::move(code));
                    copies.modules.push_back(*module);
                    copies.modules.back().pCode = copies.code.back().data();
                    copies.modules.back().codeSize = copies.code.back().size() * 4;
                    stage.pNext = &copies.modules.back();
                    stagesChanged = true;
                }
            }
            stages.push_back(stage);
        }
        if (!stagesChanged && !clip) continue;
        changed = true;
        if (stagesChanged) {
            copies.stages.push_back(std::move(stages));
            info.stageCount = uint32_t(copies.stages.back().size());
            info.pStages = copies.stages.back().data();
        }
        if (info.pRasterizationState && (clip || geometry)) {
            copies.rasterization.push_back(*info.pRasterizationState);
            VkPipelineRasterizationStateCreateInfo& rs = copies.rasterization.back();
            if (clip) {
                rs.depthClampEnable = clip->depthClipEnable ? VK_FALSE : VK_TRUE;
                rs.pNext = chainWithout(rs.pNext, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT,
                                        copies.chain);
            }
            if (geometry) rs.rasterizerDiscardEnable = VK_TRUE;
            info.pRasterizationState = &rs;
        }
        if (!geometry) continue;
        info.pTessellationState = nullptr;
        // Rasterization stays discarded: it is no longer the command buffer's to turn on.
        if (info.pDynamicState) {
            copies.dynamic.push_back(*info.pDynamicState);
            copies.dynamicStates.emplace_back();
            for (uint32_t d = 0; d < info.pDynamicState->dynamicStateCount; ++d) {
                VkDynamicState state = info.pDynamicState->pDynamicStates[d];
                if (state != VK_DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE) copies.dynamicStates.back().push_back(state);
            }
            copies.dynamic.back().dynamicStateCount = uint32_t(copies.dynamicStates.back().size());
            copies.dynamic.back().pDynamicStates = copies.dynamicStates.back().data();
            info.pDynamicState = &copies.dynamic.back();
        }
    }
    return changed;
}

}  // namespace caboose::features
