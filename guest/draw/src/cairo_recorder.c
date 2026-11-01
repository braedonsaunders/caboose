/*
 * libcaboose-draw-cairo.so: records what applications draw with cairo as Caboose draw lists
 * (cdl.h, docs/draw.md), so the device can draw it again with its own GPU at its own density.
 *
 * Loaded with LD_PRELOAD. It interposes the drawing calls toolkits make into cairo through the
 * PLT (fill, stroke, paint, mask, glyphs, clips, groups, surface creation and direct pixel
 * access), reads the state of each call through cairo's public getters, and calls cairo on.
 * Calls cairo makes internally never reach it, so each operation is recorded once. Every cairo,
 * FreeType and Wayland function is resolved with dlsym, so the library links nothing but libc
 * and is inert in processes without cairo. With neither CABOOSE_DRAW_CAPTURE nor a draw socket
 * it records nothing and only forwards calls.
 *
 * Wayland frames: it also interposes libwayland-client's request marshalling to see wl_shm
 * buffers and wl_surface commits. A commit of a buffer the recorder knows (by the memfd inode
 * and offset of its memory) ends that window surface's frame with a PRESENT op, written out
 * before the commit leaves the process.
 */
#define _GNU_SOURCE
#include <cairo.h>
#include <cairo-ft.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_TRUETYPE_TAGS_H
#include <inttypes.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <wayland-util.h>

#include "cdl.h"

#define EXPORT __attribute__((visibility("default")))

/* ------------------------------------------------------------------------------------------ */
/* Real functions                                                                              */

static void *real_sym(const char *name, const char *library) {
    void *p = dlsym(RTLD_NEXT, name);
    if (!p && library) {
        /* A library opened with RTLD_LOCAL (a Python or plugin process) is not on RTLD_NEXT's
         * path; ask it directly. */
        void *h = dlopen(library, RTLD_LAZY | RTLD_NOLOAD);
        if (h) p = dlsym(h, name);
    }
    return p;
}

#define CAIRO_LIB "libcairo.so.2"
#define FT_LIB "libfreetype.so.6"
#define WL_LIB "libwayland-client.so.0"

/* Every cairo function the recorder calls, real ones only (never its own hooks). */
#define CAIRO_FUNCTIONS(X)                                                                                  \
    X(void, cairo_fill, (cairo_t *))                                                                        \
    X(void, cairo_fill_preserve, (cairo_t *))                                                               \
    X(void, cairo_stroke, (cairo_t *))                                                                      \
    X(void, cairo_stroke_preserve, (cairo_t *))                                                             \
    X(void, cairo_paint, (cairo_t *))                                                                       \
    X(void, cairo_paint_with_alpha, (cairo_t *, double))                                                    \
    X(void, cairo_mask, (cairo_t *, cairo_pattern_t *))                                                     \
    X(void, cairo_mask_surface, (cairo_t *, cairo_surface_t *, double, double))                             \
    X(void, cairo_show_glyphs, (cairo_t *, const cairo_glyph_t *, int))                                     \
    X(void, cairo_show_text_glyphs, (cairo_t *, const char *, int, const cairo_glyph_t *, int,              \
                                     const cairo_text_cluster_t *, int, cairo_text_cluster_flags_t))       \
    X(void, cairo_show_text, (cairo_t *, const char *))                                                     \
    X(void, cairo_clip, (cairo_t *))                                                                        \
    X(void, cairo_clip_preserve, (cairo_t *))                                                               \
    X(void, cairo_reset_clip, (cairo_t *))                                                                  \
    X(void, cairo_save, (cairo_t *))                                                                        \
    X(void, cairo_restore, (cairo_t *))                                                                     \
    X(void, cairo_push_group, (cairo_t *))                                                                  \
    X(void, cairo_push_group_with_content, (cairo_t *, cairo_content_t))                                    \
    X(cairo_pattern_t *, cairo_pop_group, (cairo_t *))                                                      \
    X(void, cairo_pop_group_to_source, (cairo_t *))                                                         \
    X(cairo_surface_t *, cairo_image_surface_create, (cairo_format_t, int, int))                            \
    X(cairo_surface_t *, cairo_image_surface_create_for_data, (unsigned char *, cairo_format_t, int, int, int)) \
    X(cairo_surface_t *, cairo_surface_create_similar, (cairo_surface_t *, cairo_content_t, int, int))      \
    X(cairo_surface_t *, cairo_surface_create_similar_image, (cairo_surface_t *, cairo_format_t, int, int)) \
    X(unsigned char *, cairo_image_surface_get_data, (cairo_surface_t *))                                   \
    X(void, cairo_surface_mark_dirty, (cairo_surface_t *))                                                  \
    X(void, cairo_surface_mark_dirty_rectangle, (cairo_surface_t *, int, int, int, int))                    \
    X(cairo_surface_t *, cairo_get_target, (cairo_t *))                                                     \
    X(cairo_surface_t *, cairo_get_group_target, (cairo_t *))                                               \
    X(void, cairo_get_matrix, (cairo_t *, cairo_matrix_t *))                                                \
    X(cairo_path_t *, cairo_copy_path, (cairo_t *))                                                         \
    X(void, cairo_path_destroy, (cairo_path_t *))                                                           \
    X(cairo_pattern_t *, cairo_get_source, (cairo_t *))                                                     \
    X(cairo_operator_t, cairo_get_operator, (cairo_t *))                                                    \
    X(cairo_fill_rule_t, cairo_get_fill_rule, (cairo_t *))                                                  \
    X(cairo_antialias_t, cairo_get_antialias, (cairo_t *))                                                  \
    X(double, cairo_get_line_width, (cairo_t *))                                                            \
    X(cairo_line_cap_t, cairo_get_line_cap, (cairo_t *))                                                    \
    X(cairo_line_join_t, cairo_get_line_join, (cairo_t *))                                                  \
    X(double, cairo_get_miter_limit, (cairo_t *))                                                           \
    X(int, cairo_get_dash_count, (cairo_t *))                                                               \
    X(void, cairo_get_dash, (cairo_t *, double *, double *))                                                \
    X(void, cairo_get_font_matrix, (cairo_t *, cairo_matrix_t *))                                           \
    X(cairo_scaled_font_t *, cairo_get_scaled_font, (cairo_t *))                                            \
    X(cairo_bool_t, cairo_has_current_point, (cairo_t *))                                                   \
    X(void, cairo_get_current_point, (cairo_t *, double *, double *))                                       \
    X(cairo_status_t, cairo_set_user_data, (cairo_t *, const cairo_user_data_key_t *, void *,               \
                                            cairo_destroy_func_t))                                          \
    X(void *, cairo_get_user_data, (cairo_t *, const cairo_user_data_key_t *))                              \
    X(void, cairo_clip_extents, (cairo_t *, double *, double *, double *, double *))                        \
    X(void, cairo_glyph_extents, (cairo_t *, const cairo_glyph_t *, int, cairo_text_extents_t *))           \
    X(cairo_status_t, cairo_surface_set_user_data, (cairo_surface_t *, const cairo_user_data_key_t *,       \
                                                    void *, cairo_destroy_func_t))                          \
    X(void *, cairo_surface_get_user_data, (cairo_surface_t *, const cairo_user_data_key_t *))              \
    X(cairo_surface_type_t, cairo_surface_get_type, (cairo_surface_t *))                                    \
    X(cairo_status_t, cairo_surface_status, (cairo_surface_t *))                                            \
    X(void, cairo_surface_get_device_offset, (cairo_surface_t *, double *, double *))                       \
    X(void, cairo_surface_get_device_scale, (cairo_surface_t *, double *, double *))                        \
    X(void, cairo_surface_flush, (cairo_surface_t *))                                                       \
    X(void, cairo_surface_destroy, (cairo_surface_t *))                                                     \
    X(int, cairo_image_surface_get_width, (cairo_surface_t *))                                              \
    X(int, cairo_image_surface_get_height, (cairo_surface_t *))                                             \
    X(int, cairo_image_surface_get_stride, (cairo_surface_t *))                                             \
    X(cairo_format_t, cairo_image_surface_get_format, (cairo_surface_t *))                                  \
    X(cairo_bool_t, cairo_recording_surface_get_extents, (cairo_surface_t *, cairo_rectangle_t *))          \
    X(cairo_pattern_type_t, cairo_pattern_get_type, (cairo_pattern_t *))                                    \
    X(cairo_status_t, cairo_pattern_get_rgba, (cairo_pattern_t *, double *, double *, double *, double *))  \
    X(cairo_status_t, cairo_pattern_get_surface, (cairo_pattern_t *, cairo_surface_t **))                   \
    X(void, cairo_pattern_get_matrix, (cairo_pattern_t *, cairo_matrix_t *))                                \
    X(cairo_extend_t, cairo_pattern_get_extend, (cairo_pattern_t *))                                        \
    X(cairo_filter_t, cairo_pattern_get_filter, (cairo_pattern_t *))                                        \
    X(cairo_status_t, cairo_pattern_get_linear_points, (cairo_pattern_t *, double *, double *, double *,    \
                                                        double *))                                          \
    X(cairo_status_t, cairo_pattern_get_radial_circles, (cairo_pattern_t *, double *, double *, double *,   \
                                                         double *, double *, double *))                     \
    X(cairo_status_t, cairo_pattern_get_color_stop_count, (cairo_pattern_t *, int *))                       \
    X(cairo_status_t, cairo_pattern_get_color_stop_rgba, (cairo_pattern_t *, int, double *, double *,       \
                                                          double *, double *, double *))                    \
    X(cairo_font_face_t *, cairo_scaled_font_get_font_face, (cairo_scaled_font_t *))                        \
    X(void, cairo_scaled_font_get_font_options, (cairo_scaled_font_t *, cairo_font_options_t *))            \
    X(cairo_status_t, cairo_scaled_font_status, (cairo_scaled_font_t *))                                    \
    X(cairo_status_t, cairo_scaled_font_set_user_data, (cairo_scaled_font_t *, const cairo_user_data_key_t *, \
                                                        void *, cairo_destroy_func_t))                      \
    X(void *, cairo_scaled_font_get_user_data, (cairo_scaled_font_t *, const cairo_user_data_key_t *))      \
    X(cairo_status_t, cairo_scaled_font_text_to_glyphs, (cairo_scaled_font_t *, double, double,             \
                                                         const char *, int, cairo_glyph_t **, int *,        \
                                                         cairo_text_cluster_t **, int *,                    \
                                                         cairo_text_cluster_flags_t *))                     \
    X(void, cairo_glyph_free, (cairo_glyph_t *))                                                            \
    X(cairo_font_type_t, cairo_font_face_get_type, (cairo_font_face_t *))                                   \
    X(cairo_scaled_font_t *, cairo_scaled_font_create, (cairo_font_face_t *, const cairo_matrix_t *,        \
                                                        const cairo_matrix_t *, const cairo_font_options_t *)) \
    X(void, cairo_scaled_font_destroy, (cairo_scaled_font_t *))                                             \
    X(cairo_font_options_t *, cairo_font_options_create, (void))                                            \
    X(void, cairo_font_options_destroy, (cairo_font_options_t *))                                           \
    X(void, cairo_font_options_set_hint_style, (cairo_font_options_t *, cairo_hint_style_t))                \
    X(void, cairo_font_options_set_hint_metrics, (cairo_font_options_t *, cairo_hint_metrics_t))            \
    X(const char *, cairo_font_options_get_variations, (cairo_font_options_t *))                            \
    X(cairo_t *, cairo_create, (cairo_surface_t *))                                                         \
    X(void, cairo_destroy, (cairo_t *))                                                                     \
    X(void, cairo_set_scaled_font, (cairo_t *, const cairo_scaled_font_t *))                                \
    X(void, cairo_glyph_path, (cairo_t *, const cairo_glyph_t *, int))                                      \
    X(void, cairo_set_source_surface, (cairo_t *, cairo_surface_t *, double, double))                       \
    X(void, cairo_set_operator, (cairo_t *, cairo_operator_t))                                              \
    X(FT_Face, cairo_ft_scaled_font_lock_face, (cairo_scaled_font_t *))                                     \
    X(void, cairo_ft_scaled_font_unlock_face, (cairo_scaled_font_t *))                                      \
    X(unsigned int, cairo_ft_font_face_get_synthesize, (cairo_font_face_t *))

#define DECLARE(ret, name, args) static ret(*real_##name) args;
CAIRO_FUNCTIONS(DECLARE)
#undef DECLARE

static FT_Error (*real_FT_Load_Sfnt_Table)(FT_Face, FT_ULong, FT_Long, FT_Byte *, FT_ULong *);
static FT_Error (*real_FT_Get_Var_Design_Coordinates)(FT_Face, FT_UInt, FT_Fixed *);

static int cairo_ready;

static void resolve_cairo(void) {
    if (cairo_ready) return;
#define RESOLVE(ret, name, args) real_##name = (ret(*) args)real_sym(#name, CAIRO_LIB);
    CAIRO_FUNCTIONS(RESOLVE)
#undef RESOLVE
    real_FT_Load_Sfnt_Table = (FT_Error(*)(FT_Face, FT_ULong, FT_Long, FT_Byte *, FT_ULong *))real_sym("FT_Load_Sfnt_Table", FT_LIB);
    real_FT_Get_Var_Design_Coordinates =
        (FT_Error(*)(FT_Face, FT_UInt, FT_Fixed *))real_sym("FT_Get_Var_Design_Coordinates", FT_LIB);
    cairo_ready = 1;
}

/* ------------------------------------------------------------------------------------------ */
/* Recorder state                                                                              */

static pthread_mutex_t lock;
/* Recording now: always with a capture file; with the draw socket, between the compositor's
 * `R` and `S`. */
static int enabled;
static int capture_fd = -1;
static int sock_fd = -1;
static int capture_pixels;
static cdl_buf out;
/* The recording's generation: surfaces and resources of an earlier one are unknown to the
 * stream's reader. */
static uint32_t generation;
static __thread int depth;

static uint32_t next_surface_id = 1;
static uint32_t current_target;
static uint64_t current_clip = 1; /* hash of the last CLIP op's payload; 1 = none sent yet */

/* Bytes the socket has not taken yet, at most this many before the recorder gives up. */
#define MAX_UNSENT (64u << 20)

/* Open-addressed set of 64-bit keys: images and glyphs the stream already carries. */
typedef struct {
    uint64_t *keys;
    size_t cap, len;
} keyset;

static int keyset_add(keyset *s, uint64_t key) {
    if (key == 0) key = 1;
    if ((s->len + 1) * 2 > s->cap) {
        size_t cap = s->cap ? s->cap * 2 : 1024;
        uint64_t *keys = (uint64_t *)calloc(cap, sizeof *keys);
        if (!keys) return 0;
        for (size_t i = 0; i < s->cap; i++) {
            if (!s->keys[i]) continue;
            size_t j = s->keys[i] & (cap - 1);
            while (keys[j]) j = (j + 1) & (cap - 1);
            keys[j] = s->keys[i];
        }
        free(s->keys);
        s->keys = keys;
        s->cap = cap;
    }
    size_t j = key & (s->cap - 1);
    while (s->keys[j]) {
        if (s->keys[j] == key) return 0;
        j = (j + 1) & (s->cap - 1);
    }
    s->keys[j] = key;
    s->len++;
    return 1;
}

static void keyset_clear(keyset *s) {
    free(s->keys);
    s->keys = NULL;
    s->cap = s->len = 0;
}

static keyset sent_images, sent_glyphs;

/* Stops for good: the stream cannot be continued, and the application draws on unrecorded. */
static void give_up(void) {
    enabled = 0;
    if (sock_fd >= 0) close(sock_fd);
    sock_fd = -1;
    out.len = 0;
}

static void flush_out(void) {
    if (out.failed) {
        /* Out of memory once: what was recorded is incomplete. */
        give_up();
        return;
    }
    if (capture_fd >= 0) {
        size_t done = 0;
        while (done < out.len) {
            ssize_t n = write(capture_fd, out.data + done, out.len - done);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                enabled = 0;
                break;
            }
            done += (size_t)n;
        }
        out.len = 0;
    } else if (sock_fd >= 0) {
        /* Never waits: what the socket does not take now goes with the next flush. */
        size_t done = 0;
        while (done < out.len) {
            ssize_t n = send(sock_fd, out.data + done, out.len - done, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
            if (n <= 0) {
                give_up();
                return;
            }
            done += (size_t)n;
        }
        if (done) {
            memmove(out.data, out.data + done, out.len - done);
            out.len -= done;
        }
        if (out.len > MAX_UNSENT) give_up();
    } else {
        out.len = 0;
    }
}

/* A fresh recording: everything recorded so far is unknown to its reader. */
static void begin(uint32_t g) {
    generation = g;
    keyset_clear(&sent_images);
    keyset_clear(&sent_glyphs);
    current_target = 0;
    current_clip = 1;
    size_t at = cdl_begin(&out, CDL_BEGIN);
    cdl_u32(&out, g);
    cdl_end(&out, at);
    enabled = 1;
}

/* The compositor's commands: `R` and a generation starts a recording, `S` stops it. */
static void poll_control(void) {
    if (sock_fd < 0) return;
    for (;;) {
        uint8_t cmd[64];
        ssize_t n = recv(sock_fd, cmd, sizeof cmd, MSG_DONTWAIT | MSG_PEEK);
        if (n < 0 && errno == EINTR) continue;
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            give_up();
            return;
        }
        if (n <= 0) return;
        if (cmd[0] == 'S') {
            (void)recv(sock_fd, cmd, 1, MSG_DONTWAIT);
            enabled = 0;
        } else if (cmd[0] == 'R') {
            if (n < 5) return; /* the rest of it has not arrived */
            (void)recv(sock_fd, cmd, 5, MSG_DONTWAIT);
            begin(cdl_read32(cmd + 1));
        } else {
            give_up();
            return;
        }
    }
}

/* The compositor's draw socket: CABOOSE_DRAW_SOCKET, or (in a sandbox, where the launch
 * environment does not reach) the instance's directory found from WAYLAND_DISPLAY. */
static int connect_socket(void) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    const char *explicit_path = getenv("CABOOSE_DRAW_SOCKET");
    const char *runtime = getenv("XDG_RUNTIME_DIR"), *wayland = getenv("WAYLAND_DISPLAY");
    if (explicit_path && *explicit_path) {
        if (snprintf(path, sizeof path, "%s", explicit_path) >= (int)sizeof path) return -1;
    } else if (runtime && *runtime && wayland && *wayland && !strchr(wayland, '/')) {
        if (snprintf(path, sizeof path, "%s/caboose-display/%s/draw.sock", runtime, wayland) >= (int)sizeof path) return -1;
    } else {
        return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, strlen(path) + 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    int big = 4 << 20;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    return fd;
}

__attribute__((constructor)) static void init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&lock, &attr);
    const char *capture = getenv("CABOOSE_DRAW_CAPTURE");
    if (capture && *capture) {
        char path[4096];
        const char *pid = strstr(capture, "%p");
        if (pid) {
            snprintf(path, sizeof path, "%.*s%d%s", (int)(pid - capture), capture, (int)getpid(), pid + 2);
        } else {
            snprintf(path, sizeof path, "%s", capture);
        }
        capture_fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (capture_fd >= 0) begin(1);
        const char *pixels = getenv("CABOOSE_DRAW_PIXELS");
        capture_pixels = pixels && *pixels == '1';
    } else {
        sock_fd = connect_socket();
    }
}

__attribute__((destructor)) static void fini(void) {
    pthread_mutex_lock(&lock);
    if (capture_fd >= 0) flush_out();
    pthread_mutex_unlock(&lock);
}

/* An X11 application commits nothing the recorder sees: the compositor's commands are read
 * from drawing calls too, at most five times a second. */
static void maybe_poll_control(void) {
    static __thread struct timespec last;
    struct timespec now;
    if (sock_fd < 0 || clock_gettime(CLOCK_MONOTONIC_COARSE, &now) != 0) return;
    if (now.tv_sec == last.tv_sec && now.tv_nsec - last.tv_nsec < 200000000) return;
    if (now.tv_sec - last.tv_sec == 1 && now.tv_nsec + 1000000000 - last.tv_nsec < 200000000) return;
    last = now;
    pthread_mutex_lock(&lock);
    poll_control();
    pthread_mutex_unlock(&lock);
}

/* ------------------------------------------------------------------------------------------ */
/* Surfaces                                                                                    */

typedef struct surf {
    uint32_t id;
    uint32_t gen;      /* the recording that saw it created (0: none did, its content is unknown) */
    uint32_t declared; /* the recording it was declared to (0: not yet) */
    int clear;       /* created transparent, so its content is exactly its recorded ops */
    int pixels;      /* written directly or drawn without a record: its pixels are the truth */
    int window;      /* a wl_shm buffer */
    uint64_t shm_ino, shm_off;
    uint64_t image;  /* hash of its pixels as last sent, 0 when they may have changed */
    cairo_surface_t *surface; /* the surface this record is attached to (and dies with) */
    struct surf *next_window;
} surf_t;

static cairo_user_data_key_t surf_key;
static surf_t *windows;

static void surf_gone(void *data) {
    surf_t *s = (surf_t *)data;
    pthread_mutex_lock(&lock);
    for (surf_t **p = &windows; *p; p = &(*p)->next_window) {
        if (*p == s) {
            *p = s->next_window;
            break;
        }
    }
    if (enabled && s->declared == generation) {
        size_t at = cdl_begin(&out, CDL_FREE);
        cdl_u32(&out, s->id);
        cdl_end(&out, at);
        if (current_target == s->id) current_target = 0;
    }
    pthread_mutex_unlock(&lock);
    free(s);
}

static surf_t *surf_find(cairo_surface_t *surface) {
    return (surf_t *)real_cairo_surface_get_user_data(surface, &surf_key);
}

static surf_t *surf_get(cairo_surface_t *surface) {
    surf_t *s = surf_find(surface);
    if (s) return s;
    if (real_cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) return NULL;
    s = (surf_t *)calloc(1, sizeof *s);
    if (!s) return NULL;
    s->id = next_surface_id++;
    s->gen = enabled ? generation : 0;
    s->surface = surface;
    if (real_cairo_surface_set_user_data(surface, &surf_key, s, surf_gone) != CAIRO_STATUS_SUCCESS) {
        free(s);
        return NULL;
    }
    return s;
}

static void surface_size(cairo_surface_t *surface, int *w, int *h) {
    *w = *h = 0;
    switch (real_cairo_surface_get_type(surface)) {
    case CAIRO_SURFACE_TYPE_IMAGE:
        *w = real_cairo_image_surface_get_width(surface);
        *h = real_cairo_image_surface_get_height(surface);
        break;
    case CAIRO_SURFACE_TYPE_XLIB: {
        static int (*xw)(cairo_surface_t *), (*xh)(cairo_surface_t *);
        if (!xw) {
            xw = (int (*)(cairo_surface_t *))real_sym("cairo_xlib_surface_get_width", CAIRO_LIB);
            xh = (int (*)(cairo_surface_t *))real_sym("cairo_xlib_surface_get_height", CAIRO_LIB);
        }
        if (xw && xh) {
            *w = xw(surface);
            *h = xh(surface);
        }
        break;
    }
    case CAIRO_SURFACE_TYPE_RECORDING: {
        cairo_rectangle_t r;
        if (real_cairo_recording_surface_get_extents(surface, &r)) {
            *w = (int)r.width;
            *h = (int)r.height;
        }
        break;
    }
    default:
        break;
    }
}

static uint64_t put_image(cairo_surface_t *surface, surf_t *s);

/* Declares a surface to the stream the first time it is drawn into or drawn from. A surface
 * whose content predates this recording (a toolkit keeps its window buffers) is sent once as
 * its pixels, painted onto it, and is a recorded surface from then on. */
static void surf_declare(cairo_surface_t *surface, surf_t *s) {
    if (s->declared == generation) return;
    int w, h;
    surface_size(surface, &w, &h);
    uint64_t snapshot = 0;
    if (s->gen != generation && w > 0 && h > 0) {
        s->image = 0;
        snapshot = put_image(surface, NULL);
    }
    int known = s->gen == generation || snapshot;
    size_t at = cdl_begin(&out, CDL_SURFACE);
    cdl_u32(&out, s->id);
    cdl_u32(&out, (uint32_t)w);
    cdl_u32(&out, (uint32_t)h);
    cdl_u8(&out, !known ? CDL_SURFACE_UNKNOWN : s->window ? CDL_SURFACE_WINDOW
                 : (s->clear || snapshot) ? CDL_SURFACE_CLEAR : CDL_SURFACE_UNKNOWN);
    cdl_end(&out, at);
    s->declared = generation;
    if (!snapshot) return;
    static const float identity[6] = {1, 0, 0, 1, 0, 0};
    at = cdl_begin(&out, CDL_TARGET);
    cdl_u32(&out, s->id);
    cdl_end(&out, at);
    at = cdl_begin(&out, CDL_PAINT);
    cdl_u8(&out, CAIRO_OPERATOR_SOURCE);
    cdl_f32(&out, 1);
    for (int i = 0; i < 6; i++) cdl_f32(&out, identity[i]);
    cdl_u8(&out, CDL_SOURCE_IMAGE);
    cdl_u64(&out, snapshot);
    cdl_u8(&out, CAIRO_EXTEND_NONE);
    cdl_u8(&out, CAIRO_FILTER_NEAREST);
    for (int i = 0; i < 6; i++) cdl_f32(&out, identity[i]);
    cdl_end(&out, at);
    current_target = s->id;
    current_clip = 1;
    s->gen = generation;
    s->clear = 1;
    s->pixels = 0;
}

/* A number in `base` (10 or 16) at `at`, its end in `end` (== `at` when there is none). Not
 * strtoull: with _GNU_SOURCE glibc maps that to a C23 symbol newer than Flatpak runtimes. */
static unsigned long long parse_number(const char *at, char **end, int base) {
    unsigned long long v = 0;
    const char *p = at;
    for (;; p++) {
        int d;
        if (*p >= '0' && *p <= '9') d = *p - '0';
        else if (base == 16 && *p >= 'a' && *p <= 'f') d = *p - 'a' + 10;
        else if (base == 16 && *p >= 'A' && *p <= 'F') d = *p - 'A' + 10;
        else break;
        v = v * (unsigned)base + (unsigned)d;
    }
    *end = (char *)p;
    return v;
}

/* The memfd or shm file and offset behind `data`, from /proc/self/maps; 0 when private. */
static int shared_mapping(const void *data, uint64_t *ino, uint64_t *off) {
    FILE *maps = fopen("/proc/self/maps", "re");
    if (!maps) return 0;
    char line[512];
    int found = 0;
    uintptr_t p = (uintptr_t)data;
    while (fgets(line, sizeof line, maps)) {
        /* "start-end perms offset major:minor inode path", parsed by hand: sscanf binds to a
         * newer glibc than the Flatpak runtimes carry. */
        char *at = line, *next;
        uintptr_t start = (uintptr_t)parse_number(at, &next, 16);
        if (next == at || *next != '-') continue;
        at = next + 1;
        uintptr_t end = (uintptr_t)parse_number(at, &next, 16);
        if (next == at || *next != ' ') continue;
        const char *perms = next + 1;
        if (strlen(perms) < 5) continue;
        at = (char *)perms + 5; /* "rw-s " */
        unsigned long long file_off = parse_number(at, &next, 16);
        if (next == at) continue;
        at = strchr(next + 1, ' ');
        if (!at) continue;
        at++;
        unsigned long long inode = parse_number(at, &next, 10);
        if (next == at) continue;
        if (p < start || p >= end) continue;
        if (perms[3] == 's' && inode != 0) {
            *ino = inode;
            *off = file_off + (p - start);
            found = 1;
        }
        break;
    }
    fclose(maps);
    return found;
}

/* ------------------------------------------------------------------------------------------ */
/* Clips: a shadow clip stack per cairo_t (public API cannot read a clip that is not rectangles) */

typedef struct clip_item {
    int refs;
    cairo_matrix_t ctm;
    cairo_fill_rule_t rule;
    cairo_antialias_t aa;
    cairo_path_t *path;
} clip_item;

typedef struct {
    clip_item **items;
    int n;
} clip_list;

typedef struct {
    clip_list clip;
    clip_list *saved;
    int nsaved, capsaved;
} ctx_t;

static cairo_user_data_key_t ctx_key;

static void clip_unref(clip_item *c) {
    if (--c->refs == 0) {
        real_cairo_path_destroy(c->path);
        free(c);
    }
}

static void list_clear(clip_list *l) {
    for (int i = 0; i < l->n; i++) clip_unref(l->items[i]);
    free(l->items);
    l->items = NULL;
    l->n = 0;
}

static clip_list list_copy(const clip_list *l) {
    clip_list c = {NULL, 0};
    if (l->n) {
        c.items = (clip_item **)malloc(sizeof(clip_item *) * (size_t)l->n);
        if (!c.items) return c;
        for (int i = 0; i < l->n; i++) {
            c.items[i] = l->items[i];
            c.items[i]->refs++;
        }
        c.n = l->n;
    }
    return c;
}

static void ctx_gone(void *data) {
    ctx_t *c = (ctx_t *)data;
    pthread_mutex_lock(&lock);
    list_clear(&c->clip);
    for (int i = 0; i < c->nsaved; i++) list_clear(&c->saved[i]);
    free(c->saved);
    pthread_mutex_unlock(&lock);
    free(c);
}

static ctx_t *ctx_get(cairo_t *cr) {
    ctx_t *c = (ctx_t *)real_cairo_get_user_data(cr, &ctx_key);
    if (c) return c;
    c = (ctx_t *)calloc(1, sizeof *c);
    if (!c) return NULL;
    if (real_cairo_set_user_data(cr, &ctx_key, c, ctx_gone) != CAIRO_STATUS_SUCCESS) {
        free(c);
        return NULL;
    }
    return c;
}

static void ctx_save(cairo_t *cr) {
    ctx_t *c = ctx_get(cr);
    if (!c) return;
    if (c->nsaved == c->capsaved) {
        int cap = c->capsaved ? c->capsaved * 2 : 8;
        clip_list *saved = (clip_list *)realloc(c->saved, sizeof(clip_list) * (size_t)cap);
        if (!saved) return;
        c->saved = saved;
        c->capsaved = cap;
    }
    c->saved[c->nsaved++] = list_copy(&c->clip);
}

static void ctx_restore(cairo_t *cr) {
    ctx_t *c = ctx_get(cr);
    if (!c || c->nsaved == 0) return;
    list_clear(&c->clip);
    c->clip = c->saved[--c->nsaved];
}

static void ctx_clip(cairo_t *cr) {
    ctx_t *c = ctx_get(cr);
    if (!c) return;
    clip_item *item = (clip_item *)calloc(1, sizeof *item);
    if (!item) return;
    item->refs = 1;
    real_cairo_get_matrix(cr, &item->ctm);
    item->rule = real_cairo_get_fill_rule(cr);
    item->aa = real_cairo_get_antialias(cr);
    item->path = real_cairo_copy_path(cr);
    clip_item **items = (clip_item **)realloc(c->clip.items, sizeof(clip_item *) * (size_t)(c->clip.n + 1));
    if (!items) {
        clip_unref(item);
        return;
    }
    c->clip.items = items;
    c->clip.items[c->clip.n++] = item;
}

/* ------------------------------------------------------------------------------------------ */
/* Encoding                                                                                    */

/* `m` followed by `surface`'s device transform: user space to the surface's pixels. */
static void to_pixels(cairo_surface_t *surface, const cairo_matrix_t *m, cairo_matrix_t *r) {
    double sx = 1, sy = 1, ox = 0, oy = 0;
    real_cairo_surface_get_device_scale(surface, &sx, &sy);
    real_cairo_surface_get_device_offset(surface, &ox, &oy);
    r->xx = m->xx * sx;
    r->yx = m->yx * sy;
    r->xy = m->xy * sx;
    r->yy = m->yy * sy;
    r->x0 = m->x0 * sx + ox;
    r->y0 = m->y0 * sy + oy;
}

static void put_matrix(cdl_buf *b, const cairo_matrix_t *m) {
    cdl_f32(b, m->xx);
    cdl_f32(b, m->yx);
    cdl_f32(b, m->xy);
    cdl_f32(b, m->yy);
    cdl_f32(b, m->x0);
    cdl_f32(b, m->y0);
}

/* A cairo path, its points multiplied by `scale`. */
static void put_path(cdl_buf *b, const cairo_path_t *path, double scale) {
    uint32_t verbs = 0, points = 0;
    int ok = path && path->status == CAIRO_STATUS_SUCCESS;
    for (int i = 0; ok && i < path->num_data; i += path->data[i].header.length) {
        verbs++;
        points += (uint32_t)path->data[i].header.length - 1;
    }
    cdl_u32(b, verbs);
    cdl_u32(b, points);
    for (int i = 0; ok && i < path->num_data; i += path->data[i].header.length) {
        switch (path->data[i].header.type) {
        case CAIRO_PATH_MOVE_TO: cdl_u8(b, CDL_MOVE); break;
        case CAIRO_PATH_LINE_TO: cdl_u8(b, CDL_LINE); break;
        case CAIRO_PATH_CURVE_TO: cdl_u8(b, CDL_CUBIC); break;
        case CAIRO_PATH_CLOSE_PATH: cdl_u8(b, CDL_CLOSE); break;
        }
    }
    for (int i = 0; ok && i < path->num_data; i += path->data[i].header.length) {
        for (int k = 1; k < path->data[i].header.length; k++) {
            cdl_f32(b, path->data[i + k].point.x * scale);
            cdl_f32(b, path->data[i + k].point.y * scale);
        }
    }
}

/* Whether `path` under `m` is one axis-aligned rectangle; its pixel bounds in `r`. */
static int path_rect(const cairo_path_t *path, const cairo_matrix_t *m, double r[4]) {
    if (!path || path->status != CAIRO_STATUS_SUCCESS || m->xy != 0 || m->yx != 0) return 0;
    double xs[5], ys[5];
    int n = 0, closed = 0;
    for (int i = 0; i < path->num_data; i += path->data[i].header.length) {
        const cairo_path_data_t *d = &path->data[i];
        switch (d->header.type) {
        case CAIRO_PATH_MOVE_TO:
            if (closed) break; /* cairo moves back to the start after a close */
            if (n != 0) return 0;
            /* fall through */
        case CAIRO_PATH_LINE_TO:
            if (closed || n == 5) return 0;
            xs[n] = d[1].point.x;
            ys[n] = d[1].point.y;
            n++;
            break;
        case CAIRO_PATH_CLOSE_PATH:
            closed = 1;
            break;
        default:
            return 0;
        }
    }
    if (n == 5 && xs[4] == xs[0] && ys[4] == ys[0]) n = 4;
    if (n != 4) return 0;
    for (int k = 0; k < 4; k++) {
        int j = (k + 1) % 4;
        if (xs[k] != xs[j] && ys[k] != ys[j]) return 0;
    }
    double x0 = xs[0], x1 = xs[0], y0 = ys[0], y1 = ys[0];
    for (int k = 1; k < 4; k++) {
        if (xs[k] < x0) x0 = xs[k];
        if (xs[k] > x1) x1 = xs[k];
        if (ys[k] < y0) y0 = ys[k];
        if (ys[k] > y1) y1 = ys[k];
    }
    double ax = m->xx * x0 + m->x0, bx = m->xx * x1 + m->x0;
    double ay = m->yy * y0 + m->y0, by = m->yy * y1 + m->y0;
    r[0] = ax < bx ? ax : bx;
    r[1] = ay < by ? ay : by;
    r[2] = ax < bx ? bx - ax : ax - bx;
    r[3] = ay < by ? by - ay : ay - by;
    return 1;
}

/* Emits CLIP when the clip for `target` differs from the last one sent. */
static void put_clip(cairo_t *cr, cairo_surface_t *target) {
    ctx_t *c = ctx_get(cr);
    cdl_buf clip = {0};
    int n = c ? c->clip.n : 0;
    cdl_u32(&clip, (uint32_t)n);
    for (int i = 0; i < n; i++) {
        clip_item *item = c->clip.items[i];
        cairo_matrix_t m;
        to_pixels(target, &item->ctm, &m);
        double r[4];
        if (path_rect(item->path, &m, r)) {
            cdl_u8(&clip, CDL_CLIP_RECT);
            for (int k = 0; k < 4; k++) cdl_f32(&clip, r[k]);
        } else {
            cdl_u8(&clip, CDL_CLIP_PATH);
            put_matrix(&clip, &m);
            cdl_u8(&clip, (uint8_t)item->rule);
            cdl_u8(&clip, (uint8_t)item->aa);
            put_path(&clip, item->path, 1.0);
        }
    }
    uint64_t hash = clip.failed ? 0 : cdl_xxh64(clip.data, clip.len, 0) ^ 0x9e3779b97f4a7c15ULL;
    if (hash != current_clip) {
        size_t at = cdl_begin(&out, CDL_CLIP);
        cdl_bytes(&out, clip.data, clip.len);
        cdl_end(&out, at);
        current_clip = hash;
    }
    free(clip.data);
}

/* Premultiplied RGBA8 pixels of any surface, by converting through an ARGB32 image. */
static uint8_t *read_pixels(cairo_surface_t *surface, int *pw, int *ph) {
    int w, h;
    surface_size(surface, &w, &h);
    if (w <= 0 || h <= 0) return NULL;
    real_cairo_surface_flush(surface);
    cairo_surface_t *image = NULL;
    const uint8_t *src;
    int stride;
    cairo_format_t format = CAIRO_FORMAT_INVALID;
    if (real_cairo_surface_get_type(surface) == CAIRO_SURFACE_TYPE_IMAGE) {
        format = real_cairo_image_surface_get_format(surface);
    }
    if (format == CAIRO_FORMAT_ARGB32 || format == CAIRO_FORMAT_RGB24) {
        src = real_cairo_image_surface_get_data(surface);
        stride = real_cairo_image_surface_get_stride(surface);
    } else {
        image = real_cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
        cairo_t *cr = real_cairo_create(image);
        real_cairo_set_source_surface(cr, surface, 0, 0);
        real_cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
        real_cairo_paint(cr);
        real_cairo_destroy(cr);
        real_cairo_surface_flush(image);
        src = real_cairo_image_surface_get_data(image);
        stride = real_cairo_image_surface_get_stride(image);
        format = CAIRO_FORMAT_ARGB32;
    }
    uint8_t *rgba = src ? (uint8_t *)malloc((size_t)w * (size_t)h * 4) : NULL;
    if (rgba) {
        for (int y = 0; y < h; y++) {
            const uint32_t *row = (const uint32_t *)(src + (size_t)y * (size_t)stride);
            uint8_t *d = rgba + (size_t)y * (size_t)w * 4;
            for (int x = 0; x < w; x++) {
                uint32_t p = row[x];
                d[0] = (uint8_t)(p >> 16);
                d[1] = (uint8_t)(p >> 8);
                d[2] = (uint8_t)p;
                d[3] = format == CAIRO_FORMAT_RGB24 ? 0xFF : (uint8_t)(p >> 24);
                d += 4;
            }
        }
    }
    if (image) real_cairo_surface_destroy(image);
    *pw = w;
    *ph = h;
    return rgba;
}

/* The content hash of a surface's pixels, sending them first if the stream lacks them. */
static uint64_t put_image(cairo_surface_t *surface, surf_t *s) {
    if (s && s->image) return s->image;
    int w, h;
    uint8_t *rgba = read_pixels(surface, &w, &h);
    if (!rgba) return 0;
    size_t len = (size_t)w * (size_t)h * 4;
    uint64_t hash = cdl_xxh64(rgba, len, 0);
    if (hash == 0) hash = 1;
    if (keyset_add(&sent_images, hash)) {
        size_t at = cdl_begin(&out, CDL_IMAGE);
        cdl_u64(&out, hash);
        cdl_u32(&out, (uint32_t)w);
        cdl_u32(&out, (uint32_t)h);
        cdl_u8(&out, 0);
        cdl_bytes(&out, rgba, len);
        cdl_end(&out, at);
    }
    free(rgba);
    if (s) s->image = hash;
    return hash;
}

static void put_stops(cdl_buf *b, cairo_pattern_t *p) {
    int n = 0;
    real_cairo_pattern_get_color_stop_count(p, &n);
    cdl_u32(b, (uint32_t)n);
    for (int i = 0; i < n; i++) {
        double o, r, g, bl, a;
        real_cairo_pattern_get_color_stop_rgba(p, i, &o, &r, &g, &bl, &a);
        cdl_f32(b, o);
        cdl_f32(b, r);
        cdl_f32(b, g);
        cdl_f32(b, bl);
        cdl_f32(b, a);
    }
}

/* Encodes a source pattern into `b`; offscreen declarations and images it needs go to the
 * stream first. Returns 0 when the pattern cannot be expressed. */
static int put_source(cdl_buf *b, cairo_pattern_t *p) {
    cairo_matrix_t m;
    switch (real_cairo_pattern_get_type(p)) {
    case CAIRO_PATTERN_TYPE_SOLID: {
        double r, g, bl, a;
        real_cairo_pattern_get_rgba(p, &r, &g, &bl, &a);
        cdl_u8(b, CDL_SOURCE_SOLID);
        cdl_f32(b, r);
        cdl_f32(b, g);
        cdl_f32(b, bl);
        cdl_f32(b, a);
        return 1;
    }
    case CAIRO_PATTERN_TYPE_LINEAR: {
        double x0, y0, x1, y1;
        real_cairo_pattern_get_linear_points(p, &x0, &y0, &x1, &y1);
        real_cairo_pattern_get_matrix(p, &m);
        cdl_u8(b, CDL_SOURCE_LINEAR);
        cdl_f32(b, x0);
        cdl_f32(b, y0);
        cdl_f32(b, x1);
        cdl_f32(b, y1);
        cdl_u8(b, (uint8_t)real_cairo_pattern_get_extend(p));
        put_matrix(b, &m);
        put_stops(b, p);
        return 1;
    }
    case CAIRO_PATTERN_TYPE_RADIAL: {
        double cx0, cy0, r0, cx1, cy1, r1;
        real_cairo_pattern_get_radial_circles(p, &cx0, &cy0, &r0, &cx1, &cy1, &r1);
        real_cairo_pattern_get_matrix(p, &m);
        cdl_u8(b, CDL_SOURCE_RADIAL);
        cdl_f32(b, cx0);
        cdl_f32(b, cy0);
        cdl_f32(b, r0);
        cdl_f32(b, cx1);
        cdl_f32(b, cy1);
        cdl_f32(b, r1);
        cdl_u8(b, (uint8_t)real_cairo_pattern_get_extend(p));
        put_matrix(b, &m);
        put_stops(b, p);
        return 1;
    }
    case CAIRO_PATTERN_TYPE_SURFACE: {
        cairo_surface_t *surface = NULL;
        real_cairo_pattern_get_surface(p, &surface);
        real_cairo_pattern_get_matrix(p, &m);
        cairo_matrix_t pm;
        to_pixels(surface, &m, &pm);
        surf_t *s = surf_get(surface);
        if (s && s->gen != generation) surf_declare(surface, s); /* made known by its pixels */
        if (s && s->clear && !s->pixels && s->gen == generation) {
            surf_declare(surface, s);
            cdl_u8(b, CDL_SOURCE_SURFACE);
            cdl_u32(b, s->id);
        } else {
            uint64_t hash = put_image(surface, s);
            if (!hash) return 0;
            cdl_u8(b, CDL_SOURCE_IMAGE);
            cdl_u64(b, hash);
        }
        cdl_u8(b, (uint8_t)real_cairo_pattern_get_extend(p));
        cdl_u8(b, (uint8_t)real_cairo_pattern_get_filter(p));
        put_matrix(b, &pm);
        return 1;
    }
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Fonts and glyphs                                                                            */

typedef struct {
    uint64_t id;
    cairo_scaled_font_t *unit; /* the same face at 1024 units per em, unhinted, for outlines */
    int color;
} font_t;

static cairo_user_data_key_t font_key;

static void font_gone(void *data) {
    font_t *f = (font_t *)data;
    if (f->unit) real_cairo_scaled_font_destroy(f->unit);
    free(f);
}

#define UNIT_EM 1024.0

static font_t *font_get(cairo_scaled_font_t *sf) {
    font_t *f = (font_t *)real_cairo_scaled_font_get_user_data(sf, &font_key);
    if (f) return f;
    if (real_cairo_scaled_font_status(sf) != CAIRO_STATUS_SUCCESS) return NULL;
    f = (font_t *)calloc(1, sizeof *f);
    if (!f) return NULL;
    cairo_font_face_t *face = real_cairo_scaled_font_get_font_face(sf);
    cairo_font_options_t *options = real_cairo_font_options_create();
    real_cairo_scaled_font_get_font_options(sf, options);
    cdl_buf id = {0};
    const char *variations = real_cairo_font_options_get_variations ? real_cairo_font_options_get_variations(options) : NULL;
    if (variations) cdl_bytes(&id, variations, strlen(variations));
    if (real_cairo_font_face_get_type(face) == CAIRO_FONT_TYPE_FT && real_cairo_ft_scaled_font_lock_face) {
        FT_Face ft = real_cairo_ft_scaled_font_lock_face(sf);
        if (ft) {
            FT_Byte head[54];
            FT_ULong len = sizeof head;
            if (real_FT_Load_Sfnt_Table && real_FT_Load_Sfnt_Table(ft, TTAG_head, 0, head, &len) == 0) {
                cdl_bytes(&id, head, len);
            } else if (ft->stream && ft->stream->base) {
                cdl_bytes(&id, ft->stream->base, ft->stream->size);
            }
            cdl_u64(&id, (uint64_t)ft->face_index);
            cdl_u64(&id, (uint64_t)ft->num_glyphs);
            cdl_u32(&id, ft->units_per_EM);
            if (ft->family_name) cdl_bytes(&id, ft->family_name, strlen(ft->family_name));
            if (ft->style_name) cdl_bytes(&id, ft->style_name, strlen(ft->style_name));
            FT_Fixed coords[16] = {0};
            if (real_FT_Get_Var_Design_Coordinates && real_FT_Get_Var_Design_Coordinates(ft, 16, coords) == 0) {
                cdl_bytes(&id, coords, sizeof coords);
            }
            f->color = (ft->face_flags & FT_FACE_FLAG_COLOR) != 0;
            real_cairo_ft_scaled_font_unlock_face(sf);
        }
        if (real_cairo_ft_font_face_get_synthesize) cdl_u32(&id, real_cairo_ft_font_face_get_synthesize(face));
    } else {
        /* Not a FreeType face (a user font): only this process can name it. */
        cdl_u64(&id, (uint64_t)(uintptr_t)face);
        cdl_u32(&id, (uint32_t)getpid());
    }
    f->id = id.failed ? 0 : cdl_xxh64(id.data, id.len, 0);
    free(id.data);
    cairo_matrix_t em, identity;
    em.xx = UNIT_EM, em.yx = 0, em.xy = 0, em.yy = UNIT_EM, em.x0 = 0, em.y0 = 0;
    identity.xx = 1, identity.yx = 0, identity.xy = 0, identity.yy = 1, identity.x0 = 0, identity.y0 = 0;
    real_cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_NONE);
    real_cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_OFF);
    f->unit = real_cairo_scaled_font_create(face, &em, &identity, options);
    real_cairo_font_options_destroy(options);
    if (real_cairo_scaled_font_set_user_data(sf, &font_key, f, font_gone) != CAIRO_STATUS_SUCCESS) {
        font_gone(f);
        return NULL;
    }
    return f;
}

/* Sends a glyph's outline (em units, y down) unless the stream already carries it. */
static void put_glyph(font_t *f, uint32_t glyph) {
    uint64_t key = cdl_xxh64(&f->id, sizeof f->id, glyph);
    if (!keyset_add(&sent_glyphs, key)) return;
    static cairo_surface_t *scratch;
    if (!scratch) scratch = real_cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    cairo_t *cr = real_cairo_create(scratch);
    real_cairo_set_scaled_font(cr, f->unit);
    cairo_glyph_t g = {glyph, 0, 0};
    real_cairo_glyph_path(cr, &g, 1);
    cairo_path_t *path = real_cairo_copy_path(cr);
    size_t at = cdl_begin(&out, CDL_GLYPH);
    cdl_u64(&out, f->id);
    cdl_u32(&out, glyph);
    put_path(&out, path, 1.0 / UNIT_EM);
    cdl_end(&out, at);
    real_cairo_path_destroy(path);
    real_cairo_destroy(cr);
}

/* ------------------------------------------------------------------------------------------ */
/* Recording a drawing op                                                                      */

enum kind { K_FILL, K_STROKE, K_PAINT, K_MASK, K_GLYPHS };

static void put_unsupported(uint32_t reason, cairo_t *cr, cairo_surface_t *target) {
    double x0, y0, x1, y1;
    real_cairo_clip_extents(cr, &x0, &y0, &x1, &y1);
    cairo_matrix_t ctm, m;
    real_cairo_get_matrix(cr, &ctm);
    to_pixels(target, &ctm, &m);
    double xs[4] = {x0, x1, x0, x1}, ys[4] = {y0, y0, y1, y1};
    double ax = 1e30, ay = 1e30, bx = -1e30, by = -1e30;
    for (int i = 0; i < 4; i++) {
        double x = m.xx * xs[i] + m.xy * ys[i] + m.x0, y = m.yx * xs[i] + m.yy * ys[i] + m.y0;
        if (x < ax) ax = x;
        if (y < ay) ay = y;
        if (x > bx) bx = x;
        if (y > by) by = y;
    }
    size_t at = cdl_begin(&out, CDL_UNSUPPORTED);
    cdl_u32(&out, reason);
    cdl_f32(&out, ax);
    cdl_f32(&out, ay);
    cdl_f32(&out, bx - ax);
    cdl_f32(&out, by - ay);
    cdl_end(&out, at);
}

static void record(cairo_t *cr, enum kind kind, double alpha, cairo_pattern_t *mask, const cairo_glyph_t *glyphs,
                   int nglyphs) {
    pthread_mutex_lock(&lock);
    if (!enabled) goto done;
    cairo_surface_t *target = real_cairo_get_group_target(cr);
    surf_t *t = surf_get(target);
    if (!t) goto done;
    t->image = 0;

    /* Sources first: they may put images into the stream ahead of the op. */
    cdl_buf src = {0}, msk = {0};
    int ok = put_source(&src, real_cairo_get_source(cr));
    if (ok && mask) ok = put_source(&msk, mask);
    font_t *font = NULL;
    if (ok && kind == K_GLYPHS) {
        font = font_get(real_cairo_get_scaled_font(cr));
        if (!font || font->color) ok = 0;
    }
    surf_declare(target, t);
    if (current_target != t->id) {
        size_t at = cdl_begin(&out, CDL_TARGET);
        cdl_u32(&out, t->id);
        cdl_end(&out, at);
        current_target = t->id;
        current_clip = 1;
    }
    put_clip(cr, target);
    if (!ok) {
        put_unsupported(kind == K_GLYPHS && font ? CDL_UNSUPPORTED_GLYPHS : CDL_UNSUPPORTED_SOURCE, cr, target);
        t->pixels = 1;
        goto free_sources;
    }
    if (kind == K_GLYPHS) {
        for (int i = 0; i < nglyphs; i++) put_glyph(font, (uint32_t)glyphs[i].index);
    }
    cairo_matrix_t ctm, m;
    real_cairo_get_matrix(cr, &ctm);
    to_pixels(target, &ctm, &m);
    uint8_t op = (uint8_t)real_cairo_get_operator(cr);
    size_t at;
    switch (kind) {
    case K_FILL: {
        cairo_path_t *path = real_cairo_copy_path(cr);
        at = cdl_begin(&out, CDL_FILL);
        cdl_u8(&out, op);
        cdl_u8(&out, (uint8_t)real_cairo_get_fill_rule(cr));
        cdl_u8(&out, (uint8_t)real_cairo_get_antialias(cr));
        put_matrix(&out, &m);
        cdl_bytes(&out, src.data, src.len);
        put_path(&out, path, 1.0);
        cdl_end(&out, at);
        real_cairo_path_destroy(path);
        break;
    }
    case K_STROKE: {
        cairo_path_t *path = real_cairo_copy_path(cr);
        int ndash = real_cairo_get_dash_count(cr);
        double dashes[64], offset = 0;
        if (ndash > 64) ndash = 0;
        if (ndash) real_cairo_get_dash(cr, dashes, &offset);
        at = cdl_begin(&out, CDL_STROKE);
        cdl_u8(&out, op);
        cdl_u8(&out, (uint8_t)real_cairo_get_antialias(cr));
        put_matrix(&out, &m);
        cdl_f32(&out, real_cairo_get_line_width(cr));
        cdl_u8(&out, (uint8_t)real_cairo_get_line_cap(cr));
        cdl_u8(&out, (uint8_t)real_cairo_get_line_join(cr));
        cdl_f32(&out, real_cairo_get_miter_limit(cr));
        cdl_u32(&out, (uint32_t)ndash);
        cdl_f32(&out, offset);
        for (int i = 0; i < ndash; i++) cdl_f32(&out, dashes[i]);
        cdl_bytes(&out, src.data, src.len);
        put_path(&out, path, 1.0);
        cdl_end(&out, at);
        real_cairo_path_destroy(path);
        break;
    }
    case K_PAINT:
        at = cdl_begin(&out, CDL_PAINT);
        cdl_u8(&out, op);
        cdl_f32(&out, alpha);
        put_matrix(&out, &m);
        cdl_bytes(&out, src.data, src.len);
        cdl_end(&out, at);
        break;
    case K_MASK:
        at = cdl_begin(&out, CDL_MASK);
        cdl_u8(&out, op);
        put_matrix(&out, &m);
        cdl_bytes(&out, src.data, src.len);
        cdl_bytes(&out, msk.data, msk.len);
        cdl_end(&out, at);
        break;
    case K_GLYPHS: {
        cairo_matrix_t fm;
        real_cairo_get_font_matrix(cr, &fm);
        at = cdl_begin(&out, CDL_GLYPHS);
        cdl_u8(&out, op);
        put_matrix(&out, &m);
        put_matrix(&out, &fm);
        cdl_u64(&out, font->id);
        cdl_bytes(&out, src.data, src.len);
        cdl_u32(&out, (uint32_t)nglyphs);
        for (int i = 0; i < nglyphs; i++) {
            cdl_u32(&out, (uint32_t)glyphs[i].index);
            cdl_f32(&out, glyphs[i].x);
            cdl_f32(&out, glyphs[i].y);
        }
        cdl_end(&out, at);
        break;
    }
    }
free_sources:
    free(src.data);
    free(msk.data);
    if (out.len > (8u << 20)) flush_out();
done:
    pthread_mutex_unlock(&lock);
}

/* A hook records only at the outermost level, while recording is on. */
#define ENTER()                       \
    resolve_cairo();                  \
    if (!enabled && !depth) maybe_poll_control(); \
    int recording = enabled && !depth; \
    depth++
#define LEAVE() depth--

/* ------------------------------------------------------------------------------------------ */
/* cairo hooks                                                                                 */

EXPORT void cairo_fill(cairo_t *cr) {
    ENTER();
    if (recording) record(cr, K_FILL, 1, NULL, NULL, 0);
    if (real_cairo_fill) real_cairo_fill(cr);
    LEAVE();
}

EXPORT void cairo_fill_preserve(cairo_t *cr) {
    ENTER();
    if (recording) record(cr, K_FILL, 1, NULL, NULL, 0);
    if (real_cairo_fill_preserve) real_cairo_fill_preserve(cr);
    LEAVE();
}

EXPORT void cairo_stroke(cairo_t *cr) {
    ENTER();
    if (recording) record(cr, K_STROKE, 1, NULL, NULL, 0);
    if (real_cairo_stroke) real_cairo_stroke(cr);
    LEAVE();
}

EXPORT void cairo_stroke_preserve(cairo_t *cr) {
    ENTER();
    if (recording) record(cr, K_STROKE, 1, NULL, NULL, 0);
    if (real_cairo_stroke_preserve) real_cairo_stroke_preserve(cr);
    LEAVE();
}

EXPORT void cairo_paint(cairo_t *cr) {
    ENTER();
    if (recording) record(cr, K_PAINT, 1, NULL, NULL, 0);
    if (real_cairo_paint) real_cairo_paint(cr);
    LEAVE();
}

EXPORT void cairo_paint_with_alpha(cairo_t *cr, double alpha) {
    ENTER();
    if (recording) record(cr, K_PAINT, alpha, NULL, NULL, 0);
    if (real_cairo_paint_with_alpha) real_cairo_paint_with_alpha(cr, alpha);
    LEAVE();
}

EXPORT void cairo_mask(cairo_t *cr, cairo_pattern_t *pattern) {
    ENTER();
    if (recording && pattern) record(cr, K_MASK, 1, pattern, NULL, 0);
    if (real_cairo_mask) real_cairo_mask(cr, pattern);
    LEAVE();
}

/* cairo_pattern_create_for_surface and friends are not hooked, so the mask pattern for
 * cairo_mask_surface is made the way cairo makes it, through the real functions. */
EXPORT void cairo_mask_surface(cairo_t *cr, cairo_surface_t *surface, double x, double y) {
    ENTER();
    if (recording && surface) {
        static cairo_pattern_t *(*create)(cairo_surface_t *);
        static void (*set_matrix)(cairo_pattern_t *, const cairo_matrix_t *);
        static void (*destroy)(cairo_pattern_t *);
        if (!create) {
            create = (cairo_pattern_t * (*)(cairo_surface_t *)) real_sym("cairo_pattern_create_for_surface", CAIRO_LIB);
            set_matrix = (void (*)(cairo_pattern_t *, const cairo_matrix_t *))real_sym("cairo_pattern_set_matrix", CAIRO_LIB);
            destroy = (void (*)(cairo_pattern_t *))real_sym("cairo_pattern_destroy", CAIRO_LIB);
        }
        if (create && set_matrix && destroy) {
            cairo_pattern_t *p = create(surface);
            cairo_matrix_t m = {1, 0, 0, 1, -x, -y};
            set_matrix(p, &m);
            record(cr, K_MASK, 1, p, NULL, 0);
            destroy(p);
        }
    }
    if (real_cairo_mask_surface) real_cairo_mask_surface(cr, surface, x, y);
    LEAVE();
}

EXPORT void cairo_show_glyphs(cairo_t *cr, const cairo_glyph_t *glyphs, int num_glyphs) {
    ENTER();
    if (recording && glyphs && num_glyphs > 0) record(cr, K_GLYPHS, 1, NULL, glyphs, num_glyphs);
    if (real_cairo_show_glyphs) real_cairo_show_glyphs(cr, glyphs, num_glyphs);
    LEAVE();
}

EXPORT void cairo_show_text_glyphs(cairo_t *cr, const char *utf8, int utf8_len, const cairo_glyph_t *glyphs,
                                   int num_glyphs, const cairo_text_cluster_t *clusters, int num_clusters,
                                   cairo_text_cluster_flags_t cluster_flags) {
    ENTER();
    if (recording && glyphs && num_glyphs > 0) record(cr, K_GLYPHS, 1, NULL, glyphs, num_glyphs);
    if (real_cairo_show_text_glyphs)
        real_cairo_show_text_glyphs(cr, utf8, utf8_len, glyphs, num_glyphs, clusters, num_clusters, cluster_flags);
    LEAVE();
}

EXPORT void cairo_show_text(cairo_t *cr, const char *utf8) {
    ENTER();
    if (recording && utf8 && *utf8) {
        double x = 0, y = 0;
        if (real_cairo_has_current_point(cr)) real_cairo_get_current_point(cr, &x, &y);
        cairo_glyph_t *glyphs = NULL;
        int n = 0;
        if (real_cairo_scaled_font_text_to_glyphs(real_cairo_get_scaled_font(cr), x, y, utf8, -1, &glyphs, &n, NULL,
                                                  NULL, NULL) == CAIRO_STATUS_SUCCESS &&
            n > 0) {
            record(cr, K_GLYPHS, 1, NULL, glyphs, n);
        }
        real_cairo_glyph_free(glyphs);
    }
    if (real_cairo_show_text) real_cairo_show_text(cr, utf8);
    LEAVE();
}

EXPORT void cairo_clip(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_clip(cr);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_clip) real_cairo_clip(cr);
    LEAVE();
}

EXPORT void cairo_clip_preserve(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_clip(cr);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_clip_preserve) real_cairo_clip_preserve(cr);
    LEAVE();
}

EXPORT void cairo_reset_clip(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_t *c = ctx_get(cr);
        if (c) list_clear(&c->clip);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_reset_clip) real_cairo_reset_clip(cr);
    LEAVE();
}

EXPORT void cairo_save(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_save(cr);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_save) real_cairo_save(cr);
    LEAVE();
}

EXPORT void cairo_restore(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_restore(cr);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_restore) real_cairo_restore(cr);
    LEAVE();
}

static void group_pushed(cairo_t *cr) {
    pthread_mutex_lock(&lock);
    ctx_save(cr);
    surf_t *s = surf_get(real_cairo_get_group_target(cr));
    if (s && s->declared != generation) {
        s->clear = 1;
        s->gen = generation;
    }
    pthread_mutex_unlock(&lock);
}

EXPORT void cairo_push_group(cairo_t *cr) {
    ENTER();
    if (real_cairo_push_group) real_cairo_push_group(cr);
    if (recording) group_pushed(cr);
    LEAVE();
}

EXPORT void cairo_push_group_with_content(cairo_t *cr, cairo_content_t content) {
    ENTER();
    if (real_cairo_push_group_with_content) real_cairo_push_group_with_content(cr, content);
    if (recording) group_pushed(cr);
    LEAVE();
}

EXPORT cairo_pattern_t *cairo_pop_group(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_restore(cr);
        pthread_mutex_unlock(&lock);
    }
    cairo_pattern_t *p = real_cairo_pop_group ? real_cairo_pop_group(cr) : NULL;
    LEAVE();
    return p;
}

EXPORT void cairo_pop_group_to_source(cairo_t *cr) {
    ENTER();
    if (recording) {
        pthread_mutex_lock(&lock);
        ctx_restore(cr);
        pthread_mutex_unlock(&lock);
    }
    if (real_cairo_pop_group_to_source) real_cairo_pop_group_to_source(cr);
    LEAVE();
}

static void created_clear(cairo_surface_t *surface) {
    pthread_mutex_lock(&lock);
    surf_t *s = surf_get(surface);
    if (s) s->clear = 1;
    pthread_mutex_unlock(&lock);
}

EXPORT cairo_surface_t *cairo_image_surface_create(cairo_format_t format, int width, int height) {
    ENTER();
    cairo_surface_t *s = real_cairo_image_surface_create ? real_cairo_image_surface_create(format, width, height) : NULL;
    if (recording && s) created_clear(s);
    LEAVE();
    return s;
}

EXPORT cairo_surface_t *cairo_image_surface_create_for_data(unsigned char *data, cairo_format_t format, int width,
                                                            int height, int stride) {
    ENTER();
    cairo_surface_t *s = real_cairo_image_surface_create_for_data
                             ? real_cairo_image_surface_create_for_data(data, format, width, height, stride)
                             : NULL;
    /* Window buffers are registered while the recorder waits too: a toolkit keeps its buffers,
     * and a recording that starts later must still know which commit shows which. */
    if ((recording || (sock_fd >= 0 && !depth)) && s) {
        uint64_t ino = 0, off = 0;
        int shared = shared_mapping(data, &ino, &off);
        pthread_mutex_lock(&lock);
        surf_t *r = surf_get(s);
        if (r) {
            /* Existing memory: what is in it is pixels, unless it is a window's buffer. A
             * toolkit allocates those from fresh shared memory, which starts zeroed, so their
             * content is exactly what is drawn into them, as for a surface created clear. */
            r->pixels = !shared;
            if (shared) {
                r->clear = 1;
                r->window = 1;
                r->shm_ino = ino;
                r->shm_off = off;
                r->next_window = windows;
                windows = r;
            }
        }
        pthread_mutex_unlock(&lock);
    }
    LEAVE();
    return s;
}

EXPORT cairo_surface_t *cairo_surface_create_similar(cairo_surface_t *other, cairo_content_t content, int width,
                                                     int height) {
    ENTER();
    cairo_surface_t *s =
        real_cairo_surface_create_similar ? real_cairo_surface_create_similar(other, content, width, height) : NULL;
    if (recording && s) created_clear(s);
    LEAVE();
    return s;
}

EXPORT cairo_surface_t *cairo_surface_create_similar_image(cairo_surface_t *other, cairo_format_t format, int width,
                                                           int height) {
    ENTER();
    cairo_surface_t *s = real_cairo_surface_create_similar_image
                             ? real_cairo_surface_create_similar_image(other, format, width, height)
                             : NULL;
    if (recording && s) created_clear(s);
    LEAVE();
    return s;
}

static void written_directly(cairo_surface_t *surface) {
    pthread_mutex_lock(&lock);
    surf_t *s = surf_get(surface);
    if (s) {
        s->pixels = 1;
        s->image = 0;
    }
    pthread_mutex_unlock(&lock);
}

EXPORT unsigned char *cairo_image_surface_get_data(cairo_surface_t *surface) {
    ENTER();
    if (recording && surface) written_directly(surface);
    unsigned char *data = real_cairo_image_surface_get_data ? real_cairo_image_surface_get_data(surface) : NULL;
    LEAVE();
    return data;
}

EXPORT void cairo_surface_mark_dirty(cairo_surface_t *surface) {
    ENTER();
    if (recording && surface) written_directly(surface);
    if (real_cairo_surface_mark_dirty) real_cairo_surface_mark_dirty(surface);
    LEAVE();
}

EXPORT void cairo_surface_mark_dirty_rectangle(cairo_surface_t *surface, int x, int y, int w, int h) {
    ENTER();
    if (recording && surface) written_directly(surface);
    if (real_cairo_surface_mark_dirty_rectangle) real_cairo_surface_mark_dirty_rectangle(surface, x, y, w, h);
    LEAVE();
}

/* ------------------------------------------------------------------------------------------ */
/* Wayland: wl_shm buffers and wl_surface commits                                              */

struct wl_proxy;

/* A wl_proxy starts with its wl_object, whose first member is the interface: the layout every
 * libwayland since 1.0 has had. Only the interface's request signatures are read from it. */
static const struct wl_interface *proxy_interface(struct wl_proxy *proxy) {
    return proxy ? *(const struct wl_interface *const *)proxy : NULL;
}

typedef struct {
    struct wl_proxy *proxy;
    uint64_t ino, off;      /* pools: inode; buffers: inode and offset */
    struct wl_proxy *buffer; /* surfaces: the buffer attached for the next commit */
} wl_entry;

static wl_entry wl_table[512];

static wl_entry *wl_find(struct wl_proxy *proxy, int create) {
    wl_entry *free_slot = NULL;
    for (size_t i = 0; i < sizeof wl_table / sizeof wl_table[0]; i++) {
        if (wl_table[i].proxy == proxy) return &wl_table[i];
        if (!wl_table[i].proxy && !free_slot) free_slot = &wl_table[i];
    }
    if (!create) return NULL;
    if (!free_slot) free_slot = &wl_table[(uintptr_t)proxy / 64 % (sizeof wl_table / sizeof wl_table[0])];
    memset(free_slot, 0, sizeof *free_slot);
    free_slot->proxy = proxy;
    return free_slot;
}

static uint32_t (*real_wl_proxy_get_id)(struct wl_proxy *);
static struct wl_proxy *(*real_wl_proxy_marshal_array_flags)(struct wl_proxy *, uint32_t, const struct wl_interface *,
                                                              uint32_t, uint32_t, union wl_argument *);

static void present(struct wl_proxy *surface, struct wl_proxy *buffer) {
    wl_entry *b = wl_find(buffer, 0);
    if (!b) return;
    for (surf_t *s = windows; s; s = s->next_window) {
        if (s->shm_ino != b->ino || s->shm_off != b->off) continue;
        surf_declare(s->surface, s);
        /* Complete: created in this recording and drawn only by recorded ops (no op went
         * unrecorded and no pixels were written directly), so the stream holds all of it. */
        int complete = s->gen == generation && s->declared == generation && !s->pixels;
        size_t at = cdl_begin(&out, CDL_PRESENT);
        cdl_u32(&out, s->id);
        cdl_u32(&out, real_wl_proxy_get_id ? real_wl_proxy_get_id(surface) : 0);
        cdl_u32(&out, real_wl_proxy_get_id ? real_wl_proxy_get_id(buffer) : 0);
        cdl_u8(&out, (uint8_t)complete);
        cdl_end(&out, at);
        if (capture_pixels) {
            int w, h;
            uint8_t *rgba = read_pixels(s->surface, &w, &h);
            if (rgba) {
                at = cdl_begin(&out, CDL_PIXELS);
                cdl_u32(&out, s->id);
                cdl_u32(&out, (uint32_t)w);
                cdl_u32(&out, (uint32_t)h);
                cdl_bytes(&out, rgba, (size_t)w * (size_t)h * 4);
                cdl_end(&out, at);
                free(rgba);
            }
        }
        return;
    }
}

static uint64_t pending_pool_ino;

/* Called for every request before it is sent, and again with the new proxy after. */
static void observe(struct wl_proxy *proxy, uint32_t opcode, union wl_argument *args, struct wl_proxy *created) {
    const struct wl_interface *iface = proxy_interface(proxy);
    if (!iface || !iface->name) return;
    if (!strcmp(iface->name, "wl_shm") && opcode == 0) {
        if (!created) {
            /* The fd is the application's until the request is sent; read it first. */
            struct stat st;
            pending_pool_ino = fstat(args[1].h, &st) == 0 ? (uint64_t)st.st_ino : 0;
        } else if (pending_pool_ino) {
            wl_find(created, 1)->ino = pending_pool_ino;
        }
    } else if (!strcmp(iface->name, "wl_shm_pool") && opcode == 0 && created) {
        wl_entry *pool = wl_find(proxy, 0);
        if (pool) {
            wl_entry *e = wl_find(created, 1);
            e->ino = pool->ino;
            e->off = (uint64_t)(uint32_t)args[1].i;
        }
    } else if (!strcmp(iface->name, "wl_surface") && !created) {
        if (opcode == 1) {
            wl_entry *e = wl_find(proxy, 1);
            e->buffer = (struct wl_proxy *)args[0].o;
        } else if (opcode == 6) {
            wl_entry *e = wl_find(proxy, 0);
            if (enabled && e && e->buffer) present(proxy, e->buffer);
            if (e) e->buffer = NULL;
            /* The frame's ops leave before the commit that shows them; a new recording starts
             * on the frame after it. */
            flush_out();
            poll_control();
        }
    }
}

static int wl_ready;

static void resolve_wl(void) {
    if (wl_ready) return;
    real_wl_proxy_get_id = (uint32_t(*)(struct wl_proxy *))real_sym("wl_proxy_get_id", WL_LIB);
    real_wl_proxy_marshal_array_flags = (struct wl_proxy * (*)(struct wl_proxy *, uint32_t, const struct wl_interface *,
                                                                uint32_t, uint32_t, union wl_argument *))
        real_sym("wl_proxy_marshal_array_flags", WL_LIB);
    wl_ready = 1;
}

static struct wl_proxy *marshal(struct wl_proxy *proxy, uint32_t opcode, const struct wl_interface *interface,
                                uint32_t version, uint32_t flags, union wl_argument *args) {
    resolve_wl();
    if (!real_wl_proxy_marshal_array_flags) return NULL;
    if ((!enabled && sock_fd < 0) || depth) return real_wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    depth++;
    pthread_mutex_lock(&lock);
    observe(proxy, opcode, args, NULL);
    pthread_mutex_unlock(&lock);
    struct wl_proxy *created = real_wl_proxy_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    if (created) {
        pthread_mutex_lock(&lock);
        observe(proxy, opcode, args, created);
        pthread_mutex_unlock(&lock);
    }
    depth--;
    return created;
}

EXPORT struct wl_proxy *wl_proxy_marshal_array_flags(struct wl_proxy *proxy, uint32_t opcode,
                                                     const struct wl_interface *interface, uint32_t version,
                                                     uint32_t flags, union wl_argument *args) {
    return marshal(proxy, opcode, interface, version, flags, args);
}

#define WL_MAX_ARGS 20

/* Reads a request's arguments from `ap` by its signature, as libwayland does. */
static int args_from_va(struct wl_proxy *proxy, uint32_t opcode, va_list ap, union wl_argument *args) {
    const struct wl_interface *iface = proxy_interface(proxy);
    if (!iface || opcode >= (uint32_t)iface->method_count) return 0;
    const char *sig = iface->methods[opcode].signature;
    int n = 0;
    for (; *sig && n < WL_MAX_ARGS; sig++) {
        switch (*sig) {
        case 'i': args[n++].i = va_arg(ap, int32_t); break;
        case 'u': args[n++].u = va_arg(ap, uint32_t); break;
        case 'f': args[n++].f = va_arg(ap, wl_fixed_t); break;
        case 's': args[n++].s = va_arg(ap, const char *); break;
        case 'o': args[n++].o = va_arg(ap, struct wl_object *); break;
        case 'n': args[n++].o = va_arg(ap, struct wl_object *); break;
        case 'a': args[n++].a = va_arg(ap, struct wl_array *); break;
        case 'h': args[n++].h = va_arg(ap, int32_t); break;
        default: break; /* version digits and '?' */
        }
    }
    return 1;
}

EXPORT struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode,
                                               const struct wl_interface *interface, uint32_t version, uint32_t flags,
                                               ...) {
    union wl_argument args[WL_MAX_ARGS];
    memset(args, 0, sizeof args);
    va_list ap;
    va_start(ap, flags);
    int ok = args_from_va(proxy, opcode, ap, args);
    va_end(ap);
    if (!ok) return NULL;
    return marshal(proxy, opcode, interface, version, flags, args);
}
