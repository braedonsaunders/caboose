//! The frame tag a toolkit scroll reporter draws in a window's bottom overscan, so a
//! picture names the `scroll.tree` that describes it (docs/display.md, "Frame tag").
//!
//! 32 square blocks in a row, each black (0) or white (1): the sync pattern 1010, the
//! 24-bit value most significant bit first, then the XOR of the value's six nibbles.

/// Blocks in a tag.
pub const BLOCKS: usize = 32;
/// The smallest block side, in display pixels.
pub const MIN_BLOCK: i32 = 12;

const SYNC: [bool; 4] = [true, false, true, false];

fn check(value: u32) -> u32 {
    (0..6).fold(0, |c, i| c ^ ((value >> (4 * i)) & 0xF))
}

/// The 32 blocks for a 24-bit `value`; `true` is white.
pub fn encode(value: u32) -> [bool; BLOCKS] {
    let value = value & 0xFF_FFFF;
    let mut blocks = [false; BLOCKS];
    blocks[..4].copy_from_slice(&SYNC);
    for i in 0..24 {
        blocks[4 + i] = value >> (23 - i) & 1 == 1;
    }
    let c = check(value);
    for i in 0..4 {
        blocks[28 + i] = c >> (3 - i) & 1 == 1;
    }
    blocks
}

/// The value of 32 block luma samples (0–255), or `None` when they are not a tag.
pub fn decode(luma: &[f32]) -> Option<u32> {
    if luma.len() != BLOCKS {
        return None;
    }
    let bit = |l: f32| l >= 128.0;
    if luma[..4].iter().map(|&l| bit(l)).ne(SYNC) {
        return None;
    }
    let value = luma[4..28].iter().fold(0u32, |v, &l| v << 1 | bit(l) as u32);
    let c = luma[28..].iter().fold(0u32, |v, &l| v << 1 | bit(l) as u32);
    (c == check(value)).then_some(value)
}

/// The tag's pattern as text, `1` white and `0` black, for the golden vector.
pub fn pattern(value: u32) -> String {
    encode(value).iter().map(|&b| if b { '1' } else { '0' }).collect()
}

/// Values pinned by `vectors/scroll-tag.json`.
pub const VECTOR_VALUES: [u32; 5] = [0, 1, 0x03_2A10, 0x12_3456, 0xFF_FFFF];

/// The golden vector's JSON.
pub fn vector_json() -> String {
    let rows: Vec<String> = VECTOR_VALUES
        .iter()
        .map(|&v| format!("    {{\"value\": {v}, \"blocks\": \"{}\"}}", pattern(v)))
        .collect();
    format!(
        "{{\n  \"name\": \"scroll-tag\",\n  \"description\": \"Frame tag block patterns: 1 white, 0 black, left to right.\",\n  \"tags\": [\n{}\n  ]\n}}\n",
        rows.join(",\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn luma(value: u32) -> Vec<f32> {
        encode(value).iter().map(|&b| if b { 235.0 } else { 16.0 }).collect()
    }

    #[test]
    fn round_trips_every_vector_value() {
        for v in VECTOR_VALUES {
            assert_eq!(decode(&luma(v)), Some(v));
        }
    }

    #[test]
    fn rejects_a_flipped_bit_and_page_content() {
        let mut l = luma(0x03_2A10);
        l[10] = 255.0 - l[10];
        assert_eq!(decode(&l), None);
        assert_eq!(decode(&[255.0; BLOCKS]), None);
        assert_eq!(decode(&[0.0; BLOCKS]), None);
    }

    #[test]
    fn matches_the_golden_vector() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/scroll-tag.json");
        assert_eq!(std::fs::read_to_string(path).unwrap(), vector_json());
    }
}
