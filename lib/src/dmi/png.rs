use flate2::{Compression as ZlibCompression, write::ZlibEncoder};
use png::{Compression, Decoder, Encoder};
use std::fs::{File, create_dir_all};
use std::io::{BufReader, Write as _};
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

    write_dmi_png(width, height, bytes, path, metadata)
}

/// Encodes the PNG in memory and replaces `path` through a temporary file in the same directory,
/// so a failed encode or write never truncates or corrupts an existing file.
pub(super) fn write_dmi_png<P>(
    width: u32,
    height: u32,
    bytes: &[u8],
    path: P,
    metadata: &str,
) -> DmiResult<()>
where
    P: AsRef<Path>,
{
    let path = path.as_ref();
    let metadata = metadata_chunk(metadata)?;
    let mut encoded = Vec::new();
    {
        let mut encoder = Encoder::new(&mut encoded, width, height);
        encoder.set_compression(Compression::High);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header()?;
        // Right after IHDR, where the png crate puts text chunks added to the encoder.
        writer.write_chunk(png::chunk::zTXt, &metadata)?;
        writer.write_image_data(bytes)?;
        writer.finish()?;
    }

    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
        && !parent.exists()
    {
        create_dir_all(parent)?;
    }
    let mut temp = path.as_os_str().to_owned();
    temp.push(format!(".{}.tmp", std::process::id()));
    let temp = Path::new(&temp);
    let replaced = std::fs::write(temp, &encoded).and_then(|()| {
        // Keep the original file's permission bits (e.g. read-only stays read-only).
        if let Ok(meta) = std::fs::metadata(path) {
            let _ = std::fs::set_permissions(temp, meta.permissions());
        }
        std::fs::rename(temp, path)
    });
    if replaced.is_ok() {
        return Ok(());
    }
    let _ = std::fs::remove_file(temp);
    // Replacing fails when another program holds the file open without delete sharing
    // (common on Windows). The bytes are already encoded, so overwrite in place instead.
    std::fs::write(path, &encoded)?;
    Ok(())
}
