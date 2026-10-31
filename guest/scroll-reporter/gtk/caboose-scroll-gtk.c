// The GTK scroll reporter (docs/display.md, "Scroll reports"), a preload library for every
// application: LD_PRELOAD=libcaboose-scroll-gtk4.so (or -gtk3). It does nothing in a process
// without that GTK; GLib and GTK are reached through dlsym only, so it links to neither.
//
// For each toplevel it hooks the frame clock's layout phase, after GTK's own layout: the
// scrolled windows' adjustments then hold what this frame draws. It reports the largest
// scrolled window first and every other one after it, to caboose-display's scroll socket.
// The frame tag is a drawing area the reporter parents to the window itself, outside the
// application's layout, and places in the bottom overscan. It is redrawn in the same frame
// whenever the report changes, so the picture of each frame names its report on every GSK
// renderer and on GPU presents. scroll.target deltas move the adjustment, and the frame that
// draws the result reports their seq as applied.
//
// Built twice: -DCABOOSE_GTK=4 against GTK 4 headers, -DCABOOSE_GTK=3 against GTK 3.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <gtk/gtk.h>

#define BLOCKS 32
#define MAX_SCROLLERS 8
#define MAX_MESSAGE (1 << 20)

// ---- GLib and GTK, resolved at run time.

#define FN(ret, name, args) static ret(*p_##name) args;
#define GLIB_FNS \
    FN(guint, g_timeout_add, (guint, GSourceFunc, gpointer)) \
    FN(guint, g_unix_fd_add, (gint, GIOCondition, gboolean (*)(gint, GIOCondition, gpointer), gpointer)) \
    FN(gulong, g_signal_connect_data, (gpointer, const gchar *, GCallback, gpointer, GClosureNotify, GConnectFlags)) \
    FN(gpointer, g_object_get_data, (GObject *, const gchar *)) \
    FN(void, g_object_set_data, (GObject *, const gchar *, gpointer)) \
    FN(gboolean, g_type_check_instance_is_a, (GTypeInstance *, GType)) \
    FN(gpointer, g_object_ref, (gpointer)) \
    FN(void, g_object_unref, (gpointer)) \
    FN(GMainContext *, g_main_context_default, (void)) \
    FN(GSource *, g_main_context_find_source_by_id, (GMainContext *, guint)) \
    FN(void, gdk_frame_clock_request_phase, (GdkFrameClock *, GdkFrameClockPhase))
#if CABOOSE_GTK == 4
#define GTK_FNS \
    FN(gboolean, gtk_is_initialized, (void)) \
    FN(GListModel *, gtk_window_get_toplevels, (void)) \
    FN(guint, g_list_model_get_n_items, (GListModel *)) \
    FN(gpointer, g_list_model_get_item, (GListModel *, guint)) \
    FN(GType, gtk_scrolled_window_get_type, (void)) \
    FN(GtkAdjustment *, gtk_scrolled_window_get_vadjustment, (GtkScrolledWindow *)) \
    FN(GtkAdjustment *, gtk_scrolled_window_get_hadjustment, (GtkScrolledWindow *)) \
    FN(GtkWidget *, gtk_widget_get_first_child, (GtkWidget *)) \
    FN(GtkWidget *, gtk_widget_get_next_sibling, (GtkWidget *)) \
    FN(gboolean, gtk_widget_get_mapped, (GtkWidget *)) \
    FN(gboolean, gtk_widget_compute_bounds, (GtkWidget *, GtkWidget *, graphene_rect_t *)) \
    FN(int, gtk_widget_get_width, (GtkWidget *)) \
    FN(int, gtk_widget_get_height, (GtkWidget *)) \
    FN(void, gtk_widget_set_parent, (GtkWidget *, GtkWidget *)) \
    FN(void, gtk_widget_set_can_target, (GtkWidget *, gboolean)) \
    FN(void, gtk_widget_set_can_focus, (GtkWidget *, gboolean)) \
    FN(void, gtk_widget_size_allocate, (GtkWidget *, const GtkAllocation *, int)) \
    FN(void, gtk_widget_measure, (GtkWidget *, GtkOrientation, int, int *, int *, int *, int *)) \
    FN(void, gtk_widget_queue_draw, (GtkWidget *)) \
    FN(void, gtk_widget_set_visible, (GtkWidget *, gboolean)) \
    FN(GtkWidget *, gtk_drawing_area_new, (void)) \
    FN(void, gtk_drawing_area_set_draw_func, (GtkDrawingArea *, GtkDrawingAreaDrawFunc, gpointer, GDestroyNotify)) \
    FN(GdkSurface *, gtk_native_get_surface, (GtkNative *)) \
    FN(GdkFrameClock *, gdk_surface_get_frame_clock, (GdkSurface *)) \
    FN(double, gdk_surface_get_scale, (GdkSurface *)) \
    FN(const char *, gtk_window_get_title, (GtkWindow *))
#else
#define GTK_FNS \
    FN(GList *, gtk_window_list_toplevels, (void)) \
    FN(void, g_list_free, (GList *)) \
    FN(GType, gtk_scrolled_window_get_type, (void)) \
    FN(GType, gtk_container_get_type, (void)) \
    FN(GtkAdjustment *, gtk_scrolled_window_get_vadjustment, (GtkScrolledWindow *)) \
    FN(GtkAdjustment *, gtk_scrolled_window_get_hadjustment, (GtkScrolledWindow *)) \
    FN(void, gtk_container_forall, (GtkContainer *, GtkCallback, gpointer)) \
    FN(gboolean, gtk_widget_get_mapped, (GtkWidget *)) \
    FN(gboolean, gtk_widget_get_realized, (GtkWidget *)) \
    FN(void, gtk_widget_get_allocation, (GtkWidget *, GtkAllocation *)) \
    FN(gboolean, gtk_widget_translate_coordinates, (GtkWidget *, GtkWidget *, gint, gint, gint *, gint *)) \
    FN(gint, gtk_widget_get_scale_factor, (GtkWidget *)) \
    FN(GdkFrameClock *, gtk_widget_get_frame_clock, (GtkWidget *)) \
    FN(void, gtk_widget_queue_draw_area, (GtkWidget *, gint, gint, gint, gint)) \
    FN(GtkWidget *, gtk_bin_get_child, (GtkBin *)) \
    FN(GtkWidget *, gtk_window_get_titlebar, (GtkWindow *)) \
    FN(GType, gtk_bin_get_type, (void)) \
    FN(const gchar *, gtk_window_get_title, (GtkWindow *)) \
    FN(void, cairo_set_source_rgb, (cairo_t *, double, double, double)) \
    FN(void, cairo_rectangle, (cairo_t *, double, double, double, double)) \
    FN(void, cairo_fill, (cairo_t *)) \
    FN(void, cairo_save, (cairo_t *)) \
    FN(void, cairo_restore, (cairo_t *)) \
    FN(void, cairo_reset_clip, (cairo_t *))
#endif
#define ADJ_FNS \
    FN(gdouble, gtk_adjustment_get_value, (GtkAdjustment *)) \
    FN(gdouble, gtk_adjustment_get_lower, (GtkAdjustment *)) \
    FN(gdouble, gtk_adjustment_get_upper, (GtkAdjustment *)) \
    FN(gdouble, gtk_adjustment_get_page_size, (GtkAdjustment *)) \
    FN(void, gtk_adjustment_set_value, (GtkAdjustment *, gdouble))
GLIB_FNS
GTK_FNS
ADJ_FNS
#if CABOOSE_GTK == 4
FN(void, cairo_set_source_rgb, (cairo_t *, double, double, double))
FN(void, cairo_rectangle, (cairo_t *, double, double, double, double))
FN(void, cairo_fill, (cairo_t *))
#endif
#undef FN

static int resolve(void) {
    int ok = 1;
#define FN(ret, name, args) ok &= (p_##name = (ret(*) args)dlsym(RTLD_DEFAULT, #name)) != NULL;
    GLIB_FNS
    GTK_FNS
    ADJ_FNS
#if CABOOSE_GTK == 4
    FN(void, cairo_set_source_rgb, (cairo_t *, double, double, double))
    FN(void, cairo_rectangle, (cairo_t *, double, double, double, double))
    FN(void, cairo_fill, (cairo_t *))
#endif
#undef FN
    return ok;
}

#define is_a(obj, type) p_g_type_check_instance_is_a((GTypeInstance *)(obj), (type))

// ---- The socket.

static int sock = -1;
static unsigned char inbuf[MAX_MESSAGE + 4];
static size_t inlen;

typedef struct {
    int bound, active, reporter;
    double overscan_h, tag_top, block;
} Bind;
static Bind bind_state;
static unsigned long long applied;

static void send_json(const char *json) {
    if (sock < 0) return;
    unsigned int n = (unsigned int)strlen(json);
    unsigned char head[4] = {n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff};
    struct iovec iov[2] = {{head, 4}, {(void *)json, n}};
    struct msghdr m = {.msg_iov = iov, .msg_iovlen = 2};
    // A reporter that cannot keep up drops reports; a later one replaces them.
    if (sendmsg(sock, &m, MSG_DONTWAIT | MSG_NOSIGNAL) < 0 && errno != EAGAIN) {
        close(sock);
        sock = -1;
        bind_state.bound = 0;
    }
}

/** The number after `"key":` in a compact JSON object, or NAN. */
static double json_number(const char *json, const char *key) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":", key);
    const char *at = strstr(json, pattern);
    return at ? strtod(at + strlen(pattern), NULL) : NAN;
}

/** The `index`th number of the array after `"key":[`, or NAN. */
static double json_array(const char *json, const char *key, int index) {
    char pattern[64];
    snprintf(pattern, sizeof pattern, "\"%s\":[", key);
    const char *at = strstr(json, pattern);
    if (!at) return NAN;
    at += strlen(pattern);
    for (int i = 0; i < index; i++) {
        at = strchr(at, ',');
        if (!at) return NAN;
        at++;
    }
    return strtod(at, NULL);
}

// ---- Windows and their scrollers.

typedef struct {
    GtkScrolledWindow *sw;
    double x, y, w, h; // window logical pixels
} Found;

typedef struct {
    GtkWidget *window;
    GdkFrameClock *clock;
#if CABOOSE_GTK == 4
    GtkWidget *tag;
#endif
    unsigned int frame;
    unsigned long long epoch;
    double last_upper;
    char last[8192];
    double tag_rect[4]; // logical, while drawn
    int tagged;
} Win;

static Win *wins[32];
static int nwins;
static Win *reporting; // the window the compositor bound us to: the newest one that reported

static unsigned int next_scroller = 1;
static unsigned int scroller_id(GtkScrolledWindow *sw) {
    unsigned int id = (unsigned int)(gsize)p_g_object_get_data((GObject *)sw, "caboose-scroller");
    if (!id) {
        id = next_scroller++;
        p_g_object_set_data((GObject *)sw, "caboose-scroller", (gpointer)(gsize)id);
    }
    return id;
}

static GtkScrolledWindow *scroller_by_id(Win *w, unsigned int id);

#if CABOOSE_GTK == 4
static void collect(GtkWidget *widget, Win *w, Found *out, int *n) {
    for (GtkWidget *c = p_gtk_widget_get_first_child(widget); c; c = p_gtk_widget_get_next_sibling(c)) {
        if (c == w->tag || !p_gtk_widget_get_mapped(c)) continue;
        if (is_a(c, p_gtk_scrolled_window_get_type()) && *n < MAX_SCROLLERS) {
            graphene_rect_t r;
            if (p_gtk_widget_compute_bounds(c, w->window, &r)) {
                out[(*n)++] = (Found){(GtkScrolledWindow *)c, r.origin.x, r.origin.y, r.size.width, r.size.height};
            }
        }
        collect(c, w, out, n);
    }
}
static double window_scale(Win *w) { return p_gdk_surface_get_scale(p_gtk_native_get_surface((GtkNative *)w->window)); }
static void window_size(Win *w, double *width, double *height) {
    *width = p_gtk_widget_get_width(w->window);
    *height = p_gtk_widget_get_height(w->window);
}
static void window_origin(Win *w, double *x, double *y) { *x = 0; *y = 0; }
#else
typedef struct {
    Win *w;
    Found *out;
    int *n;
} Walk;
static void collect_cb(GtkWidget *c, gpointer data) {
    Walk *k = data;
    if (!p_gtk_widget_get_mapped(c)) return;
    if (is_a(c, p_gtk_scrolled_window_get_type()) && *k->n < MAX_SCROLLERS) {
        GtkAllocation a;
        int x, y;
        p_gtk_widget_get_allocation(c, &a);
        if (p_gtk_widget_translate_coordinates(c, k->w->window, 0, 0, &x, &y)) {
            k->out[(*k->n)++] = (Found){(GtkScrolledWindow *)c, x, y, a.width, a.height};
        }
    }
    if (is_a(c, p_gtk_container_get_type())) p_gtk_container_forall((GtkContainer *)c, collect_cb, k);
}
static void collect(GtkWidget *widget, Win *w, Found *out, int *n) {
    Walk k = {w, out, n};
    p_gtk_container_forall((GtkContainer *)widget, collect_cb, &k);
}
static double window_scale(Win *w) { return p_gtk_widget_get_scale_factor(w->window); }
// A client-side decorated GTK 3 window's allocation includes its shadow: the window is
// what its titlebar and content cover.
static void window_frame(Win *w, double *x, double *y, double *width, double *height) {
    GtkAllocation whole, a;
    p_gtk_widget_get_allocation(w->window, &whole);
    double x0 = whole.width, y0 = whole.height, x1 = 0, y1 = 0;
    GtkWidget *parts[2] = {p_gtk_window_get_titlebar((GtkWindow *)w->window), p_gtk_bin_get_child((GtkBin *)w->window)};
    for (int i = 0; i < 2; i++) {
        if (!parts[i] || !p_gtk_widget_get_mapped(parts[i])) continue;
        p_gtk_widget_get_allocation(parts[i], &a);
        int px, py;
        if (!p_gtk_widget_translate_coordinates(parts[i], w->window, 0, 0, &px, &py)) continue;
        x0 = fmin(x0, px), y0 = fmin(y0, py), x1 = fmax(x1, px + a.width), y1 = fmax(y1, py + a.height);
    }
    if (x1 <= x0 || y1 <= y0) x0 = 0, y0 = 0, x1 = whole.width, y1 = whole.height;
    *x = x0, *y = y0, *width = x1 - x0, *height = y1 - y0;
}
static void window_size(Win *w, double *width, double *height) {
    double x, y;
    window_frame(w, &x, &y, width, height);
}
static void window_origin(Win *w, double *x, double *y) {
    double width, height;
    window_frame(w, x, y, &width, &height);
}
#endif

static int collect_sorted(Win *w, Found *found) {
    int n = 0;
    collect(w->window, w, found, &n);
    // The largest first: the primary scroller.
    for (int i = 1; i < n; i++) {
        for (int j = i; j > 0 && found[j].w * found[j].h > found[j - 1].w * found[j - 1].h; j--) {
            Found t = found[j];
            found[j] = found[j - 1];
            found[j - 1] = t;
        }
    }
    return n;
}

static GtkScrolledWindow *scroller_by_id(Win *w, unsigned int id) {
    Found found[MAX_SCROLLERS];
    int n = collect_sorted(w, found);
    for (int i = 0; i < n; i++) {
        if (scroller_id(found[i].sw) == id) return found[i].sw;
    }
    return NULL;
}

static void append(char *buf, size_t size, size_t *len, const char *fmt, ...) {
    if (*len >= size) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf + *len, size - *len, fmt, ap);
    va_end(ap);
    if (n > 0) *len += (size_t)n;
}

static int tag_bit(unsigned int value, int i) {
    if (i < 4) return i % 2 == 0;
    if (i < 28) return (value >> (27 - i)) & 1;
    unsigned int check = 0;
    for (int k = 0; k < 6; k++) check ^= (value >> (4 * k)) & 0xf;
    return (check >> (31 - i)) & 1;
}

static unsigned int tag_value(Win *w) { return ((unsigned int)(bind_state.reporter & 0xff) << 16) | (w->frame & 0xffff); }

static void draw_blocks(cairo_t *cr, Win *w, double x, double y, double side) {
    unsigned int value = tag_value(w);
    for (int i = 0; i < BLOCKS; i++) {
        double v = tag_bit(value, i) ? 1 : 0;
        p_cairo_set_source_rgb(cr, v, v, v);
        p_cairo_rectangle(cr, x + i * side, y, side, side);
        p_cairo_fill(cr);
    }
}

#if CABOOSE_GTK == 4
static void draw_tag(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    Win *w = data;
    if (w->tagged) draw_blocks(cr, w, 0, 0, height);
}
#else
static gboolean draw_tag(GtkWidget *window, cairo_t *cr, gpointer data) {
    Win *w = data;
    if (!w->tagged) return FALSE;
    p_cairo_save(cr);
    p_cairo_reset_clip(cr);
    draw_blocks(cr, w, w->tag_rect[0], w->tag_rect[1], w->tag_rect[3]);
    p_cairo_restore(cr);
    return FALSE;
}
#endif

/** After GTK's layout of a frame: report it, and draw its tag if anything changed. */
static void on_layout(GdkFrameClock *clock, gpointer data) {
    Win *w = data;
    if (sock < 0) return;
    double scale = window_scale(w), width, height, ox, oy;
    window_size(w, &width, &height);
    window_origin(w, &ox, &oy);
    Found found[MAX_SCROLLERS];
    int n = collect_sorted(w, found);
    if (n == 0) return;
    // The tag: at the first overscan line, while the client places pictures by reports.
    int tagged = 0;
    double side = 0, top = 0;
    if (bind_state.bound && bind_state.active && reporting == w) {
        side = ceil(bind_state.block / scale - 1e-6);
        top = round(bind_state.tag_top / scale);
        tagged = side > 0 && bind_state.overscan_h >= side * scale && top >= 0 && top + side <= height;
    }
    char report[8192];
    size_t len = 0;
    const char *title = p_gtk_window_get_title((GtkWindow *)w->window);
    char safe[256] = "";
    for (size_t i = 0, j = 0; title && title[i] && j < sizeof safe - 2; i++) {
        if (title[i] == '"' || title[i] == '\\' || title[i] == '%' || (unsigned char)title[i] < 0x20) continue;
        safe[j++] = title[i];
        safe[j] = 0;
    }
    GtkAdjustment *primary = p_gtk_scrolled_window_get_vadjustment(found[0].sw);
    double upper = p_gtk_adjustment_get_upper(primary);
    // Content that grows or shrinks around the offset moves in document coordinates.
    if (w->last_upper != 0 && upper != w->last_upper) w->epoch++;
    w->last_upper = upper;
    append(report, sizeof report, &len,
           "{\"type\":\"report\",\"title\":\"%s\",\"outer\":[%.2f,%.2f],\"viewport\":[%.2f,%.2f],\"frame\":%%u,"
           "\"applied\":%llu,\"epoch\":%llu,",
           safe, width * scale, height * scale, width * scale, height * scale, applied, w->epoch);
    if (tagged) {
        append(report, sizeof report, &len, "\"tag\":[0,%.2f,%.2f,%.2f],", top * scale, BLOCKS * side * scale, side * scale);
    } else {
        append(report, sizeof report, &len, "\"tag\":null,");
    }
    append(report, sizeof report, &len, "\"scrollers\":[");
    for (int i = 0; i < n; i++) {
        GtkAdjustment *h = p_gtk_scrolled_window_get_hadjustment(found[i].sw);
        GtkAdjustment *v = p_gtk_scrolled_window_get_vadjustment(found[i].sw);
        double hx = p_gtk_adjustment_get_value(h) - p_gtk_adjustment_get_lower(h);
        double vy = p_gtk_adjustment_get_value(v) - p_gtk_adjustment_get_lower(v);
        double hr = fmax(0, p_gtk_adjustment_get_upper(h) - p_gtk_adjustment_get_page_size(h) - p_gtk_adjustment_get_lower(h));
        double vr = fmax(0, p_gtk_adjustment_get_upper(v) - p_gtk_adjustment_get_page_size(v) - p_gtk_adjustment_get_lower(v));
        append(report, sizeof report, &len, "%s{\"id\":%u,\"rect\":[%.2f,%.2f,%.2f,%.2f],\"offset\":[%.2f,%.2f],\"range\":[%.2f,%.2f]",
               i ? "," : "", scroller_id(found[i].sw), (found[i].x - ox) * scale, (found[i].y - oy) * scale,
               found[i].w * scale, found[i].h * scale, hx * scale, vy * scale, hr * scale, vr * scale);
        if (i == 0 && tagged) {
            append(report, sizeof report, &len, ",\"fixed\":[[0,%.2f,%.2f,%.2f]]", top * scale, BLOCKS * side * scale, side * scale);
        }
        append(report, sizeof report, &len, "}");
    }
    append(report, sizeof report, &len, "]}");
    if (len >= sizeof report || strcmp(report, w->last) == 0) return;
    memcpy(w->last, report, len + 1);
    w->frame = (w->frame + 1) & 0xffff;
    w->tagged = tagged;
    char out[8300];
    snprintf(out, sizeof out, report, w->frame);
    reporting = w;
    send_json(out);
#if CABOOSE_GTK == 4
    p_gtk_widget_set_visible(w->tag, tagged);
    if (tagged) {
        GtkAllocation a = {(int)ox, (int)(oy + top), (int)(BLOCKS * side), (int)side};
        int min, nat;
        p_gtk_widget_measure(w->tag, GTK_ORIENTATION_HORIZONTAL, -1, &min, &nat, NULL, NULL);
        p_gtk_widget_measure(w->tag, GTK_ORIENTATION_VERTICAL, a.width, &min, &nat, NULL, NULL);
        p_gtk_widget_size_allocate(w->tag, &a, -1);
        p_gtk_widget_queue_draw(w->tag);
    }
#else
    double was[4];
    memcpy(was, w->tag_rect, sizeof was);
    w->tag_rect[0] = ox, w->tag_rect[1] = oy + top, w->tag_rect[2] = BLOCKS * side, w->tag_rect[3] = side;
    if (tagged) p_gtk_widget_queue_draw_area(w->window, (int)w->tag_rect[0], (int)w->tag_rect[1], (int)w->tag_rect[2], (int)w->tag_rect[3]);
    else if (was[2] > 0) p_gtk_widget_queue_draw_area(w->window, (int)was[0], (int)was[1], (int)was[2], (int)was[3]);
#endif
}

static void hook(GtkWidget *window) {
    if (nwins >= (int)(sizeof wins / sizeof *wins) || p_g_object_get_data((GObject *)window, "caboose-scroll")) return;
#if CABOOSE_GTK == 4
    GdkSurface *surface = p_gtk_native_get_surface((GtkNative *)window);
    GdkFrameClock *clock = surface ? p_gdk_surface_get_frame_clock(surface) : NULL;
#else
    GdkFrameClock *clock = p_gtk_widget_get_realized(window) ? p_gtk_widget_get_frame_clock(window) : NULL;
#endif
    if (!clock) return;
    Win *w = calloc(1, sizeof *w);
    w->window = window;
    w->clock = clock;
    p_g_object_ref(window);
    p_g_object_set_data((GObject *)window, "caboose-scroll", w);
#if CABOOSE_GTK == 4
    w->tag = p_gtk_drawing_area_new();
    p_gtk_widget_set_can_target(w->tag, FALSE);
    p_gtk_widget_set_can_focus(w->tag, FALSE);
    p_gtk_drawing_area_set_draw_func((GtkDrawingArea *)w->tag, draw_tag, w, NULL);
    p_gtk_widget_set_parent(w->tag, window);
    p_gtk_widget_set_visible(w->tag, FALSE);
#else
    p_g_signal_connect_data(window, "draw", G_CALLBACK(draw_tag), w, NULL, G_CONNECT_AFTER);
#endif
    p_g_signal_connect_data(clock, "layout", G_CALLBACK(on_layout), w, NULL, G_CONNECT_AFTER);
    wins[nwins++] = w;
}

static void apply_target(const char *json) {
    Win *w = reporting;
    double seq = json_number(json, "seq"), id = json_number(json, "scroller");
    double dx = json_array(json, "delta", 0), dy = json_array(json, "delta", 1);
    if (!w || isnan(seq) || isnan(id) || isnan(dx) || isnan(dy)) return;
    GtkScrolledWindow *sw = scroller_by_id(w, (unsigned int)id);
    if (sw) {
        double scale = window_scale(w);
        GtkAdjustment *adj[2] = {p_gtk_scrolled_window_get_hadjustment(sw), p_gtk_scrolled_window_get_vadjustment(sw)};
        double d[2] = {dx / scale, dy / scale};
        for (int i = 0; i < 2; i++) {
            if (d[i] != 0) p_gtk_adjustment_set_value(adj[i], p_gtk_adjustment_get_value(adj[i]) + d[i]);
        }
    }
    if (seq > applied) applied = (unsigned long long)seq;
}

static void on_message(const char *json) {
    if (strstr(json, "\"type\":\"bind\"")) {
        bind_state = (Bind){1, strstr(json, "\"active\":true") != NULL, (int)json_number(json, "reporter"),
                            json_array(json, "overscan", 1), json_number(json, "tag_top"), json_number(json, "block")};
    } else if (strstr(json, "\"type\":\"unbind\"")) {
        bind_state.bound = 0;
    } else if (strstr(json, "\"type\":\"target\"")) {
        apply_target(json);
    } else {
        return;
    }
    // A frame reports again with the new state: its layout phase is where reports are made.
    for (int i = 0; i < nwins; i++) {
        wins[i]->last[0] = 0;
        p_gdk_frame_clock_request_phase(wins[i]->clock, GDK_FRAME_CLOCK_PHASE_LAYOUT);
    }
}

static gboolean on_socket(gint fd, GIOCondition condition, gpointer data) {
    ssize_t n = read(fd, inbuf + inlen, sizeof inbuf - inlen);
    if (n <= 0) {
        close(fd);
        sock = -1;
        bind_state.bound = 0;
        return FALSE;
    }
    inlen += (size_t)n;
    while (inlen >= 4) {
        unsigned int len = inbuf[0] | inbuf[1] << 8 | inbuf[2] << 16 | (unsigned int)inbuf[3] << 24;
        if (len > MAX_MESSAGE) {
            close(fd);
            sock = -1;
            return FALSE;
        }
        if (inlen < 4 + len) break;
        char msg[4096];
        size_t take = len < sizeof msg - 1 ? len : sizeof msg - 1;
        memcpy(msg, inbuf + 4, take);
        msg[take] = 0;
        on_message(msg);
        memmove(inbuf, inbuf + 4 + len, inlen - 4 - len);
        inlen -= 4 + len;
    }
    return TRUE;
}

static void connect_socket(void) {
    const char *path = getenv("CABOOSE_SCROLL_SOCKET");
    if (!path || !*path) return;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (fd < 0 || strlen(path) >= sizeof addr.sun_path) return;
    strcpy(addr.sun_path, path);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        close(fd);
        return;
    }
    sock = fd;
    inlen = 0;
    p_g_unix_fd_add(fd, G_IO_IN | G_IO_HUP | G_IO_ERR, on_socket, NULL);
}

/** Every quarter second: hook new toplevels, and reconnect after caboose-display restarts. */
static gboolean poll_windows(gpointer data) {
#if CABOOSE_GTK == 4
    if (!p_gtk_is_initialized()) return TRUE;
    GListModel *list = p_gtk_window_get_toplevels();
    for (guint i = 0; i < p_g_list_model_get_n_items(list); i++) {
        GtkWidget *window = p_g_list_model_get_item(list, i);
        if (p_gtk_widget_get_mapped(window)) hook(window);
        p_g_object_unref(window);
    }
#else
    GList *list = p_gtk_window_list_toplevels();
    for (GList *l = list; l; l = l->next) {
        if (p_gtk_widget_get_mapped(l->data)) hook(l->data);
    }
    p_g_list_free(list);
#endif
    if (sock < 0 && nwins > 0) connect_socket();
    return TRUE;
}

__attribute__((constructor)) static void start(void) {
    if (!getenv("CABOOSE_SCROLL_SOCKET")) return;
#if CABOOSE_GTK == 4
    if (!dlsym(RTLD_DEFAULT, "gtk_window_get_toplevels") || !dlsym(RTLD_DEFAULT, "gsk_renderer_render")) return;
#else
    if (!dlsym(RTLD_DEFAULT, "gtk_window_list_toplevels") || dlsym(RTLD_DEFAULT, "gsk_renderer_render")) return;
#endif
    if (!resolve()) return;
    p_g_timeout_add(250, poll_windows, NULL);
}
