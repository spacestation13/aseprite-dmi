//! Raw DMI mode: a .dmi opened as a plain spritesheet. The session holds what saving it back
//! needs, and is stored in the sprite's data so it survives saving the sprite elsewhere.

use std::fs::{self, create_dir_all};
use std::path::{Path, PathBuf};

use super::{Dmi, DmiResult, read_dmi_metadata};

const MARKER: &str = "\n__aseprite_dmi_raw__\n";
const VERSION: &str = "v1\n";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawSession {
    pub original_width: u32,
    pub original_height: u32,
    pub cell_width: u32,
    pub cell_height: u32,
    pub metadata: String,
}

impl RawSession {
    /// Reads the session of `dmi` and copies it to `temp/raw_open.png`, which Aseprite opens
    /// with its own PNG loader. Returns the session and the copy's path.
    pub fn open<P, Q>(dmi: P, temp: Q) -> DmiResult<(Self, PathBuf)>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
    {
        let dmi = dmi.as_ref();
        let metadata = read_dmi_metadata(dmi)?;
        let mut cells = Dmi::new(String::new(), 0, 0);
        cells.set_metadata(&metadata)?;
        let (original_width, original_height) = Dmi::image_dimensions(dmi)?;

        let temp = temp.as_ref();
        create_dir_all(temp)?;
        let png = temp.join("raw_open.png");
        fs::copy(dmi, &png)?;

        let session = Self {
            original_width,
            original_height,
            cell_width: cells.width,
            cell_height: cells.height,
            metadata,
        };
        Ok((session, png))
    }

    /// The record appended to the sprite's data.
    pub fn encode(&self) -> String {
        format!(
            "{MARKER}{VERSION}{}\n{}\n{}\n{}\n{}\n{}",
            self.original_width,
            self.original_height,
            self.cell_width,
            self.cell_height,
            self.metadata.len(),
            self.metadata
        )
    }

    /// The first session record in `data`, if it has a valid one.
    pub fn decode(data: &[u8]) -> Option<Self> {
        let prefix = format!("{MARKER}{VERSION}");
        let start = find(data, prefix.as_bytes())? + prefix.len();
        let mut rest = &data[start..];
        let mut numbers = [0_u32; 5];
        for number in &mut numbers {
            let end = rest.iter().position(|&b| b == b'\n')?;
            let digits = &rest[..end];
            if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
                return None;
            }
            *number = std::str::from_utf8(digits).ok()?.parse().ok()?;
            rest = &rest[end + 1..];
        }
        let [
            original_width,
            original_height,
            cell_width,
            cell_height,
            length,
        ] = numbers;
        let metadata = rest.get(..length as usize)?;

        Some(Self {
            original_width,
            original_height,
            cell_width,
            cell_height,
            metadata: String::from_utf8(metadata.to_vec()).ok()?,
        })
    }

    /// Whether `data` was marked as a raw DMI sprite, even if its session record is unreadable.
    pub fn is_marked(data: &[u8]) -> bool {
        find(data, MARKER.as_bytes()).is_some()
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}
