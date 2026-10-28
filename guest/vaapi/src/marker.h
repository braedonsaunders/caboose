/* The placeholder marker: what a passthrough surface holds instead of decoded
 * pixels, and how the compositor finds it on screen.
 *
 * A marked surface is a grid of 8 x 8 tags over its whole coded area; each tag is
 * 7 x 7 modules, so the surface is 56 x 56 modules. Module (i, j) covers luma
 * columns [i*W/56, (i+1)*W/56) and rows [j*H/56, (j+1)*H/56) (integer division).
 * A module is dark (Y = 16) or bright (Y = 56), limited range, chroma neutral:
 * on screen it reads as black and dark grey whatever the colour conversion.
 *
 * In a tag, module (x, y), 0 <= x, y < 7:
 *   ring (x or y is 0 or 6): bright when x + y is even (a checkerboard border);
 *   interior: bit (y-1)*5 + (x-1) of the 25-bit payload, bright when set.
 * Payload bits 0-2: tag column, 3-5: tag row, 6-11: stream tag (the compositor
 * assigns it), 12-17: frame sequence number mod 64, 18-24: CRC-7 (x^7 + x^3 + 1,
 * zero init, over bits 17..0 MSB first).
 *
 * Because every tag carries its own position, a tag that survives scaling,
 * cropping and partial cover gives the whole frame's rectangle on screen, and
 * the sequence number names the exact frame the app is showing. See
 * docs/display.md, "Codec passthrough". */
#ifndef CABOOSE_VA_MARKER_H
#define CABOOSE_VA_MARKER_H

#include <stddef.h>
#include <stdint.h>

#define CB_MARK_TAGS 8
#define CB_MARK_MODS 7
#define CB_MARK_GRID (CB_MARK_TAGS * CB_MARK_MODS)
#define CB_MARK_DARK 16
#define CB_MARK_BRIGHT 56

uint8_t cb_mark_crc7(uint32_t data18);
uint32_t cb_mark_payload(unsigned col, unsigned row, unsigned tag, unsigned seq);
/* Whether grid module (i, j) of a frame marked (tag, seq) is bright. */
int cb_mark_module(unsigned i, unsigned j, unsigned tag, unsigned seq);

/* Paints a luma plane (1 byte per sample, or 2 for P010's MSB-aligned 16-bit
 * samples). With `prev` >= 0 (the (tag << 6 | seq) the plane holds now), only
 * the modules that differ are rewritten. */
void cb_mark_paint(uint8_t *luma, size_t pitch, unsigned w, unsigned h, unsigned bps,
                   unsigned tag, unsigned seq, int prev);

/* Reference detector over an 8-bit grey image (BT.601 luma of what is on screen).
 * The compositor implements the same algorithm on its window buffers. */
typedef struct {
    unsigned tag, seq;
    unsigned tags_found;
    /* The whole coded frame on screen (may extend past the image when cropped). */
    double x, y, w, h;
    /* The part of it that is visible, in image pixels. */
    int clip_x0, clip_y0, clip_x1, clip_y1;
} cb_mark_hit;

/* Finds marked frames in an 8-bit luma plane. Returns the number of hits written
 * (one per stream tag, at most max_hits). Thread-safe, no global state. */
size_t cb_mark_detect(const uint8_t *grey, size_t width, size_t height, size_t stride,
                      cb_mark_hit *hits, size_t max_hits);

#endif
