use serde_json::Value;
use std::cmp::Ordering;
use std::env::current_dir;
use std::fs::read_to_string;

use dmi::check_latest_version;

/// Release guard, not a regular test: the crate and package.json versions must match and be newer
/// than the latest GitHub release. Needs network. CI runs it on `v*` tags with `-- --ignored`.
#[test]
#[ignore = "release check; run with --ignored when tagging"]
fn check_version() {
    let crate_version = env!("CARGO_PKG_VERSION");

    let package = read_to_string(current_dir().unwrap().join("../package.json")).unwrap();
    let package = serde_json::from_str::<Value>(&package).unwrap();

    let package_version = package["version"].as_str().unwrap();

    assert_eq!(crate_version, package_version, "Version mismatch");

    let version = check_latest_version().unwrap();

    match version {
        Ordering::Less | Ordering::Equal => panic!("Version must be greater than last release"),
        _ => {}
    }
}
