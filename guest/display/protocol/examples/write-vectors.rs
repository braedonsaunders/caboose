//! Regenerates guest/display/vectors/ from `caboose_display_protocol::vectors`.
//!
//!   cargo run -p caboose-display-protocol --example write-vectors

use caboose_display_protocol::vectors;
use std::path::Path;

fn main() -> std::io::Result<()> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../vectors");
    let media = vectors_media(&dir)?;
    for vector in vectors::all(&media) {
        std::fs::write(dir.join(format!("{}.bin", vector.name)), vector.bytes())?;
        std::fs::write(dir.join(format!("{}.json", vector.name)), vector.json())?;
        println!("{}", vector.name);
    }
    std::fs::write(dir.join("scroll-tag.json"), caboose_display_protocol::scroll_tag::vector_json())?;
    Ok(())
}

fn vectors_media(dir: &Path) -> std::io::Result<vectors::Media> {
    let media = dir.join("media");
    Ok(vectors::Media {
        h264_keyframe: std::fs::read(media.join("keyframe-64x64.h264"))?,
        hevc_keyframe: std::fs::read(media.join("keyframe-64x64.hevc"))?,
        png: std::fs::read(media.join("icon-16x16.png"))?,
        opus_stereo: std::fs::read(media.join("opus-stereo-20ms.opus"))?,
    })
}
