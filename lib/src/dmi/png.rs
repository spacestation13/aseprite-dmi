use png::{Compression, Decoder, Encoder};
use std::fs::{File, create_dir_all};
use std::io::BufReader;
use std::path::Path;

use super::{DmiError, DmiResult};

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

    Ok(chunk.get_text()?)
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
    let mut encoded = Vec::new();
    {
        let mut encoder = Encoder::new(&mut encoded, width, height);
        encoder.set_compression(Compression::High);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.add_ztxt_chunk("Description".to_string(), metadata.to_string())?;
        let mut writer = encoder.write_header()?;
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
    let result = std::fs::write(temp, &encoded).and_then(|()| std::fs::rename(temp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    Ok(result?)
}
