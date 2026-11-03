// SPDX-License-Identifier: MIT
// Fills a new executor session's capability cache before applications ask (README.md).
//
//   caboose-gpu-warmup                 start the GL implementation it runs under once
//   caboose-gpu-warmup --replay LOG... ask again, from many threads at once, every capability
//                                      question recorded in earlier sessions' logs
//
// The first draws nothing and needs no window system: EGL's surfaceless platform and a
// context made current without a surface. Only libEGL is loaded, at run time, so one
// binary runs on the computer and inside any Flatpak runtime. The second asks the new
// executor itself: answers are never carried over from an earlier session, only which
// questions were asked, so they arrive in about one round trip per thread's share
// instead of one per question in turn.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

typedef void* Display;
typedef void* Context;
typedef unsigned int Boolean;
typedef intptr_t Attribute;
enum {
    kPlatformSurfaceless = 0x31DD, kOpenGL = 0x30A2, kNone = 0x3038,
    kMajor = 0x3098, kMinor = 0x30FB, kRenderer = 0x1F01,
};

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec * 1000.0 + value.tv_nsec / 1e6;
}

// The cache's opcodes (static_query_cache.h keys: opcode, then the query's parameters,
// as the driver's patches 0024, 0052 and 0065 build them).
enum {
    kFormat = 20004, kImage = 20005, kFormat2 = 20149, kImage2 = 20150, kFormat2KHR = 20200, kImage2KHR = 20201,
    kSemaphore = 20163,
    kMaxQuestions = 8192, kProcesses = 8, kMaxIdentities = 16,
};
typedef struct { uint32_t op, format, type, tiling, usage, flags, three; uint64_t initial; } Question;
static Question questions[kMaxQuestions];
static size_t asked;
// The logged scopes' identities, which name the device each was asked of.
static unsigned char* identities[kMaxIdentities];
static size_t identitySizes[kMaxIdentities], identityCount;
static VkPhysicalDevice* devices;
static uint32_t deviceCount;
static PFN_vkGetPhysicalDeviceFormatProperties formatProperties;
static PFN_vkGetPhysicalDeviceFormatProperties2 formatProperties2;
static PFN_vkGetPhysicalDeviceImageFormatProperties imageProperties;
static PFN_vkGetPhysicalDeviceImageFormatProperties2 imageProperties2;
static PFN_vkGetPhysicalDeviceFormatProperties2KHR formatProperties2KHR;
static PFN_vkGetPhysicalDeviceImageFormatProperties2KHR imageProperties2KHR;
static PFN_vkGetPhysicalDeviceExternalSemaphoreProperties semaphoreProperties;

static uint64_t digest(const unsigned char* bytes, size_t count, uint64_t hash) {
    for (size_t i = 0; i < count; ++i) hash = (hash ^ bytes[i]) * 0x100000001b3ull;
    return hash;
}

static int known(const Question* question) {
    for (size_t i = 0; i < asked; ++i)
        if (!memcmp(&questions[i], question, sizeof(*question))) return 1;
    return 0;
}

// One log: an 8-byte magic, the identity, then checksummed records. Only answers are
// read ('P' keys: scope, then opcode and parameters); damaged records end the file.
static void read_log(const char* path) {
    FILE* file = fopen(path, "rb");
    if (!file) return;
    static unsigned char bytes[8u << 20];
    size_t size = fread(bytes, 1, sizeof(bytes), file);
    fclose(file);
    uint32_t identity = 0;
    if (size < 12 || memcmp(bytes, "CBCQ\2\0\0\0", 8)) return;
    memcpy(&identity, bytes + 8, 4);
    if (identity > size - 12) return;
    if (identityCount < kMaxIdentities && (identities[identityCount] = malloc(identity)))
        memcpy(identities[identityCount], bytes + 12, identity), identitySizes[identityCount++] = identity;
    size_t at = 12 + (size_t)identity;
    while (at + 16 <= size && asked < kMaxQuestions) {
        uint32_t keys, values; uint64_t checksum;
        memcpy(&keys, bytes + at, 4); memcpy(&values, bytes + at + 4, 4); memcpy(&checksum, bytes + at + 8, 8);
        if (keys < 5 + identity + 4 || size - at - 16 < (size_t)keys + values) break;
        const unsigned char* key = bytes + at + 16;
        if (digest(key, (size_t)keys + values, 0xcbf29ce484222325ull) != checksum) break;
        at += 16 + (size_t)keys + values;
        if (key[0] != 'P') continue;
        const unsigned char* query = key + 5 + identity;
        size_t length = keys - 5 - identity;
        Question question = {0};
        memcpy(&question.op, query, 4);
        uint32_t fields[5] = {0};
        if (length > 4 && length - 4 <= sizeof(fields)) memcpy(fields, query + 4, length - 4);
        switch (question.op) {
        case kFormat: if (length != 8) continue; question.format = fields[0]; break;
        case kFormat2: case kFormat2KHR: if (length != 12) continue;
            question.format = fields[0]; question.three = fields[1] == 3; break;
        case kImage: case kImage2: case kImage2KHR: if (length != 24) continue;
            question.format = fields[0]; question.type = fields[1]; question.tiling = fields[2];
            question.usage = fields[3]; question.flags = fields[4]; break;
        case kSemaphore: if (length != 24) continue;
            // handle type, whether a semaphore type is chained, the type, its initial value
            question.usage = fields[0]; question.three = fields[1]; question.type = fields[2];
            memcpy(&question.initial, &fields[3], 8); break;
        default: continue;
        }
        if (!known(&question)) questions[asked++] = question;
    }
}

static void ask(size_t first, size_t step) {
    for (size_t i = first; i < asked; i += step) {
        const Question* q = &questions[i];
        for (uint32_t d = 0; d < deviceCount; ++d) {
            if (q->op == kFormat) {
                VkFormatProperties value;
                formatProperties(devices[d], (VkFormat)q->format, &value);
            } else if (q->op == kFormat2 || q->op == kFormat2KHR) {
                VkFormatProperties3 three = {VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3};
                VkFormatProperties2 value = {VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2, q->three ? &three : NULL};
                (q->op == kFormat2 ? formatProperties2 : formatProperties2KHR)(devices[d], (VkFormat)q->format, &value);
            } else if (q->op == kSemaphore) {
                VkSemaphoreTypeCreateInfo type = {VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
                type.semaphoreType = (VkSemaphoreType)q->type; type.initialValue = q->initial;
                VkPhysicalDeviceExternalSemaphoreInfo info = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
                                                              q->three ? &type : NULL};
                info.handleType = (VkExternalSemaphoreHandleTypeFlagBits)q->usage;
                VkExternalSemaphoreProperties value = {VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES};
                semaphoreProperties(devices[d], &info, &value);
            } else if (q->op == kImage) {
                VkImageFormatProperties value;
                imageProperties(devices[d], (VkFormat)q->format, (VkImageType)q->type, (VkImageTiling)q->tiling,
                                q->usage, q->flags, &value);
            } else {
                VkPhysicalDeviceImageFormatInfo2 info = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};
                info.format = (VkFormat)q->format; info.type = (VkImageType)q->type;
                info.tiling = (VkImageTiling)q->tiling; info.usage = q->usage; info.flags = q->flags;
                VkImageFormatProperties2 value = {VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2};
                (q->op == kImage2 ? imageProperties2 : imageProperties2KHR)(devices[d], &info, &value);
            }
        }
    }
}

// Whether a logged scope was this device: its identity holds the device's name.
static int logged(const char* name) {
    size_t length = strlen(name);
    for (size_t i = 0; i < identityCount && length; ++i)
        if (memmem(identities[i], identitySizes[i], name, length)) return 1;
    return 0;
}

// The driver keys each query by the entry point the application called, so *2KHR
// questions are asked through the extension's entry points.
// One process asks every `step`th question from `first`. The executor answers separate
// processes side by side, while one process's questions are answered in turn.
static int ask_share(size_t first, size_t step) {
    void* loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!loader) { fprintf(stderr, "caboose-gpu-warmup: %s\n", dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr proc = (PFN_vkGetInstanceProcAddr)dlsym(loader, "vkGetInstanceProcAddr");
    PFN_vkCreateInstance create = proc ? (PFN_vkCreateInstance)proc(NULL, "vkCreateInstance") : NULL;
    if (!create) return 1;
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "caboose-gpu-warmup"; app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    info.pApplicationInfo = &app;
    const char* extensions[] = {VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME};
    info.enabledExtensionCount = 1; info.ppEnabledExtensionNames = extensions;
    VkInstance instance;
    if (create(&info, NULL, &instance) != VK_SUCCESS) { fprintf(stderr, "caboose-gpu-warmup: no Vulkan instance\n"); return 1; }
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)proc(instance, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties2 properties = (PFN_vkGetPhysicalDeviceProperties2)proc(instance, "vkGetPhysicalDeviceProperties2");
    formatProperties = (PFN_vkGetPhysicalDeviceFormatProperties)proc(instance, "vkGetPhysicalDeviceFormatProperties");
    formatProperties2 = (PFN_vkGetPhysicalDeviceFormatProperties2)proc(instance, "vkGetPhysicalDeviceFormatProperties2");
    imageProperties = (PFN_vkGetPhysicalDeviceImageFormatProperties)proc(instance, "vkGetPhysicalDeviceImageFormatProperties");
    imageProperties2 = (PFN_vkGetPhysicalDeviceImageFormatProperties2)proc(instance, "vkGetPhysicalDeviceImageFormatProperties2");
    formatProperties2KHR = (PFN_vkGetPhysicalDeviceFormatProperties2KHR)proc(instance, "vkGetPhysicalDeviceFormatProperties2KHR");
    imageProperties2KHR = (PFN_vkGetPhysicalDeviceImageFormatProperties2KHR)proc(instance, "vkGetPhysicalDeviceImageFormatProperties2KHR");
    semaphoreProperties = (PFN_vkGetPhysicalDeviceExternalSemaphoreProperties)proc(instance, "vkGetPhysicalDeviceExternalSemaphoreProperties");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)proc(instance, "vkDestroyInstance");
    if (!enumerate || !properties || !formatProperties || !formatProperties2 || !imageProperties || !imageProperties2 ||
        !formatProperties2KHR || !imageProperties2KHR || !semaphoreProperties ||
        enumerate(instance, &deviceCount, NULL) != VK_SUCCESS || !deviceCount) {
        if (destroy) destroy(instance, NULL);
        return 1;
    }
    devices = calloc(deviceCount, sizeof(*devices));
    if (!devices || (enumerate(instance, &deviceCount, devices) != VK_SUCCESS)) return 1;
    // The properties query is what identifies each device to the cache; only devices the
    // logs were asked of are asked again (all of them when none can be told apart).
    uint32_t kept = 0;
    VkPhysicalDevice* all = devices;
    VkPhysicalDevice chosen[16];
    for (uint32_t d = 0; d < deviceCount && kept < 16; ++d) {
        VkPhysicalDeviceProperties2 value = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        properties(all[d], &value);
        if (logged(value.properties.deviceName)) chosen[kept++] = all[d];
    }
    if (kept) { devices = chosen; deviceCount = kept; }
    ask(first, step);
    devices = all;
    destroy(instance, NULL);
    return 0;
}

static int replay(int count, char** logs) {
    const double started = now();
    for (int i = 0; i < count; ++i) read_log(logs[i]);
    if (!asked) return 0;
    const size_t processes = asked < kProcesses ? asked : kProcesses;
    pid_t children[kProcesses];
    size_t forked = 0;
    for (size_t k = 1; k < processes; ++k) {
        fflush(NULL);
        pid_t child = fork();
        if (child == 0) _exit(ask_share(k, processes));
        if (child > 0) children[forked++] = child;
    }
    int failed = ask_share(0, processes);
    for (size_t k = 0; k < forked; ++k) {
        int status = 0;
        if (waitpid(children[k], &status, 0) != children[k] || !WIFEXITED(status) || WEXITSTATUS(status)) failed = 1;
    }
    printf("CABOOSE_GPU_WARMUP replayed=%zu processes=%zu ms=%.1f%s\n", asked, forked + 1, now() - started,
           failed ? " incomplete" : "");
    return failed;
}

int main(int argc, char** argv) {
    if (argc >= 2 && !strcmp(argv[1], "--replay")) return replay(argc - 2, argv + 2);
    if (argc != 1) { fprintf(stderr, "usage: caboose-gpu-warmup [--replay LOG...]\n"); return 2; }
    const double started = now();
    void* egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!egl) { fprintf(stderr, "caboose-gpu-warmup: %s\n", dlerror()); return 1; }
    void* (*proc)(const char*) = (void* (*)(const char*))dlsym(egl, "eglGetProcAddress");
    Display (*platform)(unsigned, void*, const Attribute*) =
        (Display (*)(unsigned, void*, const Attribute*))dlsym(egl, "eglGetPlatformDisplay");
    Boolean (*initialize)(Display, int*, int*) = (Boolean (*)(Display, int*, int*))dlsym(egl, "eglInitialize");
    Boolean (*bind)(unsigned) = (Boolean (*)(unsigned))dlsym(egl, "eglBindAPI");
    Context (*create)(Display, void*, Context, const int*) =
        (Context (*)(Display, void*, Context, const int*))dlsym(egl, "eglCreateContext");
    Boolean (*current)(Display, void*, void*, Context) =
        (Boolean (*)(Display, void*, void*, Context))dlsym(egl, "eglMakeCurrent");
    Boolean (*destroy)(Display, Context) = (Boolean (*)(Display, Context))dlsym(egl, "eglDestroyContext");
    Boolean (*terminate)(Display) = (Boolean (*)(Display))dlsym(egl, "eglTerminate");
    if (!proc || !platform || !initialize || !bind || !create || !current || !destroy || !terminate) {
        fprintf(stderr, "caboose-gpu-warmup: libEGL lacks EGL 1.5\n");
        return 1;
    }
    Display display = platform(kPlatformSurfaceless, NULL, NULL);
    int major = 0, minor = 0;
    if (!display || !initialize(display, &major, &minor) || !bind(kOpenGL)) {
        fprintf(stderr, "caboose-gpu-warmup: no surfaceless EGL display\n");
        return 1;
    }
    // A compatibility context, as GLX applications get: its creation runs the same
    // format and limit discovery theirs does. A context needs no config or surface here.
    const int attributes[] = { kMajor, 2, kMinor, 1, kNone };
    Context context = create(display, NULL, NULL, attributes);
    if (!context || !current(display, NULL, NULL, context)) {
        fprintf(stderr, "caboose-gpu-warmup: no GL context\n");
        terminate(display);
        return 1;
    }
    const unsigned char* (*string)(unsigned) = (const unsigned char* (*)(unsigned))proc("glGetString");
    const unsigned char* renderer = string ? string(kRenderer) : NULL;
    printf("CABOOSE_GPU_WARMUP renderer=\"%s\" ms=%.1f\n", renderer ? (const char*)renderer : "", now() - started);
    current(display, NULL, NULL, NULL);
    destroy(display, context);
    terminate(display);
    return 0;
}
