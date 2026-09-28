#[cfg(not(windows))]
extern crate pkg_config;

fn main() {
    #[cfg(not(windows))]
    pkg_config::Config::new()
        .atleast_version("5.4")
        .probe("lua")
        .unwrap();
}
