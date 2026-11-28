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
use url::Url;

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

fn http_client(
    timeout: Duration,
    redirect: reqwest::redirect::Policy,
) -> Result<reqwest::blocking::Client> {
    Ok(reqwest::blocking::Client::builder()
        .user_agent(concat!(
            env!("CARGO_PKG_NAME"),
            "/",
            env!("CARGO_PKG_VERSION")
        ))
        .connect_timeout(timeout)
        .timeout(timeout)
        .redirect(redirect)
        .build()?)
}

/// Host and path prefix of the files the extension's registry may download: this repository.
const REGISTRY_HOST: &str = "raw.githubusercontent.com";
const REGISTRY_PATH_PREFIX: &str = "/spacestation13/aseprite-dmi/";

/// Whether a parsed URL is a file in this repository: https, raw.githubusercontent.com, no
/// port, credentials, query or fragment, and a path under `/spacestation13/aseprite-dmi/` made
/// of letters, digits and `-_~/.` only, without empty, `.` or `..` segments. Same rule as
/// `Registry.is_allowed` in scripts/classes/registry.lua.
fn is_registry_url(url: &Url) -> bool {
    let path = url.path();
    url.scheme() == "https"
        && url.host_str() == Some(REGISTRY_HOST)
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && path.starts_with(REGISTRY_PATH_PREFIX)
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_~/.".contains(&b))
        && path[1..]
            .split('/')
            .all(|segment| !matches!(segment, "" | "." | ".."))
}

/// Parses a registry URL, refusing anything outside this repository (see `is_registry_url`).
/// The URL must already be in normal form (parsing must not change it): URL parsers drop tabs
/// and newlines and resolve `.`/`..` segments, which would let `.\t.` leave the repository.
pub fn registry_url(url: &str) -> Result<Url> {
    let refused = || {
        anyhow::anyhow!(
            "Refused {url:?}: not a file in https://{REGISTRY_HOST}{REGISTRY_PATH_PREFIX}"
        )
    };
    let parsed = Url::parse(url).map_err(|_| refused())?;
    if parsed.as_str() != url || !is_registry_url(&parsed) {
        return Err(refused());
    }
    Ok(parsed)
}

/// Downloads a registry file (`registry_url`); redirects are only followed within the
/// registry. See `download`.
pub fn download_registry_file(url: &str, dest: &Path, timeout: Duration) -> Result<u64> {
    let url = registry_url(url)?;
    let redirect = reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 5 {
            attempt.error("too many redirects")
        } else if is_registry_url(attempt.url()) {
            attempt.follow()
        } else {
            attempt.error("redirect outside the registry")
        }
    });
    download_url(url, dest, timeout, redirect)
}

/// Downloads an http(s) URL to `dest` (parent directories are created). The file is written
/// to `<dest>.part` and renamed, so `dest` is never left half-written. Non-2xx statuses are
/// errors. Returns the number of bytes written.
pub fn download(url: &str, dest: &Path, timeout: Duration) -> Result<u64> {
    let parsed = Url::parse(url).with_context(|| format!("Invalid URL: {url}"))?;
    if !matches!(parsed.scheme(), "https" | "http") {
        anyhow::bail!("Only http(s) URLs can be downloaded: {url}");
    }
    download_url(parsed, dest, timeout, reqwest::redirect::Policy::default())
}

fn download_url(
    url: Url,
    dest: &Path,
    timeout: Duration,
    redirect: reqwest::redirect::Policy,
) -> Result<u64> {
    let response = http_client(timeout, redirect)?
        .get(url.clone())
        .send()?
        .error_for_status()?;

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

    let client = http_client(Duration::from_secs(3), reqwest::redirect::Policy::default())?;

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
