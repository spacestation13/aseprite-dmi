use std::fs::remove_file;
use std::path::{Path, PathBuf};

use dmi::{Dmi, SaveOptions, read_dmi_metadata, save_rgba_dmi};

fn sample() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/assets/anomaly.dmi")
}

fn temp_file(name: &str) -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("{}-{name}", std::process::id()))
}

/// The raw bytes of the zTXt text (the png crate decodes them as Latin-1, one char per byte).
fn ztxt_bytes(path: &Path) -> Vec<u8> {
    let decoder = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).unwrap()));
    let reader = decoder.read_info().unwrap();
    let chunk = &reader.info().compressed_latin1_text[0];
    assert_eq!(chunk.keyword, "Description");
    chunk
        .get_text()
        .unwrap()
        .chars()
        .map(|c| u8::try_from(c).unwrap())
        .collect()
}

/// A 2x1 RGBA PNG written by the png crate's own (Latin-1) zTXt encoder, as older versions did.
fn png_crate_dmi(path: &Path, metadata: &str) {
    let mut encoded = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut encoded, 2, 1);
        encoder.set_compression(png::Compression::High);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .add_ztxt_chunk("Description".to_string(), metadata.to_string())
            .unwrap();
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[255; 8]).unwrap();
        writer.finish().unwrap();
    }
    std::fs::write(path, encoded).unwrap();
}

fn two_states(first: &str, second: &str) -> String {
    format!(
        "# BEGIN DMI\nversion = 4.0\n\twidth = 1\n\theight = 1\nstate = \"{first}\"\n\tdirs = 1\n\tframes = 1\nstate = \"{second}\"\n\tdirs = 1\n\tframes = 1\n# END DMI\n"
    )
}

#[test]
fn non_ascii_state_names_round_trip_as_utf8() {
    let names = [
        "ok\u{2014}dash",
        "\u{65E5}\u{672C}\u{8A9E}",
        "party \u{1F389}",
        "caf\u{E9} \u{E0}\u{EE}\u{F5}\u{FC}",
    ];
    let mut dmi = Dmi::open(sample()).unwrap();
    for (state, name) in dmi.states.iter_mut().zip(names) {
        state.name = name.to_string();
    }

    let output = temp_file("utf8.dmi");
    dmi.save(&output, SaveOptions::default()).unwrap();

    let metadata = read_dmi_metadata(&output).unwrap();
    assert_eq!(
        ztxt_bytes(&output),
        metadata.as_bytes(),
        "zTXt text is UTF-8"
    );
    let reopened = Dmi::open(&output).unwrap();
    for (state, name) in reopened.states.iter().zip(names) {
        assert_eq!(state.name, name);
    }
    remove_file(output).unwrap();
}

#[test]
fn legacy_latin1_metadata_is_read() {
    let output = temp_file("latin1.dmi");
    let metadata = two_states("caf\u{E9}", "na\u{EF}ve \u{A9}");
    png_crate_dmi(&output, &metadata);
    let raw = ztxt_bytes(&output);
    assert!(
        raw.windows(5).any(|w| w == b"caf\xE9\""),
        "written as Latin-1"
    );

    assert_eq!(read_dmi_metadata(&output).unwrap(), metadata);
    let dmi = Dmi::open(&output).unwrap();
    assert_eq!(dmi.states[0].name, "caf\u{E9}");
    assert_eq!(dmi.states[1].name, "na\u{EF}ve \u{A9}");
    remove_file(output).unwrap();
}

/// The raw zTXt chunk (data only) of a PNG file.
fn ztxt_chunk(path: &Path) -> Vec<u8> {
    let bytes = std::fs::read(path).unwrap();
    let mut at = 8;
    while at + 8 <= bytes.len() {
        let len = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        if &bytes[at + 4..at + 8] == b"zTXt" {
            return bytes[at + 8..at + 8 + len].to_vec();
        }
        at += 12 + len;
    }
    panic!("no zTXt chunk");
}

#[test]
fn ascii_metadata_chunk_is_byte_identical_to_png_crate_output() {
    let metadata = two_states("plain", "with \\\"quotes\\\"");
    let expected = temp_file("ascii-expected.dmi");
    let output = temp_file("ascii-actual.dmi");
    png_crate_dmi(&expected, &metadata);
    save_rgba_dmi(2, 1, &[255; 8], &output, &metadata, SaveOptions::default()).unwrap();

    assert_eq!(ztxt_chunk(&output), ztxt_chunk(&expected));
    assert_eq!(read_dmi_metadata(&output).unwrap(), metadata);
    remove_file(expected).unwrap();
    remove_file(output).unwrap();
}
