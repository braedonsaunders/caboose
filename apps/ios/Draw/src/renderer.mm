// CabooseDraw: Caboose draw lists (docs/draw.md) drawn with Skia's Ganesh backend on Metal.
// Each op maps to one Skia call, as cairo would draw it; guest/draw/src/cdl_replay.c is the
// same reader drawing with cairo, and the reference this renderer is checked against.

#import <Metal/Metal.h>

#include "CabooseDraw.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkShader.h"
#include "include/core/SkSurface.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/effects/SkGradient.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkImageGanesh.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include "include/gpu/ganesh/mtl/GrMtlTypes.h"

#include <cmath>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>

namespace {

enum : uint8_t {
    kSurface = 0x01, kFree = 0x02, kTarget = 0x03, kClip = 0x04, kFill = 0x05, kStroke = 0x06, kPaintOp = 0x07,
    kMask = 0x08, kGlyphs = 0x09, kUnsupported = 0x0A, kImage = 0x20, kGlyph = 0x21,
};

// A reader over one op's payload; any read past the end marks it bad.
struct Reader {
    const uint8_t *p, *end;
    bool bad = false;
    bool have(size_t n) {
        if ((size_t)(end - p) < n) {
            bad = true;
            p = end;
            return false;
        }
        return true;
    }
    uint8_t u8() { return have(1) ? *p++ : 0; }
    uint32_t u32() {
        if (!have(4)) return 0;
        uint32_t v = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        p += 4;
        return v;
    }
    uint64_t u64() {
        uint64_t lo = u32();
        return lo | (uint64_t)u32() << 32;
    }
    float f32() {
        uint32_t u = u32();
        float f;
        std::memcpy(&f, &u, 4);
        return f;
    }
    SkMatrix matrix() {
        float xx = f32(), yx = f32(), xy = f32(), yy = f32(), x0 = f32(), y0 = f32();
        return SkMatrix::MakeAll(xx, xy, x0, yx, yy, y0, 0, 0, 1);
    }
    // A path, each point through `m` when given.
    SkPath path(const SkMatrix *m = nullptr) {
        uint32_t nverbs = u32(), npoints = u32();
        SkPathBuilder b;
        if (bad || !have(nverbs) || (size_t)(end - p - nverbs) < (size_t)npoints * 8) {
            bad = true;
            return b.detach();
        }
        const uint8_t *verbs = p;
        p += nverbs;
        Reader pts{p, p + (size_t)npoints * 8};
        p += (size_t)npoints * 8;
        auto point = [&] {
            SkPoint q{pts.f32(), pts.f32()};
            return m ? m->mapPoint(q) : q;
        };
        for (uint32_t i = 0; i < nverbs; i++) {
            switch (verbs[i]) {
            case 0: b.moveTo(point()); break;
            case 1: b.lineTo(point()); break;
            case 2: { SkPoint a = point(), c = point(); b.quadTo(a, c); break; }
            case 3: { SkPoint a = point(), c = point(), d = point(); b.cubicTo(a, c, d); break; }
            case 4: b.close(); break;
            default: bad = true; return b.detach();
            }
        }
        return b.detach();
    }
};

SkBlendMode blend(uint8_t cairo) {
    static const SkBlendMode modes[] = {
        SkBlendMode::kClear,     SkBlendMode::kSrc,        SkBlendMode::kSrcOver,    SkBlendMode::kSrcIn,
        SkBlendMode::kSrcOut,    SkBlendMode::kSrcATop,    SkBlendMode::kDst,        SkBlendMode::kDstOver,
        SkBlendMode::kDstIn,     SkBlendMode::kDstOut,     SkBlendMode::kDstATop,    SkBlendMode::kXor,
        SkBlendMode::kPlus,      SkBlendMode::kPlus /* saturate */, SkBlendMode::kMultiply, SkBlendMode::kScreen,
        SkBlendMode::kOverlay,   SkBlendMode::kDarken,     SkBlendMode::kLighten,    SkBlendMode::kColorDodge,
        SkBlendMode::kColorBurn, SkBlendMode::kHardLight,  SkBlendMode::kSoftLight,  SkBlendMode::kDifference,
        SkBlendMode::kExclusion, SkBlendMode::kHue,        SkBlendMode::kSaturation, SkBlendMode::kColor,
        SkBlendMode::kLuminosity,
    };
    return cairo < sizeof modes / sizeof modes[0] ? modes[cairo] : SkBlendMode::kSrcOver;
}

// cairo's extend for gradients and surfaces: none, repeat, reflect, pad.
SkTileMode tile(uint8_t extend) {
    switch (extend) {
    case 1: return SkTileMode::kRepeat;
    case 2: return SkTileMode::kMirror;
    case 3: return SkTileMode::kClamp;
    default: return SkTileMode::kDecal;
    }
}

struct Surface {
    id<MTLTexture> texture = nil;
    sk_sp<SkSurface> surface;
    float scale = 1;
};

struct Stream {
    std::vector<uint8_t> pending;
    std::unordered_map<uint32_t, Surface> surfaces;
    std::unordered_map<uint64_t, sk_sp<SkImage>> images;
    std::unordered_map<uint64_t, SkPath> glyphs; // by (font, glyph) key
    uint32_t target = 0;
    std::vector<uint8_t> clip; // the current CLIP op's payload
};

uint64_t rotl(uint64_t x, int r) { return (x << r) | (x >> (64 - r)); }

// XXH64 of the 8 bytes of `font` with seed `glyph`: the key docs/draw.md gives glyphs.
uint64_t glyph_key(uint64_t font, uint32_t glyph) {
    const uint64_t P1 = 11400714785074694791ULL, P2 = 14029467366897019727ULL, P3 = 1609587929392839161ULL,
                   P4 = 9650029242287828579ULL, P5 = 2870177450012600261ULL;
    uint64_t h = (uint64_t)glyph + P5 + 8;
    h ^= rotl(font * P2, 31) * P1;
    h = rotl(h, 27) * P1 + P4;
    h ^= h >> 33;
    h *= P2;
    h ^= h >> 29;
    h *= P3;
    h ^= h >> 32;
    return h;
}

}  // namespace

struct CabooseDrawRenderer {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    sk_sp<GrDirectContext> context;
    float scale = 1;
    std::unordered_map<uint32_t, Stream> streams;
    uint64_t drawn = 0, skipped = 0, dropped = 0;

    SkCanvas *canvas(Stream &s, Surface **out = nullptr) {
        auto it = s.surfaces.find(s.target);
        if (it == s.surfaces.end() || !it->second.surface) return nullptr;
        if (out) *out = &it->second;
        return it->second.surface->getCanvas();
    }

    bool make_surface(Surface &surface, uint32_t w, uint32_t h) {
        int pw = std::max(1, (int)std::ceil(w * scale)), ph = std::max(1, (int)std::ceil(h * scale));
        if (pw > 16384 || ph > 16384) return false;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:pw
                                                                                   height:ph
                                                                                mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:d];
        if (!texture) return false;
        GrMtlTextureInfo info;
        info.fTexture.retain((__bridge GrMTLHandle)texture);
        GrBackendTexture backend = GrBackendTextures::MakeMtl(pw, ph, skgpu::Mipmapped::kNo, info);
        sk_sp<SkSurface> sk = SkSurfaces::WrapBackendTexture(context.get(), backend, kTopLeft_GrSurfaceOrigin, 1,
                                                             kBGRA_8888_SkColorType, nullptr, nullptr, nullptr, nullptr);
        if (!sk) return false;
        sk->getCanvas()->clear(SK_ColorTRANSPARENT);
        surface.texture = texture;
        surface.surface = std::move(sk);
        surface.scale = scale;
        return true;
    }

    // A source as a shader; null for something the stream does not have.
    sk_sp<SkShader> shader(Reader &r, Stream &s, SkColor4f *solid) {
        uint8_t kind = r.u8();
        if (kind == 0) {
            float c[4] = {r.f32(), r.f32(), r.f32(), r.f32()};
            *solid = {c[0], c[1], c[2], c[3]};
            return nullptr;
        }
        *solid = {0, 0, 0, 1};
        if (kind == 1 || kind == 2) {
            float v[6] = {};
            for (int i = 0; i < (kind == 1 ? 4 : 6); i++) v[i] = r.f32();
            SkTileMode mode = tile(r.u8());
            SkMatrix m = r.matrix(), local;
            uint32_t n = r.u32();
            if (r.bad || n > 4096) return nullptr;
            std::vector<SkColor4f> colors(n);
            std::vector<float> positions(n);
            for (uint32_t i = 0; i < n; i++) {
                positions[i] = r.f32();
                colors[i] = {r.f32(), r.f32(), r.f32(), r.f32()};
            }
            if (r.bad || n == 0 || !m.invert(&local)) return nullptr;
            SkGradient gradient(SkGradient::Colors({colors.data(), n}, {positions.data(), n}, mode),
                                SkGradient::Interpolation());
            if (kind == 1) {
                SkPoint pts[2] = {{v[0], v[1]}, {v[2], v[3]}};
                return SkShaders::LinearGradient(pts, gradient, &local);
            }
            return SkShaders::TwoPointConicalGradient({v[0], v[1]}, v[2], {v[3], v[4]}, v[5], gradient, &local);
        }
        if (kind == 3 || kind == 4) {
            sk_sp<SkImage> image;
            float image_scale = 1;
            if (kind == 3) {
                auto it = s.surfaces.find(r.u32());
                if (it != s.surfaces.end() && it->second.surface) {
                    image = it->second.surface->makeImageSnapshot();
                    image_scale = it->second.scale;
                }
            } else {
                auto it = s.images.find(r.u64());
                if (it != s.images.end()) image = it->second;
            }
            SkTileMode mode = tile(r.u8());
            uint8_t filter = r.u8();
            SkMatrix m = r.matrix(), inverse;
            if (!image || r.bad || !m.invert(&inverse)) return nullptr;
            // The source matrix maps user space to the source's pixels; a surface drawn at
            // `image_scale` has that many texture pixels per source pixel.
            SkMatrix local = SkMatrix::Concat(inverse, SkMatrix::Scale(1 / image_scale, 1 / image_scale));
            SkSamplingOptions sampling(filter == 0 || filter == 3 ? SkFilterMode::kNearest : SkFilterMode::kLinear);
            return image->makeShader(mode, mode, sampling, &local);
        }
        r.bad = true;
        return nullptr;
    }

    // Applies the stream's current clip to `c`, in the target's pixels.
    void apply_clip(Stream &s, SkCanvas *c, float target_scale) {
        Reader r{s.clip.data(), s.clip.data() + s.clip.size()};
        uint32_t n = s.clip.empty() ? 0 : r.u32();
        for (uint32_t i = 0; i < n && !r.bad; i++) {
            c->setMatrix(SkMatrix::Scale(target_scale, target_scale));
            if (r.u8() == 0) {
                float x = r.f32(), y = r.f32(), w = r.f32(), h = r.f32();
                c->clipRect(SkRect::MakeXYWH(x, y, w, h), true);
            } else {
                SkMatrix m = r.matrix();
                uint8_t rule = r.u8(), aa = r.u8();
                SkPath p = r.path(&m);
                p.setFillType(rule ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding);
                c->clipPath(p, aa != 1);
            }
        }
    }

    // Draws one op; false when it names what the stream does not have or is malformed.
    bool draw(Stream &s, uint8_t op, Reader &r) {
        switch (op) {
        case kSurface: {
            uint32_t id = r.u32(), w = r.u32(), h = r.u32();
            r.u8();
            if (r.bad) return false;
            Surface &surface = s.surfaces[id];
            return surface.surface || make_surface(surface, w, h);
        }
        case kFree:
            s.surfaces.erase(r.u32());
            return !r.bad;
        case kTarget:
            s.target = r.u32();
            s.clip.clear();
            return !r.bad;
        case kClip:
            s.clip.assign(r.p, r.end);
            r.p = r.end;
            return true;
        case kImage: {
            uint64_t hash = r.u64();
            uint32_t w = r.u32(), h = r.u32();
            r.u8();
            if (r.bad || !r.have((size_t)w * h * 4)) return false;
            SkPixmap pixmap(SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType), r.p, (size_t)w * 4);
            sk_sp<SkImage> raster = SkImages::RasterFromPixmapCopy(pixmap);
            r.p += (size_t)w * h * 4;
            sk_sp<SkImage> gpu = raster ? SkImages::TextureFromImage(context.get(), raster) : nullptr;
            s.images[hash] = gpu ? gpu : raster;
            return true;
        }
        case kGlyph: {
            uint64_t font = r.u64();
            uint32_t glyph = r.u32();
            SkPath path = r.path();
            if (r.bad) return false;
            s.glyphs[glyph_key(font, glyph)] = path;
            return true;
        }
        case kFill: case kStroke: case kPaintOp: case kMask: case kGlyphs:
            break;
        case kUnsupported: case 0x30: case 0x31: case 0x32:
            return true;  // regions drawn without a record, frame markers: nothing to draw
        default:
            return false;
        }
        Surface *target = nullptr;
        SkCanvas *c = canvas(s, &target);
        uint8_t operation = r.u8();
        SkPaint paint;
        paint.setBlendMode(blend(operation));
        paint.setAntiAlias(true);
        uint8_t rule = 0;
        float alpha = 1;
        if (op == kFill) {
            rule = r.u8();
            paint.setAntiAlias(r.u8() != 1);
        } else if (op == kStroke) {
            paint.setAntiAlias(r.u8() != 1);
        } else if (op == kPaintOp) {
            alpha = r.f32();
        }
        SkMatrix m = r.matrix();
        if (op == kStroke) {
            paint.setStyle(SkPaint::kStroke_Style);
            paint.setStrokeWidth(r.f32());
            uint8_t cap = r.u8(), join = r.u8();
            paint.setStrokeCap(cap == 1 ? SkPaint::kRound_Cap : cap == 2 ? SkPaint::kSquare_Cap : SkPaint::kButt_Cap);
            paint.setStrokeJoin(join == 1 ? SkPaint::kRound_Join : join == 2 ? SkPaint::kBevel_Join : SkPaint::kMiter_Join);
            paint.setStrokeMiter(r.f32());
            uint32_t ndash = r.u32();
            float offset = r.f32();
            if (ndash > 1024) return false;
            std::vector<float> dashes;
            for (uint32_t i = 0; i < ndash; i++) dashes.push_back(r.f32());
            if (ndash % 2) dashes.insert(dashes.end(), dashes.begin(), dashes.end());  // cairo repeats an odd list
            if (!dashes.empty()) paint.setPathEffect(SkDashPathEffect::Make({dashes.data(), dashes.size()}, offset));
        }
        SkMatrix font_matrix;
        uint64_t font = 0;
        if (op == kGlyphs) {
            font_matrix = r.matrix();
            font = r.u64();
        }
        SkColor4f solid;
        sk_sp<SkShader> source = shader(r, s, &solid);
        SkColor4f mask_solid;
        sk_sp<SkShader> mask = op == kMask ? shader(r, s, &mask_solid) : nullptr;
        SkPath path;
        if (op == kFill || op == kStroke) path = r.path();
        if (op == kGlyphs) {
            uint32_t n = r.u32();
            SkPathBuilder glyphs;
            for (uint32_t i = 0; i < n && !r.bad; i++) {
                uint32_t g = r.u32();
                float x = r.f32(), y = r.f32();
                auto it = s.glyphs.find(glyph_key(font, g));
                if (it == s.glyphs.end()) continue;
                SkMatrix gm = font_matrix;
                gm.postTranslate(x, y);
                glyphs.addPath(it->second, gm);
            }
            path = glyphs.detach();
        }
        if (r.bad || !c) return false;
        if (source) paint.setShader(source); else paint.setColor4f(solid);
        if (op == kFill) path.setFillType(rule ? SkPathFillType::kEvenOdd : SkPathFillType::kWinding);

        c->save();
        apply_clip(s, c, target->scale);
        c->setMatrix(SkMatrix::Concat(SkMatrix::Scale(target->scale, target->scale), m));
        switch (op) {
        case kFill: case kStroke: case kGlyphs:
            c->drawPath(path, paint);
            break;
        case kPaintOp:
            paint.setAlphaf(paint.getAlphaf() * alpha);
            c->drawPaint(paint);
            break;
        case kMask: {
            // cairo's mask: the source, its alpha multiplied by the mask's, composited with the
            // op's operator.
            SkPaint layer;
            layer.setBlendMode(blend(operation));
            c->saveLayer(nullptr, &layer);
            SkPaint src = paint;
            src.setBlendMode(SkBlendMode::kSrc);
            c->drawPaint(src);
            SkPaint in;
            in.setBlendMode(SkBlendMode::kDstIn);
            if (mask) in.setShader(mask); else in.setColor4f(mask_solid);
            c->drawPaint(in);
            c->restore();
            break;
        }
        }
        c->restore();
        return true;
    }

    int feed(uint32_t id, const uint8_t *bytes, size_t length) {
        Stream &s = streams[id];
        s.pending.insert(s.pending.end(), bytes, bytes + length);
        size_t at = 0;
        while (s.pending.size() - at >= 5) {
            const uint8_t *op = s.pending.data() + at;
            uint32_t len = (uint32_t)op[1] | (uint32_t)op[2] << 8 | (uint32_t)op[3] << 16 | (uint32_t)op[4] << 24;
            if (len > (64u << 20)) {
                dropped++;
                streams.erase(id);
                return -1;
            }
            if (s.pending.size() - at < 5 + (size_t)len) break;
            Reader r{op + 5, op + 5 + len};
            if (draw(s, op[0], r) && !r.bad) {
                drawn++;
            } else {
                skipped++;
            }
            at += 5 + len;
        }
        s.pending.erase(s.pending.begin(), s.pending.begin() + (long)at);
        return 0;
    }
};

extern "C" {

CabooseDrawRenderer *caboose_draw_create(void *device, void *queue) {
    if (!device || !queue) return nullptr;
    GrMtlBackendContext backend;
    backend.fDevice.retain((GrMTLHandle)device);
    backend.fQueue.retain((GrMTLHandle)queue);
    sk_sp<GrDirectContext> context = GrDirectContexts::MakeMetal(backend);
    if (!context) return nullptr;
    auto *r = new CabooseDrawRenderer();
    r->device = (__bridge id<MTLDevice>)device;
    r->queue = (__bridge id<MTLCommandQueue>)queue;
    r->context = std::move(context);
    return r;
}

void caboose_draw_destroy(CabooseDrawRenderer *r) {
    if (!r) return;
    r->streams.clear();
    r->context->flushAndSubmit(GrSyncCpu::kYes);
    r->context.reset();
    delete r;
}

void caboose_draw_set_scale(CabooseDrawRenderer *r, float scale) {
    if (r && std::isfinite(scale) && scale > 0 && scale <= 8) r->scale = scale;
}

int caboose_draw_feed(CabooseDrawRenderer *r, uint32_t stream, const uint8_t *bytes, size_t length) {
    return r ? r->feed(stream, bytes, length) : -1;
}

void caboose_draw_end(CabooseDrawRenderer *r, uint32_t stream) {
    if (r) r->streams.erase(stream);
}

void *caboose_draw_texture(CabooseDrawRenderer *r, uint32_t stream, uint32_t surface, uint32_t *width,
                           uint32_t *height, float *scale) {
    if (!r) return nullptr;
    auto s = r->streams.find(stream);
    if (s == r->streams.end()) return nullptr;
    auto it = s->second.surfaces.find(surface);
    if (it == s->second.surfaces.end() || !it->second.texture) return nullptr;
    r->context->flushAndSubmit();
    if (width) *width = (uint32_t)it->second.texture.width;
    if (height) *height = (uint32_t)it->second.texture.height;
    if (scale) *scale = it->second.scale;
    return (__bridge void *)it->second.texture;
}

size_t caboose_draw_read(CabooseDrawRenderer *r, uint32_t stream, uint32_t surface, uint8_t *rgba, size_t capacity,
                         uint32_t *width, uint32_t *height) {
    if (!r) return 0;
    auto s = r->streams.find(stream);
    if (s == r->streams.end()) return 0;
    auto it = s->second.surfaces.find(surface);
    if (it == s->second.surfaces.end() || !it->second.surface) return 0;
    SkSurface *sk = it->second.surface.get();
    SkImageInfo info = SkImageInfo::Make(sk->width(), sk->height(), kRGBA_8888_SkColorType, kPremul_SkAlphaType);
    size_t need = (size_t)sk->width() * sk->height() * 4;
    if (capacity < need) return 0;
    r->context->flushAndSubmit(GrSyncCpu::kYes);
    if (!sk->readPixels(info, rgba, (size_t)sk->width() * 4, 0, 0)) return 0;
    if (width) *width = (uint32_t)sk->width();
    if (height) *height = (uint32_t)sk->height();
    return need;
}

void caboose_draw_stats(CabooseDrawRenderer *r, uint64_t *drawn, uint64_t *skipped, uint64_t *dropped) {
    if (!r) return;
    if (drawn) *drawn = r->drawn;
    if (skipped) *skipped = r->skipped;
    if (dropped) *dropped = r->dropped;
}

}  // extern "C"
