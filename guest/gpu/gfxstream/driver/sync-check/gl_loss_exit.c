// SPDX-License-Identifier: MIT
// gl_loss_exit SECONDS: renders with the platform GL (headless EGL, a context made current
// without a surface) and flushes every frame until SECONDS pass, then tears the context
// down and reports how long that took. check-gl-loss.sh ends the executor while it renders:
// the frames after the loss must fail quietly, and the teardown must return, so a GL client
// whose GPU left (the compositor's own renderer included) can make another.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

typedef void* Display;
typedef void* Context;
typedef unsigned int Boolean;
typedef intptr_t Attribute;
enum { kSurfaceless = 0x31DD, kOpenGL = 0x30A2, kNone = 0x3038, kMajor = 0x3098, kMinor = 0x30FB, kColor = 0x4000,
       kFramebuffer = 0x8D40, kRenderbuffer = 0x8D41, kRGBA8 = 0x8058, kColor0 = 0x8CE0 };

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
    const double seconds = argc > 1 ? atof(argv[1]) : 10;
    void* egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!egl) { fprintf(stderr, "gl_loss_exit: %s\n", dlerror()); return 1; }
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
    if (!proc || !platform || !initialize || !bind || !create || !current || !destroy || !terminate) return 1;
    Display display = platform(kSurfaceless, NULL, NULL);
    int major = 0, minor = 0;
    const int attributes[] = { kMajor, 2, kMinor, 1, kNone };
    Context context = display && initialize(display, &major, &minor) && bind(kOpenGL)
        ? create(display, NULL, NULL, attributes) : NULL;
    if (!context || !current(display, NULL, NULL, context)) { fprintf(stderr, "gl_loss_exit: no GL context\n"); return 1; }
    void (*clearColor)(float, float, float, float) = (void (*)(float, float, float, float))proc("glClearColor");
    void (*clear)(unsigned) = (void (*)(unsigned))proc("glClear");
    void (*finish)(void) = (void (*)(void))proc("glFinish");
    void (*genFramebuffers)(int, unsigned*) = (void (*)(int, unsigned*))proc("glGenFramebuffers");
    void (*bindFramebuffer)(unsigned, unsigned) = (void (*)(unsigned, unsigned))proc("glBindFramebuffer");
    void (*genRenderbuffers)(int, unsigned*) = (void (*)(int, unsigned*))proc("glGenRenderbuffers");
    void (*bindRenderbuffer)(unsigned, unsigned) = (void (*)(unsigned, unsigned))proc("glBindRenderbuffer");
    void (*storage)(unsigned, unsigned, int, int) = (void (*)(unsigned, unsigned, int, int))proc("glRenderbufferStorage");
    void (*attach)(unsigned, unsigned, unsigned, unsigned) =
        (void (*)(unsigned, unsigned, unsigned, unsigned))proc("glFramebufferRenderbuffer");
    if (!clearColor || !clear || !finish || !genFramebuffers || !bindFramebuffer || !genRenderbuffers ||
        !bindRenderbuffer || !storage || !attach) return 1;
    // An offscreen colour buffer, so every frame's clear is GPU work that is submitted.
    unsigned framebuffer = 0, renderbuffer = 0;
    genRenderbuffers(1, &renderbuffer); bindRenderbuffer(kRenderbuffer, renderbuffer);
    storage(kRenderbuffer, kRGBA8, 256, 256);
    genFramebuffers(1, &framebuffer); bindFramebuffer(kFramebuffer, framebuffer);
    attach(kFramebuffer, kColor0, kRenderbuffer, renderbuffer);
    unsigned frames = 0;
    const double started = now();
    while (now() - started < seconds) {
        clearColor((frames & 1) ? 1.0f : 0.0f, 0.5f, 0.25f, 1.0f);
        clear(kColor);
        finish();  // a flush and a submit every frame
        ++frames;
    }
    const double teardown = now();
    current(display, NULL, NULL, NULL);
    destroy(display, context);
    terminate(display);
    printf("CABOOSE_GL_LOSS frames=%u teardown_ms=%.1f\n", frames, (now() - teardown) * 1000);
    return 0;
}
