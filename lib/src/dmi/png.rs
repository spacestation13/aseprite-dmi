use flate2::{Compression as ZlibCompression, write::ZlibEncoder};
use png::{BitDepth, ColorType, Compression, Decoder, Encoder};
use std::collections::HashMap;
use std::fs::{File, OpenOptions, create_dir_all};
use std::io::{BufReader, BufWriter, Write};
use std::path::Path;

use super::{DmiError, DmiResult};

const METADATA_KEYWORD: &[u8] = b"Description";

/// Reads the zTXt metadata. BYOND 516 writes it as UTF-8; files whose text isn't valid UTF-8
/// are legacy Latin-1.
pub fn read_dmi_metadata<P>(path: P) -> DmiResult<String>
where
    P: AsRef<Path>,
{
    let decoder = Decoder::new(BufReader::new(File::open(path)?));
    let reader = decoder.read_info()?;
    let chunk = reader
        .info()
        .compressed_latin1_text
        .first()
        .ok_or(DmiError::MissingZTXTChunk)?;

    // The png crate decodes every byte as Latin-1, one char per byte, so this recovers the bytes.
    let latin1 = chunk.get_text()?;
    let utf8 = latin1
        .chars()
        .map(u8::try_from)
        .collect::<Result<Vec<_>, _>>()
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok());
    Ok(utf8.unwrap_or(latin1))
}

/// The zTXt "Description" chunk with UTF-8 text, as BYOND 516 writes it. The png crate only
/// writes Latin-1. ASCII text gives the same bytes as the png crate.
fn metadata_chunk(metadata: &str) -> DmiResult<Vec<u8>> {
    let mut data = Vec::with_capacity(METADATA_KEYWORD.len() + 2 + metadata.len() / 2);
    data.extend_from_slice(METADATA_KEYWORD);
    // Keyword terminator, then compression method 0 (zlib).
    data.extend_from_slice(&[0, 0]);
    let mut encoder = ZlibEncoder::new(data, ZlibCompression::fast());
    encoder.write_all(metadata.as_bytes())?;
    Ok(encoder.finish()?)
}

pub fn save_rgba_dmi<P>(
    width: u32,
    height: u32,
    bytes: &[u8],
    path: P,
    metadata: &str,
) -> DmiResult<()>
where
    P: AsRef<Path>,
{
    let expected_len = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(DmiError::MissingData)?;
    if bytes.len() != expected_len {
        return Err(DmiError::MissingData);
    }

    write_dmi_png(width, height, path, metadata, |sink| sink(bytes))
}

/// Calls the sink with consecutive RGBA bands of the image, top to bottom, each a whole number
/// of rows. The writer runs it twice: first to pick the smallest pixel format, then to encode.
pub(super) trait RowSource:
    Fn(&mut dyn FnMut(&[u8]) -> DmiResult<()>) -> DmiResult<()>
{
}
impl<F> RowSource for F where F: Fn(&mut dyn FnMut(&[u8]) -> DmiResult<()>) -> DmiResult<()> {}

/// The smallest lossless pixel format for an image, like oxipng's reductions: a palette (at 1, 2,
/// 4 or 8 bits per pixel) for up to 256 colors, else RGB when fully opaque, else RGBA.
enum Format {
    Indexed {
        /// Little-endian packed RGBA, in order of first appearance.
        palette: Vec<u32>,
        index_of: HashMap<u32, u8>,
        depth: BitDepth,
    },
    Rgb,
    Rgba,
}

fn pixels(band: &[u8]) -> impl Iterator<Item = u32> + '_ {
    band.as_chunks::<4>()
        .0
        .iter()
        .map(|px| u32::from_le_bytes(*px))
}

impl Format {
    fn detect(source: &impl RowSource) -> DmiResult<Self> {
        let mut palette = Vec::<u32>::new();
        let mut index_of = HashMap::<u32, u8>::new();
        let mut indexable = true;
        let mut opaque = true;
        let mut last = None;
        source(&mut |band| {
            for pixel in pixels(band) {
                // Pixel art is mostly flat runs.
                if last == Some(pixel) {
                    continue;
                }
                last = Some(pixel);
                opaque &= pixel >> 24 == 0xFF;
                if indexable && !index_of.contains_key(&pixel) {
                    match u8::try_from(palette.len()) {
                        Ok(index) => {
                            index_of.insert(pixel, index);
                            palette.push(pixel);
                        }
                        Err(_) => indexable = false,
                    }
                }
            }
            Ok(())
        })?;
        Ok(if indexable {
            let depth = match palette.len() {
                0..=2 => BitDepth::One,
                3..=4 => BitDepth::Two,
                5..=16 => BitDepth::Four,
                _ => BitDepth::Eight,
            };
            Format::Indexed {
                palette,
                index_of,
                depth,
            }
        } else if opaque {
            Format::Rgb
        } else {
            Format::Rgba
        })
    }

    fn configure<W: Write>(&self, encoder: &mut Encoder<W>) {
        match self {
            Format::Indexed { palette, depth, .. } => {
                encoder.set_color(ColorType::Indexed);
                encoder.set_depth(*depth);
                encoder.set_palette(
                    palette
                        .iter()
                        .flat_map(|color| {
                            let [r, g, b, _] = color.to_le_bytes();
                            [r, g, b]
                        })
                        .collect::<Vec<_>>(),
                );
                // Entries after the last translucent one are implicitly opaque.
                let alpha: Vec<u8> = palette.iter().map(|color| color.to_le_bytes()[3]).collect();
                if let Some(last) = alpha.iter().rposition(|&a| a != 0xFF) {
                    encoder.set_trns(alpha[..=last].to_vec());
                }
            }
            Format::Rgb => {
                encoder.set_color(ColorType::Rgb);
                encoder.set_depth(BitDepth::Eight);
            }
            Format::Rgba => {
                encoder.set_color(ColorType::Rgba);
                encoder.set_depth(BitDepth::Eight);
            }
        }
    }

    /// Converts a band of RGBA rows `width` pixels wide to this format. Rows are padded to whole
    /// bytes. `scratch` holds the result unless the band is already in this format.
    fn encode<'a>(&self, width: usize, band: &'a [u8], scratch: &'a mut Vec<u8>) -> &'a [u8] {
        scratch.clear();
        match self {
            Format::Rgba => return band,
            Format::Rgb => {
                for pixel in band.as_chunks::<4>().0 {
                    scratch.extend_from_slice(&pixel[..3]);
                }
            }
            Format::Indexed {
                index_of, depth, ..
            } => {
                let bits = *depth as usize;
                let mut cached = None;
                for row in band.chunks_exact(width * 4) {
                    for group in row.chunks(4 * (8 / bits)) {
                        let mut byte = 0_u8;
                        for (i, pixel) in pixels(group).enumerate() {
                            let index = match cached {
                                Some((color, index)) if color == pixel => index,
                                _ => {
                                    let index = index_of[&pixel];
                                    cached = Some((pixel, index));
                                    index
                                }
                            };
                            byte |= index << (8 - bits * (i + 1));
                        }
                        scratch.push(byte);
                    }
                }
            }
        }
        scratch
    }
}

/// Streams the PNG to a temporary file next to `path`, then replaces `path` with it, so a failed
/// encode never touches the existing file. `source` provides the RGBA rows top to bottom.
pub(super) fn write_dmi_png<P, S>(
    width: u32,
    height: u32,
    path: P,
    metadata: &str,
    source: S,
) -> DmiResult<()>
where
    P: AsRef<Path>,
    S: RowSource,
{
    let path = path.as_ref();
    let metadata = metadata_chunk(metadata)?;
    let format = Format::detect(&source)?;
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
        && !parent.exists()
    {
        create_dir_all(parent)?;
    }
    let mut temp = path.as_os_str().to_owned();
    temp.push(format!(".{}.tmp", std::process::id()));
    let temp = Path::new(&temp);

    let encoded = (|| -> DmiResult<()> {
        let mut file = BufWriter::new(File::create(temp)?);
        let mut encoder = Encoder::new(&mut file, width, height);
        encoder.set_compression(Compression::High);
        // Row filters mostly hurt pixel art: on 47 Goonstation DMIs, unfiltered rows were the
        // smallest in 46 and within 0.1% overall of the best filter per file.
        encoder.set_filter(png::Filter::NoFilter);
        format.configure(&mut encoder);
        let mut writer = encoder.write_header()?;
        // After IHDR and the palette, which the png crate writes with the header.
        writer.write_chunk(png::chunk::zTXt, &metadata)?;
        let mut stream = writer.stream_writer()?;
        let mut scratch = Vec::new();
        source(&mut |band| {
            Ok(stream.write_all(format.encode(width as usize, band, &mut scratch))?)
        })?;
        stream.finish()?;
        writer.finish()?;
        file.flush()?;
        Ok(())
    })();
    if let Err(err) = encoded {
        let _ = std::fs::remove_file(temp);
        return Err(err);
    }

    // Keep the original file's permission bits (e.g. read-only stays read-only).
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(temp, meta.permissions());
    }
    if std::fs::rename(temp, path).is_err() {
        // Replacing fails when another program holds the file open without delete sharing
        // (common on Windows), so overwrite in place from the finished temp file instead.
        let copied = File::open(temp).and_then(|mut src| {
            let mut dst = OpenOptions::new().write(true).truncate(true).open(path)?;
            std::io::copy(&mut src, &mut dst)
        });
        let _ = std::fs::remove_file(temp);
        copied?;
    }
    Ok(())
}
