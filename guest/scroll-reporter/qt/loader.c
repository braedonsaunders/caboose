// libcaboose-scroll-qt6.so, the Qt scroll reporter's preload library. Preloaded into every
// application, it links to nothing: only in a process that already has Qt Quick (and a
// scroll socket to report to) does it load the reporter itself, libcaboose-scroll-qt6-quick.so
// from its own directory, whose constructor registers with Qt before the application starts.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

__attribute__((constructor)) static void start(void) {
    if (!getenv("CABOOSE_SCROLL_SOCKET") || !dlsym(RTLD_DEFAULT, "_ZN12QQuickWindow16staticMetaObjectE")) return;
    Dl_info self;
    if (!dladdr((void *)start, &self) || !self.dli_fname) return;
    char path[PATH_MAX];
    const char *slash = strrchr(self.dli_fname, '/');
    int dir = slash ? (int)(slash - self.dli_fname) : 0;
    if (snprintf(path, sizeof path, "%.*s%slibcaboose-scroll-qt6-quick.so", dir, self.dli_fname, slash ? "/" : "") >= (int)sizeof path) return;
    if (!dlopen(path, RTLD_NOW | RTLD_LOCAL)) fprintf(stderr, "caboose-scroll: %s\n", dlerror());
}
