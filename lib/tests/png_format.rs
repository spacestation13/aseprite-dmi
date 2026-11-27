use std::path::PathBuf;

use dmi::{SaveOptions, read_dmi_metadata, save_rgba_dmi};
use image::ImageReader;

const METADATA: &str = "# BEGIN DMI\nversion = 4.0\n\twidth = 1\n\theight = 1\n# END DMI\n";

/// `width` x `height` RGBA pixels, each from `color(index)`.
fn image(width: u32, height: u32, color: impl Fn(u32) -> [u8; 4]) -> Vec<u8> {
    (0..width * height).flat_map(color).collect()
}

/// Saves `bytes` with `options` and returns the PNG's (bit depth, color type), where color type
/// 3 is a palette, 2 RGB and 6 RGBA, and the pixels and metadata it decodes to.
fn save_and_read(
    name: &str,
    width: u32,
    height: u32,
    bytes: &[u8],
    options: SaveOptions,
) -> ((u8, u8), Vec<u8>) {
    let path: PathBuf = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    save_rgba_dmi(width, height, bytes, &path, METADATA, options).unwrap();

    let png = std::fs::read(&path).unwrap();
    let decoded = ImageReader::open(&path).unwrap().decode().unwrap();
    assert_eq!(
        read_dmi_metadata(&path).unwrap(),
        METADATA,
        "{name}: metadata"
    );
    std::fs::remove_file(path).unwrap();
    // IHDR data starts at byte 16: width, height, then bit depth and color type.
    ((png[24], png[25]), decoded.to_rgba8().into_raw())
}

/// Saves `bytes` and checks that the pixels survive exactly. Returns the PNG's
/// (bit depth, color type).
fn round_trip(name: &str, width: u32, height: u32, bytes: &[u8]) -> (u8, u8) {
    let (format, pixels) = save_and_read(name, width, height, bytes, SaveOptions::default());
    assert_eq!(pixels, bytes, "{name}: pixels");
    format
}

#[test]
fn black_near_transparent_keeps_images_in_a_palette() {
    // Pixels with alpha 0 and 1 in hundreds of different colors, among pixels that show.
    let bytes = image(30, 30, |i| match i % 4 {
        0 => [i as u8, (i >> 8) as u8, 7, 1],
        1 => [10, 20, 30, 255],
        2 => [5, 9, 9, 2],
        _ => [i as u8, (i >> 8) as u8, 3, 0],
    });
    let name = "near_transparent.png";

    let (format, pixels) = save_and_read(name, 30, 30, &bytes, SaveOptions::default());
    assert_eq!(
        format,
        (8, 6),
        "off by default: too many colors for a palette"
    );
    assert_eq!(pixels, bytes);

    let options = SaveOptions {
        black_near_transparent: true,
    };
    let (format, pixels) = save_and_read(name, 30, 30, &bytes, options);
    let expected: Vec<u8> = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|&[r, g, b, a]| if a <= 1 { [0, 0, 0, a] } else { [r, g, b, a] })
        .collect();
    assert_eq!(pixels, expected, "only alpha 0 and 1 pixels change");
    assert_eq!(format, (2, 3), "four colors: a 2-bit palette");
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
