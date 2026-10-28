#include "marker.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

uint8_t cb_mark_crc7(uint32_t data18)
{
    unsigned crc = 0;
    for (int i = 17; i >= 0; i--) {
        unsigned in = (data18 >> i) & 1;
        unsigned top = (crc >> 6) & 1;
        crc = (crc << 1) & 0x7f;
        if (in ^ top)
            crc ^= 0x09;
    }
    return (uint8_t)crc;
}

uint32_t cb_mark_payload(unsigned col, unsigned row, unsigned tag, unsigned seq)
{
    uint32_t d = (col & 7) | (row & 7) << 3 | (tag & 63) << 6 | (seq & 63) << 12;
    return d | (uint32_t)cb_mark_crc7(d) << 18;
}

static int tag_module(unsigned x, unsigned y, uint32_t payload)
{
    if (x == 0 || y == 0 || x == CB_MARK_MODS - 1 || y == CB_MARK_MODS - 1)
        return ((x + y) & 1) == 0;
    return (payload >> ((y - 1) * 5 + (x - 1))) & 1;
}

int cb_mark_module(unsigned i, unsigned j, unsigned tag, unsigned seq)
{
    uint32_t p = cb_mark_payload(i / CB_MARK_MODS, j / CB_MARK_MODS, tag, seq);
    return tag_module(i % CB_MARK_MODS, j % CB_MARK_MODS, p);
}

static void fill(uint8_t *luma, size_t pitch, unsigned bps, unsigned x0, unsigned x1,
                 unsigned y0, unsigned y1, int bright)
{
    unsigned v = bright ? CB_MARK_BRIGHT : CB_MARK_DARK;
    for (unsigned y = y0; y < y1; y++) {
        uint8_t *row = luma + y * pitch;
        if (bps == 1) {
            memset(row + x0, (int)v, x1 - x0);
        } else {
            uint16_t s = (uint16_t)(v << 8); /* P010: 10 bits MSB aligned, v * 4 << 6 */
            uint16_t *r16 = (uint16_t *)row;
            for (unsigned x = x0; x < x1; x++)
                r16[x] = s;
        }
    }
}

void cb_mark_paint(uint8_t *luma, size_t pitch, unsigned w, unsigned h, unsigned bps,
                   unsigned tag, unsigned seq, int prev)
{
    for (unsigned row = 0; row < CB_MARK_TAGS; row++) {
        for (unsigned col = 0; col < CB_MARK_TAGS; col++) {
            uint32_t now = cb_mark_payload(col, row, tag, seq);
            uint32_t was = prev >= 0 ? cb_mark_payload(col, row, (unsigned)prev >> 6, (unsigned)prev & 63) : 0;
            for (unsigned y = 0; y < CB_MARK_MODS; y++) {
                for (unsigned x = 0; x < CB_MARK_MODS; x++) {
                    int b = tag_module(x, y, now);
                    if (prev >= 0 && b == tag_module(x, y, was))
                        continue;
                    unsigned i = col * CB_MARK_MODS + x, j = row * CB_MARK_MODS + y;
                    fill(luma, pitch, bps, i * w / CB_MARK_GRID, (i + 1) * w / CB_MARK_GRID,
                         j * h / CB_MARK_GRID, (j + 1) * h / CB_MARK_GRID, b);
                }
            }
        }
    }
}

/* ---- Reference detector ------------------------------------------------- */

#define SCAN_THRESHOLD 30

typedef struct {
    int start, len, bright;
} run_t;

typedef struct {
    double x0, y0, lx, ly; /* tag origin and module size, image pixels */
    unsigned col, row, tag, seq;
} found_t;

static int runs_of(const uint8_t *px, size_t step, int n, run_t *runs)
{
    int count = 0;
    for (int i = 0; i < n;) {
        int b = px[(size_t)i * step] > SCAN_THRESHOLD;
        int j = i + 1;
        while (j < n && (px[(size_t)j * step] > SCAN_THRESHOLD) == b)
            j++;
        runs[count++] = (run_t){ i, j - i, b };
        i = j;
    }
    return count;
}

/* Runs k..k+4 are dark, bright, dark, bright, dark of one length, flanked by
 * bright runs at least half that long. Returns the module length or 0. */
static double five_runs(const run_t *r, int count, int k)
{
    if (k < 1 || k + 5 >= count || r[k].bright)
        return 0;
    double sum = 0;
    for (int i = 0; i < 5; i++) {
        if (r[k + i].bright != (i & 1))
            return 0;
        sum += r[k + i].len;
    }
    double l = sum / 5;
    if (l < 1.5)
        return 0;
    for (int i = 0; i < 5; i++)
        if (fabs(r[k + i].len - l) > 0.35 * l + 1)
            return 0;
    if (r[k - 1].len < 0.5 * l || r[k + 5].len < 0.5 * l)
        return 0;
    return l;
}

static double sample(const uint8_t *g, unsigned w, unsigned h, size_t stride, double cx,
                     double cy, double rx, double ry)
{
    int x0 = (int)floor(cx - rx), x1 = (int)floor(cx + rx);
    int y0 = (int)floor(cy - ry), y1 = (int)floor(cy + ry);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= (int)w) x1 = (int)w - 1;
    if (y1 >= (int)h) y1 = (int)h - 1;
    if (x1 < x0 || y1 < y0)
        return -1;
    double sum = 0;
    int n = 0;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++, n++)
            sum += g[(size_t)y * stride + (size_t)x];
    return sum / n;
}

static int read_tag(const uint8_t *g, unsigned w, unsigned h, size_t stride, double x0,
                    double y0, double lx, double ly, found_t *out)
{
    if (x0 < -0.5 || y0 < -0.5 || x0 + 7 * lx > w + 0.5 || y0 + 7 * ly > h + 0.5)
        return 0;
    double v[7][7], bright = 0, dark = 0;
    int nb = 0, nd = 0;
    for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
            v[y][x] = sample(g, w, h, stride, x0 + (x + 0.5) * lx, y0 + (y + 0.5) * ly,
                             lx / 5, ly / 5);
            if (v[y][x] < 0)
                return 0;
            if (x == 0 || y == 0 || x == 6 || y == 6) {
                if (((x + y) & 1) == 0)
                    bright += v[y][x], nb++;
                else
                    dark += v[y][x], nd++;
            }
        }
    }
    bright /= nb;
    dark /= nd;
    if (bright - dark < 12)
        return 0;
    double t = (bright + dark) / 2;
    uint32_t payload = 0;
    for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
            int b = v[y][x] > t;
            if (x == 0 || y == 0 || x == 6 || y == 6) {
                if (b != (((x + y) & 1) == 0))
                    return 0;
            } else if (b) {
                payload |= 1u << ((y - 1) * 5 + (x - 1));
            }
        }
    }
    uint32_t data = payload & 0x3ffff;
    if (cb_mark_crc7(data) != payload >> 18)
        return 0;
    *out = (found_t){ x0, y0, lx, ly, data & 7, (data >> 3) & 7, (data >> 6) & 63, (data >> 12) & 63 };
    return 1;
}

static int known(const found_t *f, int n, double x, double y)
{
    for (int i = 0; i < n; i++)
        if (x > f[i].x0 - f[i].lx && x < f[i].x0 + 7 * f[i].lx && y >= f[i].y0 - f[i].ly &&
            y < f[i].y0 + 7 * f[i].ly)
            return 1;
    return 0;
}

/* Least-squares fit of pos = origin + idx * span over the found tags. */
static void fit(const double *pos, const double *idx, const double *len, int n, double *origin,
                double *module)
{
    double si = 0, sp = 0, sii = 0, sip = 0, sl = 0;
    for (int i = 0; i < n; i++) {
        si += idx[i];
        sp += pos[i];
        sii += idx[i] * idx[i];
        sip += idx[i] * pos[i];
        sl += len[i];
    }
    double den = n * sii - si * si;
    if (n >= 2 && den > 1e-9) {
        double slope = (n * sip - si * sp) / den;
        *module = slope / CB_MARK_MODS;
        *origin = (sp - slope * si) / n;
    } else {
        *module = sl / n;
        *origin = (sp - si * CB_MARK_MODS * *module) / n;
    }
}

static int pixel_matches(const uint8_t *g, size_t stride, int x, int y, const cb_mark_hit *hit,
                         double t, int horizontal)
{
    double mx = hit->w / CB_MARK_GRID, my = hit->h / CB_MARK_GRID;
    int b = g[(size_t)y * stride + (size_t)x] > t;
    for (int d = -1; d <= 1; d++) {
        double fx = (x + 0.5 + (horizontal ? d : 0) - hit->x) / mx;
        double fy = (y + 0.5 + (horizontal ? 0 : d) - hit->y) / my;
        if (fx < 0 || fy < 0 || fx >= CB_MARK_GRID || fy >= CB_MARK_GRID)
            continue;
        if (cb_mark_module((unsigned)fx, (unsigned)fy, hit->tag, hit->seq) == b)
            return 1;
    }
    return 0;
}

/* Fraction of sample points along a pixel column (or row) that match the marker. */
static double line_match(const uint8_t *g, size_t stride, const cb_mark_hit *hit, int pos,
                         int vertical_line, int from, int to, double t)
{
    double m = vertical_line ? hit->h / CB_MARK_GRID : hit->w / CB_MARK_GRID;
    double origin = vertical_line ? hit->y : hit->x;
    int good = 0, total = 0;
    for (double c = origin + m / 2; c < origin + CB_MARK_GRID * m; c += m) {
        int p = (int)c;
        if (p < from || p >= to)
            continue;
        int x = vertical_line ? pos : p, y = vertical_line ? p : pos;
        good += pixel_matches(g, stride, x, y, hit, t, vertical_line);
        total++;
    }
    return total ? (double)good / total : 0;
}

static void find_clip(const uint8_t *g, unsigned w, unsigned h, size_t stride, cb_mark_hit *hit,
                      const found_t *f, int n)
{
    int x0 = (int)w, y0 = (int)h, x1 = 0, y1 = 0;
    for (int i = 0; i < n; i++) {
        if (f[i].x0 < x0) x0 = (int)ceil(f[i].x0);
        if (f[i].y0 < y0) y0 = (int)ceil(f[i].y0);
        if (f[i].x0 + 7 * f[i].lx > x1) x1 = (int)floor(f[i].x0 + 7 * f[i].lx);
        if (f[i].y0 + 7 * f[i].ly > y1) y1 = (int)floor(f[i].y0 + 7 * f[i].ly);
    }
    double t = SCAN_THRESHOLD;
    int lx = (int)fmax(0, ceil(hit->x)), rx = (int)fmin(w, floor(hit->x + hit->w));
    int ty = (int)fmax(0, ceil(hit->y)), by = (int)fmin(h, floor(hit->y + hit->h));
    while (x0 > lx && line_match(g, stride, hit, x0 - 1, 1, y0, y1, t) >= 0.9) x0--;
    while (x1 < rx && line_match(g, stride, hit, x1, 1, y0, y1, t) >= 0.9) x1++;
    while (y0 > ty && line_match(g, stride, hit, y0 - 1, 0, x0, x1, t) >= 0.9) y0--;
    while (y1 < by && line_match(g, stride, hit, y1, 0, x0, x1, t) >= 0.9) y1++;
    hit->clip_x0 = x0;
    hit->clip_y0 = y0;
    hit->clip_x1 = x1;
    hit->clip_y1 = y1;
}

size_t cb_mark_detect(const uint8_t *grey, size_t width_, size_t height_, size_t stride,
                      cb_mark_hit *hits, size_t max_hits)
{
    if (width_ > (1u << 16) || height_ > (1u << 16))
        return 0;
    unsigned width = (unsigned)width_, height = (unsigned)height_;
    unsigned longest = width > height ? width : height;
    run_t *rr = malloc(sizeof(run_t) * (width + 1));
    run_t *cr = malloc(sizeof(run_t) * (height + 1));
    int cap = 1024, n = 0;
    found_t *found = malloc(sizeof(found_t) * (size_t)cap);
    if (!rr || !cr || !found || !longest)
        goto out;
    for (unsigned y = 0; y < height; y++) {
        int nr = runs_of(grey + (size_t)y * stride, 1, (int)width, rr);
        for (int k = 1; k + 5 < nr; k++) {
            double lx = five_runs(rr, nr, k);
            if (!lx)
                continue;
            double x0 = rr[k].start - lx;
            if (known(found, n, x0 + 3.5 * lx, y))
                continue;
            if (n == cap) {
                found_t *more = realloc(found, sizeof(found_t) * (size_t)cap * 2);
                if (!more)
                    goto out;
                found = more;
                cap *= 2;
            }
            int xc = (int)(x0 + 0.5 * lx);
            if (xc < 0 || xc >= (int)width)
                continue;
            int nc = runs_of(grey + xc, stride, (int)height, cr);
            int at = 0;
            while (at + 1 < nc && cr[at + 1].start <= (int)y)
                at++;
            for (int j = at - 6; j <= at + 1; j++) {
                double ly = five_runs(cr, nc, j);
                if (!ly)
                    continue;
                double y0 = cr[j].start - ly;
                if (y < y0 || y >= y0 + 7 * ly)
                    continue;
                found_t f;
                if (read_tag(grey, width, height, stride, x0, y0, lx, ly, &f)) {
                    found[n++] = f;
                    break;
                }
            }
        }
    }
out:;
    /* Group tags into frames: same stream tag and the same implied frame
     * rectangle (one video can be on screen more than once, e.g. mirrored). */
    size_t nh = 0;
    int *group = n ? malloc(sizeof(int) * (size_t)n) : NULL;
    found_t *g = n ? malloc(sizeof(found_t) * (size_t)n) : NULL;
    double *px = n ? malloc(sizeof(double) * (size_t)n * 6) : NULL;
    if (n && (!group || !g || !px))
        n = 0;
    for (int i = 0; i < n; i++)
        group[i] = -1;
    for (int i = 0; i < n && nh < max_hits; i++) {
        if (group[i] >= 0)
            continue;
        double fx = found[i].x0 - found[i].col * 7.0 * found[i].lx, fy = found[i].y0 - found[i].row * 7.0 * found[i].ly;
        int m = 0;
        unsigned votes[64] = { 0 };
        for (int k = i; k < n; k++) {
            if (group[k] >= 0 || found[k].tag != found[i].tag)
                continue;
            double kx = found[k].x0 - found[k].col * 7.0 * found[k].lx, ky = found[k].y0 - found[k].row * 7.0 * found[k].ly;
            /* Per-tag estimates drift by a module or two across the frame; two
             * copies of one frame never overlap by more than a quarter. */
            if (fabs(kx - fx) > 14 * found[i].lx || fabs(ky - fy) > 14 * found[i].ly ||
                fabs(found[k].lx - found[i].lx) > 0.25 * found[i].lx || fabs(found[k].ly - found[i].ly) > 0.25 * found[i].ly)
                continue;
            group[k] = (int)nh;
            g[m++] = found[k];
            votes[found[k].seq]++;
        }
        double *ix = px, *iy = px + m, *xs = px + 2 * m, *ys = px + 3 * m, *lxs = px + 4 * m,
               *lys = px + 5 * m;
        for (int k = 0; k < m; k++) {
            ix[k] = g[k].col;
            iy[k] = g[k].row;
            xs[k] = g[k].x0;
            ys[k] = g[k].y0;
            lxs[k] = g[k].lx;
            lys[k] = g[k].ly;
        }
        double ox, oy, mx, my;
        fit(xs, ix, lxs, m, &ox, &mx);
        fit(ys, iy, lys, m, &oy, &my);
        unsigned seq = 0;
        for (unsigned v = 1; v < 64; v++)
            if (votes[v] > votes[seq])
                seq = v;
        cb_mark_hit *hit = &hits[nh++];
        *hit = (cb_mark_hit){ found[i].tag, seq, (unsigned)m, ox, oy, mx * CB_MARK_GRID,
                              my * CB_MARK_GRID, 0, 0, 0, 0 };
        find_clip(grey, width, height, stride, hit, g, m);
    }
    free(group);
    free(g);
    free(px);
    free(rr);
    free(cr);
    free(found);
    return nh;
}
