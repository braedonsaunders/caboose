// SPDX-License-Identifier: MIT
// Real xdg toplevel with no wl_buffer; stdout reports object and configure events.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

struct fixture {
    struct wl_compositor *compositor;
    struct xdg_wm_base *wm;
    struct xdg_surface *xdg;
    int32_t width, height;
};

static void ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    struct fixture *f = data;
    if (!strcmp(interface, wl_compositor_interface.name)) {
        if (f->compositor) return;
        f->compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (!strcmp(interface, xdg_wm_base_interface.name)) {
        if (f->wm) return;
        f->wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(f->wm, &wm_listener, f);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = global_remove };

static void top_configure(void *data, struct xdg_toplevel *top, int32_t width, int32_t height,
                          struct wl_array *states) {
    struct fixture *f = data;
    (void)top; (void)states;
    f->width = width; f->height = height;
}
static void top_close(void *data, struct xdg_toplevel *top) {
    (void)data; (void)top;
    exit(0);
}
static const struct xdg_toplevel_listener top_listener = { .configure = top_configure, .close = top_close };

static void surface_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    struct fixture *f = data;
    xdg_surface_ack_configure(xdg, serial);
    printf("CONFIGURE %u %d %d\n", serial, f->width, f->height);
    fflush(stdout);
}
static const struct xdg_surface_listener surface_listener = { .configure = surface_configure };

int main(void) {
    struct fixture f = {0};
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "Wayland connect: %s\n", strerror(errno)); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &f);
    if (wl_display_roundtrip(display) < 0 || !f.compositor || !f.wm) {
        fprintf(stderr, "required Wayland globals unavailable\n"); return 1;
    }
    struct wl_surface *surface = wl_compositor_create_surface(f.compositor);
    f.xdg = xdg_wm_base_get_xdg_surface(f.wm, surface);
    xdg_surface_add_listener(f.xdg, &surface_listener, &f);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(f.xdg);
    xdg_toplevel_add_listener(top, &top_listener, &f);
    xdg_toplevel_set_title(top, "Caboose unbuffered GPU fixture");
    xdg_toplevel_set_app_id(top, "caboose.gpu.unbuffered-fixture");
    printf("OBJECT %u\n", wl_proxy_get_id((struct wl_proxy *)surface));
    fflush(stdout);
    // Initial no-buffer commit only. No attachment, frame callback, or pixels.
    wl_surface_commit(surface);
    while (wl_display_dispatch(display) >= 0) {}
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(f.xdg);
    wl_surface_destroy(surface);
    xdg_wm_base_destroy(f.wm);
    wl_compositor_destroy(f.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 1;
}
