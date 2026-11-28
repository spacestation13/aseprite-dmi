mod colors;
mod dmi;
mod errors;
mod lua;
mod macros;
mod utils;

pub use colors::{ColorCount, collect_colors};
pub use dmi::*;
pub use utils::{check_latest_version, download, download_registry_file, registry_url};
