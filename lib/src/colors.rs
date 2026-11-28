use anyhow::{Context as _, Result};
use image::{ImageFormat, ImageReader};
use std::collections::HashMap;
use std::path::Path;

/// One distinct color and how many pixels use it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColorCount {
    pub rgba: [u8; 4],
    pub count: u64,
}

/// Counts the colors of PNG-based images (.dmi or .png) together.
///
/// Fully transparent pixels (alpha 0) are skipped; other alpha values are distinct colors.
/// Sorted by count, most used first, ties by RGBA value so the order is stable.
pub fn collect_colors<P: AsRef<Path>>(paths: &[P]) -> Result<Vec<ColorCount>> {
    let mut counts: HashMap<[u8; 4], u64> = HashMap::new();

    for path in paths {
        let path = path.as_ref();
        let mut reader = ImageReader::open(path).with_context(|| format!("{}", path.display()))?;
        // .dmi is a PNG the image crate can't guess from the extension.
        reader.set_format(ImageFormat::Png);
        let image = reader
            .decode()
            .with_context(|| format!("{}", path.display()))?
            .into_rgba8();

        for pixel in image.pixels() {
            if pixel.0[3] != 0 {
                *counts.entry(pixel.0).or_default() += 1;
            }
        }
    }

    let mut colors: Vec<ColorCount> = counts
        .into_iter()
        .map(|(rgba, count)| ColorCount { rgba, count })
        .collect();
    colors.sort_unstable_by(|a, b| b.count.cmp(&a.count).then(a.rgba.cmp(&b.rgba)));

    Ok(colors)
}
