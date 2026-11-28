//! `download` against a throwaway local HTTP server: no internet needed.
//! The real GitHub registry is only hit by the `#[ignore]`d test:
//! `cargo test --test download -- --ignored`.

use std::io::{BufRead as _, BufReader, Write as _};
use std::net::TcpListener;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};

use dmi::{download, download_registry_file, registry_url};

const BODY: &str = "GIMP Palette\nName: Test\n255   0   0\tRed\n";

/// Serves `/ok` (200 + BODY), `/slow` (never answers) and anything else as 404.
fn serve() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                reader.read_line(&mut request_line).unwrap();
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap() == 0 || header == "\r\n" {
                        break;
                    }
                }
                let path = request_line.split_whitespace().nth(1).unwrap_or("/");
                let response = match path {
                    "/ok" => format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{BODY}",
                        BODY.len()
                    ),
                    "/slow" => {
                        thread::sleep(Duration::from_secs(5));
                        return;
                    }
                    _ => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                        .to_string(),
                };
                let _ = stream.write_all(response.as_bytes());
            });
        }
    });
    format!("http://{addr}")
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("aseprite-dmi-test-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[test]
fn downloads_into_new_directories() {
    let base = serve();
    let dir = temp_dir("download-ok");
    let dest = dir.join("nested").join("test.gpl");

    let written = download(&format!("{base}/ok"), &dest, Duration::from_secs(5)).unwrap();

    assert_eq!(written, BODY.len() as u64);
    assert_eq!(std::fs::read_to_string(&dest).unwrap(), BODY);
    assert!(!dest.with_extension("gpl.part").exists());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn http_errors_keep_the_old_file() {
    let base = serve();
    let dir = temp_dir("download-404");
    std::fs::create_dir_all(&dir).unwrap();
    let dest = dir.join("cached.json");
    std::fs::write(&dest, "old").unwrap();

    let err = download(&format!("{base}/missing"), &dest, Duration::from_secs(5)).unwrap_err();

    assert!(err.to_string().contains("404"), "{err}");
    assert_eq!(std::fs::read_to_string(&dest).unwrap(), "old");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn times_out() {
    let base = serve();
    let dir = temp_dir("download-slow");
    let dest = dir.join("slow.json");

    let start = Instant::now();
    assert!(download(&format!("{base}/slow"), &dest, Duration::from_secs(1)).is_err());
    assert!(
        start.elapsed() < Duration::from_secs(4),
        "{:?}",
        start.elapsed()
    );
    assert!(!dest.exists());
}

#[test]
fn rejects_other_schemes() {
    let dest = temp_dir("download-scheme").join("x");
    assert!(download("file:///etc/passwd", &dest, Duration::from_secs(1)).is_err());
    assert!(download("ftp://example.com/x", &dest, Duration::from_secs(1)).is_err());
}

#[test]
fn registry_urls_stay_in_this_repository() {
    for ok in [
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes.json",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/some-branch/registry/palettes/goon_v2.gpl",
    ] {
        assert!(registry_url(ok).is_ok(), "{ok}");
    }
    for refused in [
        // URL parsers drop tabs/CR/LF: `.\t.` would become `..` and leave the repository.
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.\t./.\t./evil/repo/main/x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.\n./.\r./evil/repo/main/x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x .gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.%2E/.%2e/evil/repo/main/x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/../../evil/repo/main/x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/./x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main//x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi\\main\\x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi-evil/main/x.gpl",
        "https://raw.githubusercontent.com/example/codebase/master/.github/palette.png",
        "http://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl",
        "https://raw.githubusercontent.com:8443/spacestation13/aseprite-dmi/main/x.gpl",
        "https://user@raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl",
        "https://raw.githubusercontent.com.evil.example/spacestation13/aseprite-dmi/main/x.gpl",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl?token=1",
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl#frag",
        "https://example.com/spacestation13/aseprite-dmi/main/x.gpl",
        "not a url",
    ] {
        assert!(registry_url(refused).is_err(), "{refused:?}");
    }
}

#[test]
fn registry_download_refuses_other_urls_without_connecting() {
    // A local server is a valid http URL, but not the registry: refused before any request.
    let base = serve();
    let dir = temp_dir("download-registry-refused");
    let dest = dir.join("x.gpl");
    let err =
        download_registry_file(&format!("{base}/ok"), &dest, Duration::from_secs(5)).unwrap_err();
    assert!(err.to_string().contains("Refused"), "{err}");
    assert!(!dest.exists());
    let tab = "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.\t./x.gpl";
    assert!(download_registry_file(tab, &dest, Duration::from_secs(1)).is_err());
    assert!(!dest.exists());
}

#[test]
#[ignore = "needs internet"]
fn downloads_the_github_registry() {
    let dir = temp_dir("download-github");
    let dest = dir.join("palettes.json");
    download_registry_file(
        "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes.json",
        &dest,
        Duration::from_secs(10),
    )
    .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&std::fs::read(&dest).unwrap()).unwrap();
    assert!(json["palettes"].is_array());
    std::fs::remove_dir_all(&dir).unwrap();
}
