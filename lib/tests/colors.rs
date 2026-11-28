use std::path::Path;

use dmi::{ColorCount, collect_colors};
use image::{ImageReader, Rgba, RgbaImage};

fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("aseprite-dmi-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn counts_sorts_and_skips_transparent() {
    let dir = temp_dir("colors");
    let red = Rgba([255, 0, 0, 255]);
    let blue = Rgba([0, 0, 255, 255]);
    let glass = Rgba([0, 0, 255, 128]);

    // 4x2: 3 red, 2 blue, 1 half-transparent blue, 2 fully transparent (one with color bits).
    let mut a = RgbaImage::new(4, 2);
    a.put_pixel(0, 0, red);
    a.put_pixel(1, 0, red);
    a.put_pixel(2, 0, blue);
    a.put_pixel(3, 0, glass);
    a.put_pixel(0, 1, Rgba([12, 34, 56, 0]));
    a.put_pixel(1, 1, red);
    a.put_pixel(2, 1, blue);
    let a_path = dir.join("a.png");
    a.save(&a_path).unwrap();

    // A second file with a .dmi extension (still PNG data): 1 more blue pixel, so blue ties red.
    let mut b = RgbaImage::new(1, 1);
    b.put_pixel(0, 0, blue);
    let b_path = dir.join("b.dmi");
    b.save_with_format(&b_path, image::ImageFormat::Png)
        .unwrap();

    let colors = collect_colors(&[&a_path, &b_path]).unwrap();
    assert_eq!(
        colors,
        vec![
            // Ties are ordered by RGBA value.
            ColorCount {
                rgba: [0, 0, 255, 255],
                count: 3
            },
            ColorCount {
                rgba: [255, 0, 0, 255],
                count: 3
            },
            ColorCount {
                rgba: [0, 0, 255, 128],
                count: 1
            },
        ]
    );

    let only_a = collect_colors(&[&a_path]).unwrap();
    assert_eq!(
        only_a[0],
        ColorCount {
            rgba: [255, 0, 0, 255],
            count: 3
        }
    );

    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn counts_every_opaque_pixel_of_a_dmi() {
    let sample = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/assets/anomaly.dmi");
    let colors = collect_colors(&[&sample]).unwrap();

    let mut reader = ImageReader::open(&sample).unwrap();
    reader.set_format(image::ImageFormat::Png);
    let image = reader.decode().unwrap().into_rgba8();
    let visible = image.pixels().filter(|p| p.0[3] != 0).count() as u64;

    assert!(!colors.is_empty());
    assert_eq!(colors.iter().map(|c| c.count).sum::<u64>(), visible);
    assert!(colors.iter().all(|c| c.rgba[3] != 0));
    assert!(colors.windows(2).all(|w| w[0].count >= w[1].count));
}

#[test]
fn missing_or_invalid_file_is_an_error() {
    let dir = temp_dir("colors-invalid");
    let bogus = dir.join("bogus.dmi");
    std::fs::write(&bogus, b"not a png").unwrap();

    assert!(collect_colors(&[dir.join("missing.dmi")]).is_err());
    assert!(collect_colors(&[&bogus]).is_err());

    std::fs::remove_dir_all(&dir).unwrap();
}
