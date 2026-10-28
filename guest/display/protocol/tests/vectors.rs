//! The committed golden vectors are exactly what this crate encodes, and decode back
//! to the same messages.

use caboose_display_protocol::vectors::{self, Entry};
use caboose_display_protocol::{decode_all, encode, Decoded};
use std::path::{Path, PathBuf};

fn dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../vectors")
}

fn media() -> vectors::Media {
    let media = dir().join("media");
    vectors::Media {
        h264_keyframe: std::fs::read(media.join("keyframe-64x64.h264")).unwrap(),
        hevc_keyframe: std::fs::read(media.join("keyframe-64x64.hevc")).unwrap(),
        png: std::fs::read(media.join("icon-16x16.png")).unwrap(),
        opus_stereo: std::fs::read(media.join("opus-stereo-20ms.opus")).unwrap(),
    }
}

#[test]
fn committed_vectors_match_the_encoder() {
    let all = vectors::all(&media());
    for vector in &all {
        let bin = std::fs::read(dir().join(format!("{}.bin", vector.name)))
            .unwrap_or_else(|_| panic!("{}.bin missing: run the write-vectors example", vector.name));
        assert_eq!(bin, vector.bytes(), "{}.bin drifted from the encoder", vector.name);
        let json = std::fs::read_to_string(dir().join(format!("{}.json", vector.name))).unwrap();
        assert_eq!(json, vector.json(), "{}.json drifted", vector.name);
    }
    // No stale files from renamed vectors.
    let names: Vec<String> = all.iter().map(|v| v.name.to_owned()).collect();
    for file in std::fs::read_dir(dir()).unwrap() {
        let path = file.unwrap().path();
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            if ext == "bin" || ext == "json" {
                let stem = path.file_stem().unwrap().to_str().unwrap().to_owned();
                assert!(names.contains(&stem), "stale vector file {}", path.display());
            }
        }
    }
}

#[test]
fn vectors_decode_to_their_messages() {
    for vector in vectors::all(&media()) {
        let decoded = decode_all(&vector.bytes()).unwrap();
        assert_eq!(decoded.len(), vector.entries.len(), "{}", vector.name);
        for (entry, got) in vector.entries.iter().zip(decoded) {
            match (entry, got) {
                (Entry::Message(want), Decoded::Message(got)) => {
                    assert_eq!(&got, want, "{}", vector.name);
                    assert_eq!(encode(&got), encode(want));
                }
                (Entry::Liberal { decodes_to, .. }, Decoded::Message(got)) => {
                    assert_eq!(&got, decodes_to, "{}", vector.name)
                }
                (Entry::Unknown { type_id, payload }, Decoded::Unknown { type_id: t, len }) => {
                    assert_eq!((*type_id, payload.len()), (t, len))
                }
                (_, got) => panic!("{}: unexpected {got:?}", vector.name),
            }
        }
    }
}

#[test]
fn every_type_id_has_a_vector() {
    use caboose_display_protocol::type_name;
    let mut covered = std::collections::BTreeSet::new();
    for vector in vectors::all(&media()) {
        for entry in &vector.entries {
            if let Entry::Message(m) = entry {
                covered.insert(m.type_id());
            }
        }
    }
    for id in 0..=255u8 {
        if type_name(id).is_some() {
            assert!(covered.contains(&id), "type 0x{id:02x} has no vector");
        }
    }
}
