use std::path::PathBuf;

use dmi::{read_dmi_metadata, save_rgba_dmi};
use image::ImageReader;

const METADATA: &str = "# BEGIN DMI\nversion = 4.0\n\twidth = 1\n\theight = 1\n# END DMI\n";

/// `width` x `height` RGBA pixels, each from `color(index)`.
fn image(width: u32, height: u32, color: impl Fn(u32) -> [u8; 4]) -> Vec<u8> {
    (0..width * height).flat_map(color).collect()
}

/// Saves `bytes`, checks that the pixels and metadata survive, and returns the PNG's
/// (bit depth, color type): color type 3 is a palette, 2 RGB and 6 RGBA.
fn round_trip(name: &str, width: u32, height: u32, bytes: &[u8]) -> (u8, u8) {
    let path: PathBuf = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    save_rgba_dmi(width, height, bytes, &path, METADATA).unwrap();

    let png = std::fs::read(&path).unwrap();
    let decoded = ImageReader::open(&path).unwrap().decode().unwrap();
    assert_eq!(decoded.to_rgba8().as_raw(), bytes, "{name}: pixels");
    assert_eq!(
        read_dmi_metadata(&path).unwrap(),
        METADATA,
        "{name}: metadata"
    );
    std::fs::remove_file(path).unwrap();
    // IHDR data starts at byte 16: width, height, then bit depth and color type.
    (png[24], png[25])
}

#[test]
fn few_colors_use_the_smallest_palette_depth() {
    // Widths that are not a multiple of the pixels per byte exercise the row padding.
    let cases = [(2, 1, 3), (4, 2, 5), (16, 4, 7), (17, 8, 9)];
    for (colors, depth, width) in cases {
        let bytes = image(width, 6, |i| {
            let c = (i % colors) as u8;
            [c * 7, 255 - c, c, if c == 1 { 0 } else { 255 }]
        });
        assert_eq!(
            round_trip(&format!("palette{colors}.png"), width, 6, &bytes),
            (depth, 3),
            "{colors} colors"
        );
    }
}

#[test]
fn palette_keeps_transparent_pixels_exactly() {
    // Fully transparent pixels with different hidden RGB are different colors.
    let bytes = image(4, 4, |i| [i as u8, 9, 9, if i % 2 == 0 { 0 } else { 128 }]);
    assert_eq!(round_trip("translucent.png", 4, 4, &bytes), (4, 3));
}

#[test]
fn many_colors_drop_alpha_only_when_opaque() {
    let opaque = image(20, 20, |i| [i as u8, (i / 256) as u8, 3, 255]);
    assert_eq!(round_trip("opaque.png", 20, 20, &opaque), (8, 2));

    let translucent = image(20, 20, |i| {
        [i as u8, (i / 256) as u8, 3, 255 - (i % 2) as u8]
    });
    assert_eq!(round_trip("alpha.png", 20, 20, &translucent), (8, 6));
}

#[test]
fn exactly_256_colors_still_fit_a_palette() {
    let bytes = image(16, 16, |i| [i as u8, 0, 0, 255]);
    assert_eq!(round_trip("full_palette.png", 16, 16, &bytes), (8, 3));
}
