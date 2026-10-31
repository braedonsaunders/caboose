/*
 * caboose_wsi_promote.c — Implicit Vulkan WSI Layer (VK_LAYER_CABOOSE_wsi_promote)
 * and Mesa Zink OpenGL-to-Vulkan Promotion Gate for the Caboose OS Decomposition
 * ("Zero Server Video") architecture.
 *
 * Strictly gated on CABOOSE_WSI_AUTO_PROMOTE=1 (set only on the owner seat,
 * never on the agent seat). Leaves 2D desktop launchers/toolkits on the
 * Surface Atlas / Scene Graph lanes while promoting 3D / Vulkan / Zink / Proton
 * swapchains to the GPU command / media lane without stalling in headless mode.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "../src/scene_wire.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ========================================================================== *
 * Minimal Vulkan Layer ABI Types (Self-contained, no vulkan.h dependency)    *
 * ========================================================================== */

typedef int32_t  VkResult;
typedef uint32_t VkFlags;
typedef void    *VkInstance;
typedef void    *VkDevice;
typedef uint64_t VkSwapchainKHR;
typedef void     VkAllocationCallbacks;
typedef void     VkSwapchainCreateInfoKHR;
typedef void   (*PFN_vkVoidFunction)(void);

#define VK_SUCCESS 0

typedef enum VkNegotiateLayerStructType {
    LAYER_NEGOTIATE_INTERFACE_STRUCT = 1
} VkNegotiateLayerStructType;

typedef struct VkNegotiateLayerInterface {
    VkNegotiateLayerStructType sType;
    void                      *pNext;
    uint32_t                   loaderLayerInterfaceVersion;
    PFN_vkVoidFunction         pfnGetInstanceProcAddr;
    PFN_vkVoidFunction         pfnGetDeviceProcAddr;
    PFN_vkVoidFunction         pfnGetPhysicalDeviceProcAddr;
} VkNegotiateLayerInterface;

typedef VkResult (*PFN_vkCreateSwapchainKHR)(
    VkDevice                        device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks    *pAllocator,
    VkSwapchainKHR                 *pSwapchain
);

typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(
    VkDevice    device,
    const char *pName
);

typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(
    VkInstance  instance,
    const char *pName
);

/* ========================================================================== *
 * Denylist of 2D Desktop UI / Shell / Launcher / Electron Processes          *
 * ========================================================================== */

static const char *const k_denylist_2d_processes[] = {
    "waybar",
    "rofi",
    "wofi",
    "fuzzel",
    "dunst",
    "mako",
    "swaybg",
    "swaylock",
    "wl-paste",
    "wl-copy",
    "nautilus",
    "thunar",
    "pcmanfm",
    "dolphin",
    "gtk4-widget-factory",
    "gtk4-demo",
    "pavucontrol",
    "nm-connection-editor",
    "blueman-manager",
    "foot",
    "alacritty",
    "kitty",
    "wezterm",
    "xterm",
    "tmux",
    "bash",
    "zsh",
    "sh",
    "systemd",
    "dbus-daemon",
    "caboose-display",
    "caboose-agent",
    "claude-desktop",
    "chatgpt",
    "code",
    "obsidian",
    NULL
};

static const char *cb_basename(const char *path) {
    if (!path) {
        return "";
    }
    const char *slash = strrchr(path, '/');
    return slash ? (slash + 1) : path;
}

static void cb_read_current_process_name(char *buf, size_t buf_len) {
    if (!buf || buf_len == 0) {
        return;
    }
    buf[0] = '\0';

    const char *override_name = getenv("CABOOSE_PROCESS_NAME");
    if (override_name && override_name[0] != '\0') {
        strncpy(buf, cb_basename(override_name), buf_len - 1);
        buf[buf_len - 1] = '\0';
        return;
    }

#if defined(__linux__)
    FILE *f = fopen("/proc/self/comm", "r");
    if (f) {
        if (fgets(buf, (int)buf_len, f) != NULL) {
            size_t len = strlen(buf);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) {
                buf[--len] = '\0';
            }
        }
        fclose(f);
        if (buf[0] != '\0') {
            return;
        }
    }
#elif defined(__APPLE__)
    const char *prog = getprogname();
    if (prog && prog[0] != '\0') {
        strncpy(buf, cb_basename(prog), buf_len - 1);
        buf[buf_len - 1] = '\0';
        return;
    }
#endif

    strncpy(buf, "unknown", buf_len - 1);
    buf[buf_len - 1] = '\0';
}

static bool cb_is_denylisted_2d_process(const char *proc_name) {
    const char *base = cb_basename(proc_name);
    if (!base || base[0] == '\0') {
        return true;
    }
    for (size_t i = 0; k_denylist_2d_processes[i] != NULL; i++) {
        if (strcmp(base, k_denylist_2d_processes[i]) == 0) {
            return true;
        }
    }
    return false;
}

/* ========================================================================== *
 * Implicit WSI & Zink Promotion Gate                                         *
 * ========================================================================== */

/**
 * Pure policy evaluation helper for unit testing and runtime gating.
 *
 * Rules:
 *   1. `auto_promote_env` ("CABOOSE_WSI_AUTO_PROMOTE") MUST be "1".
 *   2. `seat_env` ("CABOOSE_SEAT") MUST NOT be "agent" (agent seat never
 *      auto-promotes to owner-seat GPU stream).
 *   3. `disable_env` ("CABOOSE_WSI_DISABLE") MUST NOT be "1".
 *   4. Process name must not be in the 2D UI / launcher / Electron denylist
 *      (unless `force_env` == "1").
 */
bool caboose_wsi_should_promote_process_ex(
    const char *proc_name,
    const char *auto_promote_env,
    const char *seat_env,
    const char *disable_env,
    const char *force_env
) {
    if (disable_env && strcmp(disable_env, "1") == 0) {
        return false;
    }
    if (!auto_promote_env || strcmp(auto_promote_env, "1") != 0) {
        return false;
    }
    if (seat_env && strcmp(seat_env, "agent") == 0) {
        return false;
    }
    if (force_env && strcmp(force_env, "1") == 0) {
        return true;
    }
    if (cb_is_denylisted_2d_process(proc_name)) {
        return false;
    }
    return true;
}

/**
 * Inspects current environment and process name (`proc_name_override` if
 * non-NULL, otherwise `/proc/self/comm` / `getprogname()`) to decide whether
 * this process's Vulkan / Mesa Zink swapchain should be promoted.
 */
bool caboose_wsi_should_promote_process(const char *proc_name_override) {
    char proc_buf[128];
    const char *proc_name = proc_name_override;
    if (!proc_name || proc_name[0] == '\0') {
        cb_read_current_process_name(proc_buf, sizeof(proc_buf));
        proc_name = proc_buf;
    }

    return caboose_wsi_should_promote_process_ex(
        proc_name,
        getenv("CABOOSE_WSI_AUTO_PROMOTE"),
        getenv("CABOOSE_SEAT"),
        getenv("CABOOSE_WSI_DISABLE"),
        getenv("CABOOSE_WSI_FORCE_PROMOTE")
    );
}

/**
 * Configure Mesa Zink (`MESA_LOADER_DRIVER_OVERRIDE=zink` and
 * `GALLIUM_DRIVER=zink`) for the current process if and only if WSI promotion
 * is active for this process.
 */
bool caboose_wsi_apply_zink_env_if_promoted(const char *proc_name_override) {
    if (!caboose_wsi_should_promote_process(proc_name_override)) {
        return false;
    }
    setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 0);
    setenv("GALLIUM_DRIVER", "zink", 0);
    return true;
}

/* ========================================================================== *
 * Vulkan Swapchain Interception & Headless Liveness                          *
 * ========================================================================== */

static uint64_t g_promoted_swapchains = 0;

uint64_t caboose_wsi_promoted_swapchain_count(void) {
    return g_promoted_swapchains;
}

/**
 * Intercepts `vkCreateSwapchainKHR`.
 * If the process qualifies for WSI promotion on the owner seat, records the
 * promotion and notifies the non-blocking GPU/scene socket if available.
 * Honors Invariant A (Headless Liveness): never blocks if the socket is
 * missing or disconnected.
 */
VkResult caboose_wsi_CreateSwapchainKHR(
    VkDevice                        device,
    const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks    *pAllocator,
    VkSwapchainKHR                 *pSwapchain
) {
    if (caboose_wsi_should_promote_process(NULL)) {
        g_promoted_swapchains++;

        /* Non-blocking probe to live socket (Invariant A: never stalls if dead) */
        cb_scene_client_t client;
        const char *gpu_sock = getenv("CABOOSE_GPU_SOCKET");
        if (!gpu_sock || gpu_sock[0] == '\0') {
            gpu_sock = getenv("CABOOSE_SCENE_SOCKET");
        }
        cb_scene_client_connect_path(&client, gpu_sock);
        cb_scene_client_close(&client);
    }

    static PFN_vkCreateSwapchainKHR real_create_swapchain = NULL;
    if (!real_create_swapchain) {
        real_create_swapchain = (PFN_vkCreateSwapchainKHR)dlsym(RTLD_NEXT, "vkCreateSwapchainKHR");
    }
    if (real_create_swapchain) {
        return real_create_swapchain(device, pCreateInfo, pAllocator, pSwapchain);
    }

    if (pSwapchain) {
        *pSwapchain = (VkSwapchainKHR)(0xCAB005E000000000ULL + g_promoted_swapchains);
    }
    return VK_SUCCESS;
}

PFN_vkVoidFunction caboose_wsi_GetDeviceProcAddr(VkDevice device, const char *pName) {
    if (pName && strcmp(pName, "vkCreateSwapchainKHR") == 0) {
        return (PFN_vkVoidFunction)caboose_wsi_CreateSwapchainKHR;
    }
    if (pName && strcmp(pName, "vkGetDeviceProcAddr") == 0) {
        return (PFN_vkVoidFunction)caboose_wsi_GetDeviceProcAddr;
    }
    static PFN_vkGetDeviceProcAddr next_gda = NULL;
    if (!next_gda) {
        next_gda = (PFN_vkGetDeviceProcAddr)dlsym(RTLD_NEXT, "vkGetDeviceProcAddr");
    }
    return next_gda ? next_gda(device, pName) : NULL;
}

PFN_vkVoidFunction caboose_wsi_GetInstanceProcAddr(VkInstance instance, const char *pName) {
    if (pName && strcmp(pName, "vkCreateSwapchainKHR") == 0) {
        return (PFN_vkVoidFunction)caboose_wsi_CreateSwapchainKHR;
    }
    if (pName && strcmp(pName, "vkGetDeviceProcAddr") == 0) {
        return (PFN_vkVoidFunction)caboose_wsi_GetDeviceProcAddr;
    }
    if (pName && strcmp(pName, "vkGetInstanceProcAddr") == 0) {
        return (PFN_vkVoidFunction)caboose_wsi_GetInstanceProcAddr;
    }
    static PFN_vkGetInstanceProcAddr next_gia = NULL;
    if (!next_gia) {
        next_gia = (PFN_vkGetInstanceProcAddr)dlsym(RTLD_NEXT, "vkGetInstanceProcAddr");
    }
    return next_gia ? next_gia(instance, pName) : NULL;
}

VkResult vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *pVersionStruct) {
    if (!pVersionStruct || pVersionStruct->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) {
        return -1;
    }
    if (pVersionStruct->loaderLayerInterfaceVersion > 2) {
        pVersionStruct->loaderLayerInterfaceVersion = 2;
    }
    pVersionStruct->pfnGetInstanceProcAddr = (PFN_vkVoidFunction)caboose_wsi_GetInstanceProcAddr;
    pVersionStruct->pfnGetDeviceProcAddr = (PFN_vkVoidFunction)caboose_wsi_GetDeviceProcAddr;
    pVersionStruct->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
