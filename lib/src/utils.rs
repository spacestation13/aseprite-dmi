use anyhow::{Context as _, Result};
use base64::{Engine as _, engine::general_purpose};
use image::DynamicImage;
use png::{Compression, Encoder};
use serde_json::Value;
use std::cmp::Ordering;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{self, BufWriter, Read as _};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Largest file `download` accepts; registry JSON, palettes and preview images are tiny.
const MAX_DOWNLOAD_BYTES: u64 = 32 * 1024 * 1024;

pub fn image_to_base64(image: &DynamicImage) -> Result<String> {
    let mut image_data = Vec::new();

    {
        let image_buffer = image.to_rgba8();
        let mut writer = BufWriter::new(&mut image_data);
        let mut encoder = Encoder::new(&mut writer, image.width(), image.height());

        encoder.set_compression(Compression::High);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);

        let mut writer = encoder.write_header()?;

        writer.write_image_data(&image_buffer)?;
    }

    Ok(format!(
        "data:image/png;base64,{}",
        general_purpose::STANDARD.encode(image_data)
    ))
}

pub fn find_directory<P>(path: P) -> PathBuf
where
    P: AsRef<OsStr>,
{
    let mut path = Path::new(&path).to_path_buf();
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("state")
        .to_string();

    let mut index = 1u32;
    loop {
        path.set_file_name(format!("{file_name}.{index}"));
        if !path.exists() {
            break;
        }
        index += 1;
    }

    path
}

pub fn optimal_size(frames: usize, width: u32, height: u32) -> (f32, u32, u32) {
    if frames == 0 {
        return (0., width, height);
    }

    let sqrt = (frames as f32).sqrt().ceil();
    let (width, height) = (
        (width as f32 * sqrt) as u32,
        height * (frames as f32 / sqrt).ceil() as u32,
    );

    (sqrt, width, height)
}

fn http_client(timeout: Duration) -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent(concat!(
            env!("CARGO_PKG_NAME"),
            "/",
            env!("CARGO_PKG_VERSION")
        ))
        .connect_timeout(timeout)
        .timeout(timeout)
        .build()?)
}

/// Downloads an http(s) URL to `dest` (parent directories are created). The file is written
/// to `<dest>.part` and renamed, so `dest` is never left half-written. Non-2xx statuses are
/// errors. Returns the number of bytes written.
pub fn download(url: &str, dest: &Path, timeout: Duration) -> Result<u64> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        anyhow::bail!("Only http(s) URLs can be downloaded: {url}");
    }

    let response = http_client(timeout)?.get(url).send()?.error_for_status()?;

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut part = dest.as_os_str().to_owned();
    part.push(".part");
    let part = PathBuf::from(part);

    let written = (|| -> Result<u64> {
        let mut file = File::create(&part)?;
        let written = io::copy(&mut response.take(MAX_DOWNLOAD_BYTES + 1), &mut file)?;
        if written > MAX_DOWNLOAD_BYTES {
            anyhow::bail!("Download is larger than {MAX_DOWNLOAD_BYTES} bytes: {url}");
        }
        Ok(written)
    })();

    match written {
        Ok(written) => {
            fs::rename(&part, dest)?;
            Ok(written)
        }
        Err(err) => {
            let _ = fs::remove_file(&part);
            Err(err)
        }
    }
}

pub fn check_latest_version() -> Result<Ordering> {
    let current_version = env!("CARGO_PKG_VERSION");

    let repository = env!("CARGO_PKG_REPOSITORY")
        .split('/')
        .skip(3)
        .collect::<Vec<_>>()
        .join("/");

    let client = http_client(Duration::from_secs(3))?;

    let url = format!("https://api.github.com/repos/{repository}/releases/latest");

    let response = client.get(url).send()?.json::<Value>()?;

    let latest_version = response["tag_name"]
        .as_str()
        .context(format!("No tag name found\n{response}"))?;
    let latest_version = &latest_version[1..];

    Ok(compare_versions(current_version, latest_version))
}

fn compare_versions(v1: &str, v2: &str) -> Ordering {
    let v1 = v1
        .split('.')
        .map(|s| s.parse().unwrap_or(0u8))
        .collect::<Vec<_>>();
    let v2 = v2
        .split('.')
        .map(|s| s.parse().unwrap_or(0u8))
        .collect::<Vec<_>>();

    v1.cmp(&v2)
}

/// Sanitizes a string to be safe for use as a filename on all platforms.
/// Replaces illegal characters with underscores.
pub fn sanitize_filename(name: &str) -> String {
    sanitize_filename::sanitize_with_options(
        name,
        sanitize_filename::Options {
            replacement: "_",
            ..Default::default()
        },
    )
}
