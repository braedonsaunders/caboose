// MoltenVK, linked into the same image, as the player and the capability query reach it.
//
// MoltenVK initializes some process-wide state without locks of its own: its configuration on
// the first Vulkan call of the process, its layer manager on the first instance-level query,
// and a scratch format table entry that every physical device writes while vkCreateInstance
// builds it. GetInstanceProcAddr hands out MoltenVK's functions with that first call made once,
// and with the instance-level calls (vkCreateInstance, vkDestroyInstance and the instance
// enumeration queries) made one at a time across the process. Device creation/destruction
// share that lock because MoltenVK can accumulate performance statistics process-wide.
// Both instance and device proc lookup preserve the underlying availability before
// substituting a wrapper. Everything else is MoltenVK's own function.
#ifndef CABOOSE_GPU_STREAM_MOLTENVK_H
#define CABOOSE_GPU_STREAM_MOLTENVK_H

#include <vulkan/vulkan.h>

namespace caboose::gpu_stream {

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name);

} // namespace caboose::gpu_stream

#endif // CABOOSE_GPU_STREAM_MOLTENVK_H
