use flate2::{Compression as ZlibCompression, write::ZlibEncoder};
use png::{Compression, Decoder, Encoder};
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

    write_dmi_png(width, height, path, metadata, |out| {
        Ok(out.write_all(bytes)?)
    })
}

/// Streams the PNG to a temporary file next to `path`, then replaces `path` with it, so a failed
/// encode never touches the existing file. `write_pixels` writes the RGBA rows top to bottom.
pub(super) fn write_dmi_png<P, F>(
    width: u32,
    height: u32,
    path: P,
    metadata: &str,
    write_pixels: F,
) -> DmiResult<()>
where
    P: AsRef<Path>,
    F: FnOnce(&mut dyn Write) -> DmiResult<()>,
{
    let path = path.as_ref();
    let metadata = metadata_chunk(metadata)?;
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
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header()?;
        // Right after IHDR, where the png crate puts text chunks added to the encoder.
        writer.write_chunk(png::chunk::zTXt, &metadata)?;
        let mut stream = writer.stream_writer()?;
        write_pixels(&mut stream)?;
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
