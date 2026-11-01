/*
 * caboose-draw-replay: draws a Caboose draw-list capture again with cairo, and checks it.
 *
 *     caboose-draw-replay [--scale S] [--png DIR] [--diff DIR] CAPTURE...
 *
 * Each capture is what libcaboose-draw-cairo.so wrote for one process (CABOOSE_DRAW_CAPTURE).
 * Every surface is drawn again at S times its pixels (default 1). At each PRESENT the window
 * surface's replay is written to DIR/surface-<id>-<frame>.png when --png is given, and a window
 * surface that never had one (an X11 window) to DIR/final-<id>.png at the end. With S = 1
 * each PIXELS op (CABOOSE_DRAW_PIXELS=1) is compared with the replay: replay and application use
 * the same rasterizer, so what differs is what the recording missed; --diff writes each comparison
 * to DIR/diff-<id>-<frame>.png, the picture dimmed and what differs in red. Prints one JSON line with
 * the op counts, the bytes by kind, and the comparison.
 */
#include <cairo.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cdl.h"

typedef struct {
    const uint8_t *p, *end;
    int bad;
} rd;

static uint8_t u8(rd *r) {
    if (r->p + 1 > r->end) { r->bad = 1; return 0; }
    return *r->p++;
}

static uint32_t u32(rd *r) {
    if (r->p + 4 > r->end) { r->bad = 1; r->p = r->end; return 0; }
    uint32_t v = cdl_read32(r->p);
    r->p += 4;
    return v;
}

static uint64_t u64(rd *r) {
    uint64_t lo = u32(r);
    return lo | ((uint64_t)u32(r) << 32);
}

static double f32(rd *r) {
    uint32_t u = u32(r);
    float f;
    memcpy(&f, &u, 4);
    return f;
}

static void matrix(rd *r, cairo_matrix_t *m) {
    m->xx = f32(r);
    m->yx = f32(r);
    m->xy = f32(r);
    m->yy = f32(r);
    m->x0 = f32(r);
    m->y0 = f32(r);
}

/* Appends a path to `cr`'s current path, each point through `m` first (when given). */
static void path(rd *r, cairo_t *cr, const cairo_matrix_t *m) {
    uint32_t nverbs = u32(r), npoints = u32(r);
    if (r->bad || (size_t)(r->end - r->p) < nverbs + (size_t)npoints * 8) { r->bad = 1; return; }
    const uint8_t *verbs = r->p;
    r->p += nverbs;
    rd pts = {r->p, r->p + (size_t)npoints * 8, 0};
    r->p += (size_t)npoints * 8;
    double cx = 0, cy = 0;
    for (uint32_t i = 0; i < nverbs; i++) {
        double x[3], y[3];
        int n = verbs[i] == CDL_MOVE || verbs[i] == CDL_LINE ? 1 : verbs[i] == CDL_QUAD ? 2 : verbs[i] == CDL_CUBIC ? 3 : 0;
        for (int k = 0; k < n; k++) {
            x[k] = f32(&pts);
            y[k] = f32(&pts);
            if (m) cairo_matrix_transform_point(m, &x[k], &y[k]);
        }
        switch (verbs[i]) {
        case CDL_MOVE: cairo_move_to(cr, x[0], y[0]); cx = x[0]; cy = y[0]; break;
        case CDL_LINE: cairo_line_to(cr, x[0], y[0]); cx = x[0]; cy = y[0]; break;
        case CDL_QUAD:
            cairo_curve_to(cr, cx + 2.0 / 3 * (x[0] - cx), cy + 2.0 / 3 * (y[0] - cy), x[1] + 2.0 / 3 * (x[0] - x[1]),
                           y[1] + 2.0 / 3 * (y[0] - y[1]), x[1], y[1]);
            cx = x[1]; cy = y[1];
            break;
        case CDL_CUBIC: cairo_curve_to(cr, x[0], y[0], x[1], y[1], x[2], y[2]); cx = x[2]; cy = y[2]; break;
        case CDL_CLOSE: cairo_close_path(cr); break;
        default: r->bad = 1; return;
        }
    }
}

/* ------------------------------------------------------------------------------------------ */

typedef struct {
    uint32_t id;
    cairo_surface_t *s;
    int w, h;
    int window;
    int frames;
} surface_t;

typedef struct {
    uint64_t key;
    cairo_surface_t *image; /* images */
    uint8_t *path;          /* glyph outlines: the encoded path */
    size_t path_len;
} resource_t;

static surface_t surfaces[4096];
static int nsurfaces;
static resource_t *resources;
static size_t nresources, capresources;
static double scale = 1;
static const char *png_dir, *diff_dir;

static struct {
    unsigned long ops[256], bytes[256];
    unsigned long frames, compared, pixels, differing, unsupported_area;
    double max_diff, sq_err;
    unsigned long missing;
} stats;

static surface_t *surface_find(uint32_t id) {
    for (int i = 0; i < nsurfaces; i++)
        if (surfaces[i].id == id) return &surfaces[i];
    return NULL;
}

static resource_t *resource_find(uint64_t key) {
    for (size_t i = 0; i < nresources; i++)
        if (resources[i].key == key) return &resources[i];
    return NULL;
}

static resource_t *resource_add(uint64_t key) {
    resource_t *r = resource_find(key);
    if (r) return r;
    if (nresources == capresources) {
        capresources = capresources ? capresources * 2 : 1024;
        resources = realloc(resources, capresources * sizeof *resources);
    }
    r = &resources[nresources++];
    memset(r, 0, sizeof *r);
    r->key = key;
    return r;
}

static uint64_t glyph_key(uint64_t font, uint32_t glyph) { return cdl_xxh64(&font, sizeof font, glyph); }

/* A source as a cairo pattern; NULL when it names something the capture does not hold. */
static cairo_pattern_t *source(rd *r) {
    cairo_pattern_t *p = NULL;
    cairo_matrix_t m;
    uint8_t kind = u8(r);
    switch (kind) {
    case CDL_SOURCE_SOLID: {
        double c[4];
        for (int i = 0; i < 4; i++) c[i] = f32(r);
        return cairo_pattern_create_rgba(c[0], c[1], c[2], c[3]);
    }
    case CDL_SOURCE_LINEAR:
    case CDL_SOURCE_RADIAL: {
        double v[6];
        int n = kind == CDL_SOURCE_LINEAR ? 4 : 6;
        for (int i = 0; i < n; i++) v[i] = f32(r);
        p = kind == CDL_SOURCE_LINEAR ? cairo_pattern_create_linear(v[0], v[1], v[2], v[3])
                                      : cairo_pattern_create_radial(v[0], v[1], v[2], v[3], v[4], v[5]);
        cairo_pattern_set_extend(p, (cairo_extend_t)u8(r));
        matrix(r, &m);
        cairo_pattern_set_matrix(p, &m);
        uint32_t stops = u32(r);
        for (uint32_t i = 0; i < stops && !r->bad; i++) {
            double o = f32(r), cr = f32(r), cg = f32(r), cb = f32(r), ca = f32(r);
            cairo_pattern_add_color_stop_rgba(p, o, cr, cg, cb, ca);
        }
        return p;
    }
    case CDL_SOURCE_SURFACE:
    case CDL_SOURCE_IMAGE: {
        cairo_surface_t *s = NULL;
        if (kind == CDL_SOURCE_SURFACE) {
            surface_t *t = surface_find(u32(r));
            if (t) s = t->s;
        } else {
            resource_t *res = resource_find(u64(r));
            if (res) s = res->image;
        }
        cairo_extend_t extend = (cairo_extend_t)u8(r);
        cairo_filter_t filter = (cairo_filter_t)u8(r);
        matrix(r, &m);
        if (!s) {
            stats.missing++;
            return NULL;
        }
        p = cairo_pattern_create_for_surface(s);
        cairo_pattern_set_extend(p, extend);
        cairo_pattern_set_filter(p, filter);
        cairo_pattern_set_matrix(p, &m);
        return p;
    }
    default:
        r->bad = 1;
        return NULL;
    }
}

static void clip(rd *r, cairo_t *cr) {
    cairo_reset_clip(cr);
    uint32_t n = u32(r);
    for (uint32_t i = 0; i < n && !r->bad; i++) {
        cairo_identity_matrix(cr);
        cairo_new_path(cr);
        if (u8(r) == CDL_CLIP_RECT) {
            double x = f32(r), y = f32(r), w = f32(r), h = f32(r);
            cairo_rectangle(cr, x, y, w, h);
            cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
        } else {
            cairo_matrix_t m;
            matrix(r, &m);
            cairo_set_fill_rule(cr, (cairo_fill_rule_t)u8(r));
            cairo_set_antialias(cr, (cairo_antialias_t)u8(r));
            path(r, cr, &m);
        }
        cairo_clip(cr);
    }
}

/* 32-bit premultiplied RGBA bytes as a cairo ARGB32 image. */
static cairo_surface_t *image_from_rgba(const uint8_t *rgba, int w, int h) {
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    uint8_t *data = cairo_image_surface_get_data(s);
    int stride = cairo_image_surface_get_stride(s);
    for (int y = 0; y < h; y++) {
        uint32_t *row = (uint32_t *)(data + (size_t)y * stride);
        const uint8_t *src = rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++, src += 4)
            row[x] = ((uint32_t)src[3] << 24) | ((uint32_t)src[0] << 16) | ((uint32_t)src[1] << 8) | src[2];
    }
    cairo_surface_mark_dirty(s);
    return s;
}

static void compare(surface_t *t, const uint8_t *rgba, int w, int h) {
    if (scale != 1 || t->w != w || t->h != h) return;
    cairo_surface_flush(t->s);
    const uint8_t *data = cairo_image_surface_get_data(t->s);
    int stride = cairo_image_surface_get_stride(t->s);
    stats.compared++;
    cairo_surface_t *diff = diff_dir ? cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h) : NULL;
    uint32_t *dd = diff ? (uint32_t *)cairo_image_surface_get_data(diff) : NULL;
    int dstride = diff ? cairo_image_surface_get_stride(diff) / 4 : 0;
    for (int y = 0; y < h; y++) {
        const uint32_t *row = (const uint32_t *)(data + (size_t)y * stride);
        for (int x = 0; x < w; x++) {
            const uint8_t *a = rgba + ((size_t)y * w + x) * 4;
            uint32_t p = row[x];
            int b[4] = {(int)(p >> 16) & 255, (int)(p >> 8) & 255, (int)p & 255, (int)(p >> 24)};
            int worst = 0;
            for (int c = 0; c < 4; c++) {
                int d = abs(a[c] - b[c]);
                stats.sq_err += (double)d * d;
                if (d > worst) worst = d;
            }
            stats.pixels++;
            if (worst > 8) stats.differing++;
            if (dd) {
                /* The application's picture, dimmed, with what differs in red. */
                uint32_t grey = (uint32_t)((a[0] + a[1] + a[2]) / 6 + 128);
                dd[(size_t)y * dstride + x] = worst > 8 ? 0xFF0000u | (uint32_t)(255 - worst) << 8 : grey << 16 | grey << 8 | grey;
            }
            if (worst > stats.max_diff) stats.max_diff = worst;
        }
    }
    if (diff) {
        cairo_surface_mark_dirty(diff);
        char name[4096];
        snprintf(name, sizeof name, "%s/diff-%u-%04d.png", diff_dir, t->id, t->frames);
        cairo_surface_write_to_png(diff, name);
        cairo_surface_destroy(diff);
    }
}

static void replay_op(uint8_t op, rd *r, cairo_t **crp, surface_t **target) {
    cairo_t *cr = *crp;
    switch (op) {
    case CDL_SURFACE: {
        uint32_t id = u32(r), w = u32(r), h = u32(r);
        int window = u8(r) == CDL_SURFACE_WINDOW;
        if (surface_find(id) || nsurfaces == (int)(sizeof surfaces / sizeof surfaces[0])) break;
        surface_t *t = &surfaces[nsurfaces++];
        t->id = id;
        t->w = (int)w;
        t->h = (int)h;
        t->frames = 0;
        t->window = window;
        t->s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)ceil(w * scale), (int)ceil(h * scale));
        cairo_surface_set_device_scale(t->s, scale, scale);
        break;
    }
    case CDL_FREE: {
        uint32_t id = u32(r);
        for (int i = 0; i < nsurfaces; i++) {
            if (surfaces[i].id != id) continue;
            if (*target == &surfaces[i]) {
                cairo_destroy(cr);
                *crp = NULL;
                *target = NULL;
            }
            cairo_surface_destroy(surfaces[i].s);
            surfaces[i] = surfaces[--nsurfaces];
            if (*target == &surfaces[nsurfaces]) *target = &surfaces[i];
            break;
        }
        break;
    }
    case CDL_TARGET: {
        surface_t *t = surface_find(u32(r));
        if (*crp) cairo_destroy(*crp);
        *crp = t ? cairo_create(t->s) : NULL;
        *target = t;
        break;
    }
    case CDL_CLIP:
        if (cr) clip(r, cr);
        break;
    case CDL_FILL:
    case CDL_STROKE:
    case CDL_PAINT:
    case CDL_MASK:
    case CDL_GLYPHS: {
        if (!cr) break;
        cairo_operator_t operator = (cairo_operator_t)u8(r);
        cairo_matrix_t m, fm;
        double alpha = 1;
        cairo_new_path(cr);
        cairo_identity_matrix(cr);
        if (op == CDL_FILL) {
            cairo_set_fill_rule(cr, (cairo_fill_rule_t)u8(r));
            cairo_set_antialias(cr, (cairo_antialias_t)u8(r));
        } else if (op == CDL_STROKE) {
            cairo_set_antialias(cr, (cairo_antialias_t)u8(r));
        } else if (op == CDL_PAINT) {
            alpha = f32(r);
        }
        matrix(r, &m);
        if (op == CDL_STROKE) {
            cairo_set_line_width(cr, f32(r));
            cairo_set_line_cap(cr, (cairo_line_cap_t)u8(r));
            cairo_set_line_join(cr, (cairo_line_join_t)u8(r));
            cairo_set_miter_limit(cr, f32(r));
            uint32_t ndash = u32(r);
            double offset = f32(r), dashes[64];
            for (uint32_t i = 0; i < ndash && i < 64; i++) dashes[i] = f32(r);
            cairo_set_dash(cr, dashes, ndash <= 64 ? (int)ndash : 0, offset);
        }
        uint64_t font = 0;
        if (op == CDL_GLYPHS) {
            matrix(r, &fm);
            font = u64(r);
        }
        cairo_pattern_t *src = source(r);
        cairo_pattern_t *mask = op == CDL_MASK ? source(r) : NULL;
        cairo_set_matrix(cr, &m);
        if (op == CDL_FILL || op == CDL_STROKE) path(r, cr, NULL);
        if (op == CDL_GLYPHS) {
            /* Outlines in em units, through the font matrix, at each glyph's origin. */
            uint32_t n = u32(r);
            cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
            cairo_set_antialias(cr, CAIRO_ANTIALIAS_DEFAULT);
            for (uint32_t i = 0; i < n && !r->bad; i++) {
                uint32_t glyph = u32(r);
                double x = f32(r), y = f32(r);
                resource_t *g = resource_find(glyph_key(font, glyph));
                if (!g) {
                    stats.missing++;
                    continue;
                }
                cairo_matrix_t gm = fm;
                gm.x0 += x;
                gm.y0 += y;
                rd pr = {g->path, g->path + g->path_len, 0};
                path(&pr, cr, &gm);
            }
        }
        if (src && !r->bad && (op != CDL_MASK || mask)) {
            cairo_set_source(cr, src);
            cairo_set_operator(cr, operator);
            switch (op) {
            case CDL_FILL: cairo_fill(cr); break;
            case CDL_STROKE: cairo_stroke(cr); break;
            case CDL_PAINT: cairo_paint_with_alpha(cr, alpha); break;
            case CDL_MASK: cairo_mask(cr, mask); break;
            case CDL_GLYPHS: cairo_fill(cr); break;
            }
        }
        cairo_new_path(cr);
        if (src) cairo_pattern_destroy(src);
        if (mask) cairo_pattern_destroy(mask);
        break;
    }
    case CDL_UNSUPPORTED: {
        u32(r);
        f32(r), f32(r);
        double w = f32(r), h = f32(r);
        stats.unsupported_area += (unsigned long)(w * h);
        break;
    }
    case CDL_IMAGE: {
        uint64_t hash = u64(r);
        uint32_t w = u32(r), h = u32(r);
        u8(r);
        if ((size_t)(r->end - r->p) < (size_t)w * h * 4) { r->bad = 1; break; }
        resource_t *res = resource_add(hash);
        if (!res->image) res->image = image_from_rgba(r->p, (int)w, (int)h);
        r->p += (size_t)w * h * 4;
        break;
    }
    case CDL_GLYPH: {
        uint64_t font = u64(r);
        uint32_t glyph = u32(r);
        resource_t *res = resource_add(glyph_key(font, glyph));
        if (!res->path) {
            res->path_len = (size_t)(r->end - r->p);
            res->path = malloc(res->path_len);
            memcpy(res->path, r->p, res->path_len);
        }
        r->p = r->end;
        break;
    }
    case CDL_PRESENT: {
        surface_t *t = surface_find(u32(r));
        u32(r);
        stats.frames++;
        if (t && png_dir) {
            char name[4096];
            snprintf(name, sizeof name, "%s/surface-%u-%04d.png", png_dir, t->id, t->frames);
            cairo_surface_write_to_png(t->s, name);
        }
        if (t) t->frames++;
        break;
    }
    case CDL_PIXELS: {
        surface_t *t = surface_find(u32(r));
        uint32_t w = u32(r), h = u32(r);
        if ((size_t)(r->end - r->p) < (size_t)w * h * 4) { r->bad = 1; break; }
        if (t) compare(t, r->p, (int)w, (int)h);
        r->p += (size_t)w * h * 4;
        break;
    }
    default:
        break; /* an op this reader does not know: skipped by its length */
    }
}

static int replay_file(const char *name) {
    FILE *f = fopen(name, "rb");
    if (!f) { perror(name); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *data = malloc(size > 0 ? (size_t)size : 1);
    if (fread(data, 1, (size_t)size, f) != (size_t)size) { fclose(f); free(data); return 1; }
    fclose(f);
    cairo_t *cr = NULL;
    surface_t *target = NULL;
    const uint8_t *p = data, *end = data + size;
    while (p + 5 <= end) {
        uint8_t op = p[0];
        uint32_t len = cdl_read32(p + 1);
        if ((size_t)(end - p - 5) < len) {
            fprintf(stderr, "%s: truncated op 0x%02x\n", name, op);
            break;
        }
        rd r = {p + 5, p + 5 + len, 0};
        stats.ops[op]++;
        stats.bytes[op] += 5 + len;
        replay_op(op, &r, &cr, &target);
        if (r.bad) fprintf(stderr, "%s: malformed op 0x%02x\n", name, op);
        p += 5 + len;
    }
    if (cr) cairo_destroy(cr);
    free(data);
    for (int i = 0; i < nsurfaces; i++) {
        /* Window surfaces without a PRESENT (X11 windows): their last state. */
        if (png_dir && surfaces[i].window && !surfaces[i].frames) {
            char out[4096];
            snprintf(out, sizeof out, "%s/final-%u.png", png_dir, surfaces[i].id);
            cairo_surface_write_to_png(surfaces[i].s, out);
        }
        cairo_surface_destroy(surfaces[i].s);
    }
    nsurfaces = 0;
    return 0;
}

int main(int argc, char **argv) {
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "--scale") && i + 1 < argc) scale = atof(argv[++i]);
        else if (!strcmp(argv[i], "--png") && i + 1 < argc) png_dir = argv[++i];
        else if (!strcmp(argv[i], "--diff") && i + 1 < argc) diff_dir = argv[++i];
        else {
            fprintf(stderr, "usage: caboose-draw-replay [--scale S] [--png DIR] [--diff DIR] CAPTURE...\n");
            return 2;
        }
    }
    if (scale <= 0) scale = 1;
    int failed = 0;
    for (; i < argc; i++) failed |= replay_file(argv[i]);
    static const struct { uint8_t op; const char *name; } names[] = {
        {CDL_SURFACE, "surface"}, {CDL_FREE, "free"}, {CDL_TARGET, "target"}, {CDL_CLIP, "clip"},
        {CDL_FILL, "fill"}, {CDL_STROKE, "stroke"}, {CDL_PAINT, "paint"}, {CDL_MASK, "mask"},
        {CDL_GLYPHS, "glyphs"}, {CDL_UNSUPPORTED, "unsupported"}, {CDL_IMAGE, "image"}, {CDL_GLYPH, "glyph"},
        {CDL_PRESENT, "present"}, {CDL_PIXELS, "pixels"}};
    printf("{\"ops\":{");
    int first = 1;
    for (size_t k = 0; k < sizeof names / sizeof names[0]; k++) {
        if (!stats.ops[names[k].op]) continue;
        printf("%s\"%s\":[%lu,%lu]", first ? "" : ",", names[k].name, stats.ops[names[k].op], stats.bytes[names[k].op]);
        first = 0;
    }
    double psnr = stats.sq_err > 0 ? 10 * log10(255.0 * 255.0 / (stats.sq_err / (stats.pixels * 4.0))) : 99;
    printf("},\"frames\":%lu,\"compared\":%lu,\"pixels\":%lu,\"differing\":%lu,\"max_diff\":%.0f,\"psnr\":%.2f,"
           "\"missing\":%lu,\"unsupported_px\":%lu}\n",
           stats.frames, stats.compared, stats.pixels, stats.differing, stats.max_diff, psnr, stats.missing,
           stats.unsupported_area);
    return failed;
}
