use png::{Compression, Decoder, Encoder};
use std::fs::{File, create_dir_all};
use std::io::{BufReader, BufWriter};
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
    if let Some(parent) = path.as_ref().parent()
        && !parent.exists()
    {
        create_dir_all(parent)?;
    }

    let mut file = BufWriter::new(File::create(path)?);
    let mut encoder = Encoder::new(&mut file, width, height);
    encoder.set_compression(Compression::High);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.add_ztxt_chunk("Description".to_string(), metadata.to_string())?;

    let mut writer = encoder.write_header()?;
    writer.write_image_data(bytes)?;

    Ok(())
}
