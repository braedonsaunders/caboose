// SPDX-License-Identifier: MIT
// Real Wayland Vulkan presentation, sharing the sync probe's clear/present sequence.
#define main xcb_sync_check_main
#include "sync_check.c"
#undef main
#include <wayland-client.h>
#include <vulkan/vulkan_wayland.h>
#include "xdg-shell-client-protocol.h"
static struct wl_compositor* compositor;
static struct xdg_wm_base* wm;
static int configured;
static void ping(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data; xdg_wm_base_pong(base,serial);
}
static const struct xdg_wm_base_listener wmListener={.ping=ping};
static void global(void* data, struct wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface,"wl_compositor")) compositor=wl_registry_bind(registry,name,&wl_compositor_interface,version<4?version:4);
    if (!strcmp(interface,"xdg_wm_base")) {
        wm=wl_registry_bind(registry,name,&xdg_wm_base_interface,1);
        xdg_wm_base_add_listener(wm,&wmListener,NULL);
    }
}
static void removed(void* data, struct wl_registry* registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registryListener={.global=global,.global_remove=removed};
static void configure(void* data, struct xdg_surface* surface, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(surface,serial); configured=1;
}
static const struct xdg_surface_listener surfaceListener={.configure=configure};
static void topConfigure(void* data, struct xdg_toplevel* top, int32_t width, int32_t height, struct wl_array* states) {
    (void)data; (void)top; (void)width; (void)height; (void)states;
}
static void topClose(void* data, struct xdg_toplevel* top) { (void)data; (void)top; }
static const struct xdg_toplevel_listener topListener={.configure=topConfigure,.close=topClose};
int main(int argc, char** argv) {
    const int frames=argc>1 ? atoi(argv[1]) : 1;
    if (frames<1 || frames>300) return 2;
    struct wl_display* display=wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry* registry=wl_display_get_registry(display);
    wl_registry_add_listener(registry,&registryListener,NULL);
    if (wl_display_roundtrip(display)<0 || !compositor || !wm) return 2;
    struct wl_surface* surface=wl_compositor_create_surface(compositor);
    struct xdg_surface* xdg=xdg_wm_base_get_xdg_surface(wm,surface);
    xdg_surface_add_listener(xdg,&surfaceListener,NULL);
    struct xdg_toplevel* top=xdg_surface_get_toplevel(xdg);
    xdg_toplevel_add_listener(top,&topListener,NULL);
    xdg_toplevel_set_title(top,"Caboose Vulkan presentation check");
    wl_surface_commit(surface);
    if (wl_display_roundtrip(display)<0 || !configured) return 2;
    const char* extensions[]={VK_KHR_SURFACE_EXTENSION_NAME,VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME};
    VkApplicationInfo app={VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.apiVersion=VK_API_VERSION_1_3;
    VkInstanceCreateInfo ii={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ii.pApplicationInfo=&app; ii.enabledExtensionCount=2; ii.ppEnabledExtensionNames=extensions;
    CHECK(vkCreateInstance(&ii,NULL,&instance));
    uint32_t count=1;
    VkResult enumerated=vkEnumeratePhysicalDevices(instance,&count,&physical);
    if ((enumerated!=VK_SUCCESS && enumerated!=VK_INCOMPLETE) || !count) return 2;
    VkQueueFamilyProperties families[32]; count=32;
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&count,families);
    for (family=0;family<count;++family) if (families[family].queueFlags&VK_QUEUE_GRAPHICS_BIT) break;
    if (family==count) return 2;
    float priority=1;
    VkDeviceQueueCreateInfo qi={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    const char* extension=VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    VkDeviceCreateInfo di={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    di.queueCreateInfoCount=1; di.pQueueCreateInfos=&qi; di.enabledExtensionCount=1; di.ppEnabledExtensionNames=&extension;
    CHECK(vkCreateDevice(physical,&di,NULL,&device)); vkGetDeviceQueue(device,family,0,&queue);
    VkCommandPoolCreateInfo pi={VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pi.queueFamilyIndex=family;
    CHECK(vkCreateCommandPool(device,&pi,NULL,&commandPool));
    VkCommandBufferAllocateInfo ai={VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    ai.commandPool=commandPool; ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount=1;
    CHECK(vkAllocateCommandBuffers(device,&ai,&cb));
    struct Presenter presenter={0};
    VkWaylandSurfaceCreateInfoKHR si={VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR};
    si.display=display; si.surface=surface;
    CHECK(vkCreateWaylandSurfaceKHR(instance,&si,NULL,&presenter.surface));
    presenterSetup(&presenter,320,240);
    for (int i=0;i<frames;++i) presenterFrame(&presenter,(float)i/frames);
    // A one-shot must reach the executor without any more Vulkan entry points.
    struct timespec pause={2,0}; nanosleep(&pause,NULL);
    presenterDestroy(&presenter);
    vkDestroyCommandPool(device,commandPool,NULL);
    vkDestroyDevice(device,NULL); vkDestroyInstance(instance,NULL);
    xdg_toplevel_destroy(top); xdg_surface_destroy(xdg); wl_surface_destroy(surface);
    xdg_wm_base_destroy(wm); wl_compositor_destroy(compositor); wl_registry_destroy(registry);
    wl_display_disconnect(display);
    report("wayland_present",presenter.presented==frames,"frames=%d accepted=%d",frames,presenter.presented);
    return failures ? 1 : 0;
}
