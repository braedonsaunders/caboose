/* cbva-detect: runs the reference marker detector (src/marker.c) over a
 * screenshot, PGM (P5) or PPM (P6), and prints what it finds:
 *   tag=3 seq=17 tags=58 rect=100.0,80.0,1280.0,720.0 clip=100,80,1380,800 */
#include "marker.h"

#include <stdio.h>
#include <stdlib.h>

static int read_int(FILE *f)
{
    int c, v = 0;
    while ((c = fgetc(f)) != EOF) {
        if (c == '#')
            while ((c = fgetc(f)) != EOF && c != '\n')
                ;
        else if (c >= '0' && c <= '9')
            break;
    }
    for (; c >= '0' && c <= '9'; c = fgetc(f))
        v = v * 10 + (c - '0');
    return v;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: cbva-detect IMAGE.pgm|IMAGE.ppm\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror(argv[1]);
        return 2;
    }
    char magic[2];
    if (fread(magic, 1, 2, f) != 2 || magic[0] != 'P' || (magic[1] != '5' && magic[1] != '6')) {
        fprintf(stderr, "not a binary PGM/PPM\n");
        return 2;
    }
    int ch = magic[1] == '6' ? 3 : 1;
    int w = read_int(f), h = read_int(f), max = read_int(f);
    if (w <= 0 || h <= 0 || max != 255)
        return 2;
    size_t n = (size_t)w * (size_t)h;
    uint8_t *px = malloc(n * (size_t)ch), *grey = malloc(n);
    if (!px || !grey || fread(px, 1, n * (size_t)ch, f) != n * (size_t)ch)
        return 2;
    for (size_t i = 0; i < n; i++)
        grey[i] = ch == 1 ? px[i]
                          : (uint8_t)((299 * px[3 * i] + 587 * px[3 * i + 1] + 114 * px[3 * i + 2]) / 1000);
    cb_mark_hit hits[16];
    int nh = (int)cb_mark_detect(grey, (unsigned)w, (unsigned)h, (size_t)w, hits, 16);
    for (int i = 0; i < nh; i++)
        printf("tag=%u seq=%u tags=%u rect=%.1f,%.1f,%.1f,%.1f clip=%d,%d,%d,%d\n", hits[i].tag, hits[i].seq,
               hits[i].tags_found, hits[i].x, hits[i].y, hits[i].w, hits[i].h, hits[i].clip_x0, hits[i].clip_y0,
               hits[i].clip_x1, hits[i].clip_y1);
    free(px);
    free(grey);
    fclose(f);
    return nh ? 0 : 1;
}
