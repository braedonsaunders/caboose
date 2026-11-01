//! Caboose draw lists (docs/draw.md): 2D drawing recorded as commands, read here op by op.
//!
//! A stream is a sequence of `op: u8, len: u32 LE, payload[len]`. [`Reader`] yields each op
//! decoded into [`Op`], borrowing paths, glyph runs and pixels from the stream. An op this
//! reader does not know is [`Op::Unknown`]; a payload that does not fit its op is an error.

use std::fmt;

pub const SURFACE: u8 = 0x01;
pub const FREE: u8 = 0x02;
pub const TARGET: u8 = 0x03;
pub const CLIP: u8 = 0x04;
pub const FILL: u8 = 0x05;
pub const STROKE: u8 = 0x06;
pub const PAINT: u8 = 0x07;
pub const MASK: u8 = 0x08;
pub const GLYPHS: u8 = 0x09;
pub const UNSUPPORTED: u8 = 0x0A;
pub const IMAGE: u8 = 0x20;
pub const GLYPH: u8 = 0x21;
pub const PRESENT: u8 = 0x30;
pub const PIXELS: u8 = 0x31;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DrawError {
    pub op: u8,
    pub offset: usize,
}

impl fmt::Display for DrawError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "malformed draw op 0x{:02x} at byte {}", self.op, self.offset)
    }
}

impl std::error::Error for DrawError {}

/// cairo's six numbers: `x' = xx·x + xy·y + x0`, `y' = yx·x + yy·y + y0`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Matrix {
    pub xx: f32,
    pub yx: f32,
    pub xy: f32,
    pub yy: f32,
    pub x0: f32,
    pub y0: f32,
}

impl Matrix {
    pub const IDENTITY: Matrix = Matrix { xx: 1.0, yx: 0.0, xy: 0.0, yy: 1.0, x0: 0.0, y0: 0.0 };

    pub fn apply(&self, x: f32, y: f32) -> (f32, f32) {
        (self.xx * x + self.xy * y + self.x0, self.yx * x + self.yy * y + self.y0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verb {
    Move,
    Line,
    Quad,
    Cubic,
    Close,
}

impl Verb {
    fn from_u8(v: u8) -> Option<Verb> {
        Some(match v {
            0 => Verb::Move,
            1 => Verb::Line,
            2 => Verb::Quad,
            3 => Verb::Cubic,
            4 => Verb::Close,
            _ => return None,
        })
    }

    pub fn points(self) -> usize {
        match self {
            Verb::Move | Verb::Line => 1,
            Verb::Quad => 2,
            Verb::Cubic => 3,
            Verb::Close => 0,
        }
    }
}

/// A path borrowed from the stream: verbs and their points, `(x, y)` pairs of `f32`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Path<'a> {
    verbs: &'a [u8],
    points: &'a [u8],
}

impl<'a> Path<'a> {
    pub fn len(&self) -> usize {
        self.verbs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.verbs.is_empty()
    }

    /// Each verb with its points.
    pub fn segments(&self) -> impl Iterator<Item = (Verb, [(f32, f32); 3])> + 'a {
        let points = self.points;
        let mut at = 0usize;
        self.verbs.iter().map(move |&v| {
            let verb = Verb::from_u8(v).unwrap_or(Verb::Close);
            let mut p = [(0.0, 0.0); 3];
            for slot in p.iter_mut().take(verb.points()) {
                *slot = (f32_at(points, at), f32_at(points, at + 4));
                at += 8;
            }
            (verb, p)
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stop {
    pub offset: f32,
    pub rgba: [f32; 4],
}

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    Solid([f32; 4]),
    Linear { points: [f32; 4], extend: u8, matrix: Matrix, stops: Vec<Stop> },
    Radial { circles: [f32; 6], extend: u8, matrix: Matrix, stops: Vec<Stop> },
    Surface { surface: u32, extend: u8, filter: u8, matrix: Matrix },
    Image { image: u64, extend: u8, filter: u8, matrix: Matrix },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClipItem<'a> {
    Rect([f32; 4]),
    Path { matrix: Matrix, rule: u8, antialias: u8, path: Path<'a> },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Stroke {
    pub width: f32,
    pub cap: u8,
    pub join: u8,
    pub miter: f32,
    pub dash_offset: f32,
    pub dashes: Vec<f32>,
}

/// A glyph run's records: `(glyph: u32, x: f32, y: f32)`, 12 bytes each.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glyphs<'a>(&'a [u8]);

impl<'a> Glyphs<'a> {
    pub fn len(&self) -> usize {
        self.0.len() / 12
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = (u32, f32, f32)> + 'a {
        self.0.chunks_exact(12).map(|g| (u32_at(g, 0), f32_at(g, 4), f32_at(g, 8)))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Op<'a> {
    Surface { id: u32, w: u32, h: u32, window: bool },
    Free { id: u32 },
    Target { id: u32 },
    Clip(Vec<ClipItem<'a>>),
    Fill { operator: u8, rule: u8, antialias: u8, matrix: Matrix, source: Source, path: Path<'a> },
    Stroke { operator: u8, antialias: u8, matrix: Matrix, stroke: Stroke, source: Source, path: Path<'a> },
    Paint { operator: u8, alpha: f32, matrix: Matrix, source: Source },
    Mask { operator: u8, matrix: Matrix, source: Source, mask: Source },
    Glyphs { operator: u8, matrix: Matrix, font_matrix: Matrix, font: u64, source: Source, glyphs: Glyphs<'a> },
    Unsupported { reason: u32, rect: [f32; 4] },
    Image { hash: u64, w: u32, h: u32, format: u8, pixels: &'a [u8] },
    Glyph { font: u64, glyph: u32, path: Path<'a> },
    Present { surface: u32, wl_surface: u32 },
    Pixels { surface: u32, w: u32, h: u32, rgba: &'a [u8] },
    Unknown { op: u8, payload: &'a [u8] },
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn f32_at(b: &[u8], at: usize) -> f32 {
    f32::from_bits(u32_at(b, at))
}

/// The key of a glyph's outline: `XXH64(font as 8 bytes LE, seed = glyph)`.
pub fn glyph_key(font: u64, glyph: u32) -> u64 {
    crate::atlas::xxh64(&font.to_le_bytes(), glyph as u64)
}

struct Cursor<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(n)?;
        let s = self.b.get(self.at..end)?;
        self.at = end;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|s| s[0])
    }
    fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|s| u32_at(s, 0))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(self.u32()? as u64 | (self.u32()? as u64) << 32)
    }
    fn f32(&mut self) -> Option<f32> {
        self.u32().map(f32::from_bits)
    }
    fn f32s<const N: usize>(&mut self) -> Option<[f32; N]> {
        let mut v = [0.0; N];
        for x in v.iter_mut() {
            *x = self.f32()?;
        }
        Some(v)
    }
    fn matrix(&mut self) -> Option<Matrix> {
        let [xx, yx, xy, yy, x0, y0] = self.f32s::<6>()?;
        Some(Matrix { xx, yx, xy, yy, x0, y0 })
    }
    fn path(&mut self) -> Option<Path<'a>> {
        let nverbs = self.u32()? as usize;
        let npoints = self.u32()? as usize;
        let verbs = self.take(nverbs)?;
        let points = self.take(npoints.checked_mul(8)?)?;
        let mut needed = 0usize;
        for &v in verbs {
            needed += Verb::from_u8(v)?.points();
        }
        (needed == npoints).then_some(Path { verbs, points })
    }
    fn stops(&mut self) -> Option<Vec<Stop>> {
        let n = self.u32()? as usize;
        if n > self.b.len() / 20 {
            return None;
        }
        (0..n)
            .map(|_| {
                let [offset, r, g, b, a] = self.f32s::<5>()?;
                Some(Stop { offset, rgba: [r, g, b, a] })
            })
            .collect()
    }
    fn source(&mut self) -> Option<Source> {
        Some(match self.u8()? {
            0 => Source::Solid(self.f32s::<4>()?),
            1 => Source::Linear { points: self.f32s::<4>()?, extend: self.u8()?, matrix: self.matrix()?, stops: self.stops()? },
            2 => Source::Radial { circles: self.f32s::<6>()?, extend: self.u8()?, matrix: self.matrix()?, stops: self.stops()? },
            3 => Source::Surface { surface: self.u32()?, extend: self.u8()?, filter: self.u8()?, matrix: self.matrix()? },
            4 => Source::Image { image: self.u64()?, extend: self.u8()?, filter: self.u8()?, matrix: self.matrix()? },
            _ => return None,
        })
    }
    fn done(&self) -> bool {
        self.at == self.b.len()
    }
}

fn decode(op: u8, payload: &[u8]) -> Option<Op<'_>> {
    let mut c = Cursor { b: payload, at: 0 };
    let op = match op {
        SURFACE => Op::Surface { id: c.u32()?, w: c.u32()?, h: c.u32()?, window: c.u8()? == 1 },
        FREE => Op::Free { id: c.u32()? },
        TARGET => Op::Target { id: c.u32()? },
        CLIP => {
            let n = c.u32()? as usize;
            if n > payload.len() {
                return None;
            }
            let mut items = Vec::with_capacity(n);
            for _ in 0..n {
                items.push(match c.u8()? {
                    0 => ClipItem::Rect(c.f32s::<4>()?),
                    1 => ClipItem::Path { matrix: c.matrix()?, rule: c.u8()?, antialias: c.u8()?, path: c.path()? },
                    _ => return None,
                });
            }
            Op::Clip(items)
        }
        FILL => Op::Fill {
            operator: c.u8()?,
            rule: c.u8()?,
            antialias: c.u8()?,
            matrix: c.matrix()?,
            source: c.source()?,
            path: c.path()?,
        },
        STROKE => {
            let operator = c.u8()?;
            let antialias = c.u8()?;
            let matrix = c.matrix()?;
            let width = c.f32()?;
            let cap = c.u8()?;
            let join = c.u8()?;
            let miter = c.f32()?;
            let ndash = c.u32()? as usize;
            let dash_offset = c.f32()?;
            if ndash > payload.len() / 4 {
                return None;
            }
            let dashes = (0..ndash).map(|_| c.f32()).collect::<Option<Vec<_>>>()?;
            Op::Stroke {
                operator,
                antialias,
                matrix,
                stroke: Stroke { width, cap, join, miter, dash_offset, dashes },
                source: c.source()?,
                path: c.path()?,
            }
        }
        PAINT => Op::Paint { operator: c.u8()?, alpha: c.f32()?, matrix: c.matrix()?, source: c.source()? },
        MASK => Op::Mask { operator: c.u8()?, matrix: c.matrix()?, source: c.source()?, mask: c.source()? },
        GLYPHS => {
            let operator = c.u8()?;
            let matrix = c.matrix()?;
            let font_matrix = c.matrix()?;
            let font = c.u64()?;
            let source = c.source()?;
            let n = c.u32()? as usize;
            let glyphs = Glyphs(c.take(n.checked_mul(12)?)?);
            Op::Glyphs { operator, matrix, font_matrix, font, source, glyphs }
        }
        UNSUPPORTED => Op::Unsupported { reason: c.u32()?, rect: c.f32s::<4>()? },
        IMAGE => {
            let hash = c.u64()?;
            let w = c.u32()?;
            let h = c.u32()?;
            let format = c.u8()?;
            let pixels = c.take((w as usize).checked_mul(h as usize)?.checked_mul(4)?)?;
            Op::Image { hash, w, h, format, pixels }
        }
        GLYPH => Op::Glyph { font: c.u64()?, glyph: c.u32()?, path: c.path()? },
        PRESENT => Op::Present { surface: c.u32()?, wl_surface: c.u32()? },
        PIXELS => {
            let surface = c.u32()?;
            let w = c.u32()?;
            let h = c.u32()?;
            let rgba = c.take((w as usize).checked_mul(h as usize)?.checked_mul(4)?)?;
            Op::Pixels { surface, w, h, rgba }
        }
        other => return Some(Op::Unknown { op: other, payload }),
    };
    c.done().then_some(op)
}

/// Yields the ops of a stream in order. Stops after the first error; a stream that ends
/// inside an op is an error at that op.
pub struct Reader<'a> {
    stream: &'a [u8],
    at: usize,
    failed: bool,
}

impl<'a> Reader<'a> {
    pub fn new(stream: &'a [u8]) -> Self {
        Self { stream, at: 0, failed: false }
    }
}

impl<'a> Iterator for Reader<'a> {
    type Item = Result<Op<'a>, DrawError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.failed || self.at >= self.stream.len() {
            return None;
        }
        let start = self.at;
        let rest = &self.stream[start..];
        let op = rest[0];
        let payload = (rest.len() >= 5)
            .then(|| u32_at(rest, 1) as usize)
            .and_then(|len| rest.get(5..5usize.checked_add(len)?));
        let decoded = payload.and_then(|p| {
            self.at = start + 5 + p.len();
            decode(op, p)
        });
        match decoded {
            Some(op) => Some(Ok(op)),
            None => {
                self.failed = true;
                Some(Err(DrawError { op, offset: start }))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct W(Vec<u8>);
    impl W {
        fn u8(&mut self, v: u8) -> &mut Self {
            self.0.push(v);
            self
        }
        fn u32(&mut self, v: u32) -> &mut Self {
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }
        fn u64(&mut self, v: u64) -> &mut Self {
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }
        fn f(&mut self, v: &[f32]) -> &mut Self {
            for x in v {
                self.0.extend_from_slice(&x.to_le_bytes());
            }
            self
        }
    }

    fn op(code: u8, body: impl FnOnce(&mut W)) -> Vec<u8> {
        let mut w = W(Vec::new());
        body(&mut w);
        let mut out = vec![code];
        out.extend_from_slice(&(w.0.len() as u32).to_le_bytes());
        out.extend_from_slice(&w.0);
        out
    }

    const ID: [f32; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

    #[test]
    fn reads_a_frame_of_ops() {
        let mut s = Vec::new();
        s.extend(op(SURFACE, |w| {
            w.u32(1).u32(400).u32(300).u8(1);
        }));
        s.extend(op(TARGET, |w| {
            w.u32(1);
        }));
        s.extend(op(CLIP, |w| {
            w.u32(1).u8(0).f(&[0.0, 0.0, 200.0, 100.0]);
        }));
        s.extend(op(GLYPH, |w| {
            w.u64(7).u32(36).u32(3).u32(2).u8(0).u8(1).u8(4).f(&[0.0, 0.0, 0.5, -0.7]);
        }));
        s.extend(op(FILL, |w| {
            w.u8(2).u8(0).u8(0).f(&ID).u8(0).f(&[1.0, 0.5, 0.0, 1.0]);
            w.u32(2).u32(2).u8(0).u8(1).f(&[1.0, 2.0, 3.0, 4.0]);
        }));
        s.extend(op(GLYPHS, |w| {
            w.u8(2).f(&ID).f(&[13.0, 0.0, 0.0, 13.0, 0.0, 0.0]).u64(7).u8(0).f(&[0.0, 0.0, 0.0, 1.0]);
            w.u32(2).u32(36).f(&[10.0, 20.0]).u32(36).f(&[18.0, 20.0]);
        }));
        s.extend(op(0x7F, |w| {
            w.u32(99);
        }));
        s.extend(op(PRESENT, |w| {
            w.u32(1).u32(12);
        }));
        let ops: Vec<Op> = Reader::new(&s).collect::<Result<_, _>>().unwrap();
        assert_eq!(ops.len(), 8);
        assert_eq!(ops[0], Op::Surface { id: 1, w: 400, h: 300, window: true });
        assert_eq!(ops[2], Op::Clip(vec![ClipItem::Rect([0.0, 0.0, 200.0, 100.0])]));
        let Op::Glyph { path, .. } = &ops[3] else { panic!() };
        let segs: Vec<_> = path.segments().collect();
        assert_eq!(segs[1].0, Verb::Line);
        assert_eq!(segs[1].1[0], (0.5, -0.7));
        assert_eq!(segs[2].0, Verb::Close);
        let Op::Fill { operator, source, path, .. } = &ops[4] else { panic!() };
        assert_eq!((*operator, source), (2, &Source::Solid([1.0, 0.5, 0.0, 1.0])));
        assert_eq!(path.segments().map(|s| s.1[0]).collect::<Vec<_>>(), [(1.0, 2.0), (3.0, 4.0)]);
        let Op::Glyphs { glyphs, font, .. } = &ops[5] else { panic!() };
        assert_eq!(*font, 7);
        assert_eq!(glyphs.iter().collect::<Vec<_>>(), [(36, 10.0, 20.0), (36, 18.0, 20.0)]);
        assert!(matches!(ops[6], Op::Unknown { op: 0x7F, .. }));
        assert_eq!(ops[7], Op::Present { surface: 1, wl_surface: 12 });
    }

    #[test]
    fn rejects_payloads_that_do_not_fit() {
        // A path claiming more points than its verbs use.
        let bad = op(GLYPH, |w| {
            w.u64(1).u32(1).u32(1).u32(2).u8(0).f(&[0.0, 0.0, 1.0, 1.0]);
        });
        let r: Vec<_> = Reader::new(&bad).collect();
        assert_eq!(r, [Err(DrawError { op: GLYPH, offset: 0 })]);
        // Truncated inside an op.
        let mut cut = op(TARGET, |w| {
            w.u32(5);
        });
        cut.pop();
        assert!(Reader::new(&cut).next().unwrap().is_err());
        // Trailing bytes inside a payload.
        let long = op(FREE, |w| {
            w.u32(5).u8(0);
        });
        assert!(Reader::new(&long).next().unwrap().is_err());
    }

    #[test]
    fn glyph_keys_match_the_recorder() {
        // cdl_xxh64(&font, 8, glyph) in guest/draw/src/cdl.h.
        assert_eq!(glyph_key(0, 0), crate::atlas::xxh64(&[0u8; 8], 0));
        assert_ne!(glyph_key(7, 36), glyph_key(7, 37));
    }
}
