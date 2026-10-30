// SPDX-License-Identifier: MIT
// Real xdg toplevel with no wl_buffer; stdout reports object and configure events.
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>
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

static void put32(unsigned char *p, uint32_t n) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(n >> (8 * i));
}
static void put64(unsigned char *p, uint64_t n) { put32(p, (uint32_t)n); put32(p + 4, (uint32_t)(n >> 32)); }
static uint32_t get32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t get64(const unsigned char *p) { return get32(p) | (uint64_t)get32(p + 4) << 32; }
static int unix_connect(const char *path, int kind) {
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, kind | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct timeval timeout = { .tv_sec = 10 };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) ||
        connect(fd, (struct sockaddr *)&addr, sizeof(addr))) { close(fd); return -1; }
    return fd;
}
static int read_exact(int fd, unsigned char *data, size_t length) {
    while (length) {
        ssize_t n = read(fd, data, length);
        if (n <= 0) return -1;
        data += n; length -= (size_t)n;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 1 && argc != 4) {
        fprintf(stderr, "usage: %s [STREAM_SOCKET SURFACE_SOCKET BOXED_INSTANCE]\n", argv[0]); return 2;
    }
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
    // Ensure the compositor has processed the surface before the separate CGB
    // bind races it on another socket.
    if (wl_display_roundtrip(display) < 0) { fprintf(stderr, "initial Wayland roundtrip failed\n"); return 1; }
    int stream_fd = -1, surface_fd = -1;
    if (argc == 4) {
        static const unsigned char hello[48] = {
            'C','B','G','L','R','E','F','1', 3,0,0,0, 0x30,0,0,0,
            0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
            0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0
        };
        char *end = NULL;
        errno = 0; unsigned long long instance = strtoull(argv[3], &end, 0);
        if (errno || !end || *end || !instance) { fprintf(stderr, "invalid boxed instance\n"); return 2; }
        stream_fd = unix_connect(argv[1], SOCK_STREAM);
        unsigned char reply[48]; uint32_t flags = 0;
        if (stream_fd < 0 || write(stream_fd, hello, sizeof(hello)) != (ssize_t)sizeof(hello) ||
            read_exact(stream_fd, reply, sizeof(reply)) || memcmp(hello, reply, sizeof(hello)) ||
            write(stream_fd, &flags, sizeof(flags)) != (ssize_t)sizeof(flags)) {
            fprintf(stderr, "GPU stream handshake failed\n"); return 1;
        }
        surface_fd = unix_connect(argv[2], SOCK_SEQPACKET);
        unsigned char bind[40] = {'C','G','L','S', 1,0, 16,0};
        put32(bind + 8, sizeof(bind)); put64(bind + 16, (uint64_t)instance);
        put32(bind + 24, wl_proxy_get_id((struct wl_proxy *)surface));
        if (surface_fd < 0 || send(surface_fd, bind, sizeof(bind), 0) != (ssize_t)sizeof(bind)) {
            fprintf(stderr, "GPU surface bind failed\n"); return 1;
        }
    }
    int bound = 0;
    while (1) {
        if (wl_display_dispatch_pending(display) < 0 || wl_display_flush(display) < 0) break;
        struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {surface_fd, POLLIN, 0}};
        int count = poll(fds, surface_fd >= 0 && !bound ? 2 : 1, 10000);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { fprintf(stderr, "fixture timeout\n"); break; }
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if ((fds[0].revents & POLLIN) && wl_display_dispatch(display) < 0) break;
        if (surface_fd >= 0 && !bound && fds[1].revents) {
            unsigned char response[80];
            ssize_t n = recv(surface_fd, response, sizeof(response), MSG_TRUNC);
            if (n != (ssize_t)sizeof(response) || memcmp(response, "CGLS\1\0\21\0", 8) ||
                get32(response + 8) != sizeof(response) || get32(response + 12) ||
                !get64(response + 16) || !get64(response + 56) ||
                get32(response + 64) || get32(response + 68) > 1 || get32(response + 72) || get32(response + 76)) {
                fprintf(stderr, "surface bind rejected or malformed\n"); break;
            }
            printf("BOUND %llu %llu\n", (unsigned long long)get64(response + 16),
                   (unsigned long long)get64(response + 56)); fflush(stdout); bound = 1;
        }
    }
    if (surface_fd >= 0) close(surface_fd);
    if (stream_fd >= 0) close(stream_fd);
    xdg_toplevel_destroy(top);
    xdg_surface_destroy(f.xdg);
    wl_surface_destroy(surface);
    xdg_wm_base_destroy(f.wm);
    wl_compositor_destroy(f.compositor);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return 1;
}
