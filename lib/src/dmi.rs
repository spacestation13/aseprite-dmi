use base64::{Engine as _, engine::general_purpose};
use image::{DynamicImage, ImageReader};
use image::{ImageBuffer, Rgba, imageops};
use serde::{Deserialize, Serialize};
use std::borrow::{Borrow, Cow};
use std::cmp::Ordering;
use std::ffi::OsStr;
use std::fs::{File, create_dir_all, remove_dir_all};
use std::io::{BufRead as _, BufReader, BufWriter, Cursor, Read as _, Write as _};
use std::path::{Path, PathBuf};
use thiserror::Error;

use crate::utils::{find_directory, image_to_base64, optimal_size, sanitize_filename};

mod metadata;
mod operations;
mod png;
mod raw;

pub use operations::{CombineLayout, CombinePlan, combine_plan};
pub use png::{read_dmi_metadata, save_rgba_dmi};
pub use raw::RawSession;

// This leaves memory for Aseprite while bounding the decoded atlas plus two frame buffers.
const MAX_STREAMING_IMPORT_BYTES: u64 = 256 * 1024 * 1024;

type DmiResult<T> = Result<T, DmiError>;

#[derive(Error, Debug)]
#[error(transparent)]
pub enum DmiError {
    Anyhow(#[from] anyhow::Error),
    Io(#[from] std::io::Error),
    Image(#[from] image::ImageError),
    PngDecoding(#[from] ::png::DecodingError),
    PngEncoding(#[from] ::png::EncodingError),
    ParseInt(#[from] std::num::ParseIntError),
    ParseFloat(#[from] std::num::ParseFloatError),
    DecodeError(#[from] base64::DecodeError),
    #[error("Missing data")]
    MissingData,
    #[error("Missing ZTXT chunk")]
    MissingZTXTChunk,
    #[error("Missing metadata header")]
    MissingMetadataHeader,
    #[error("Invalid metadata version")]
    InvalidMetadataVersion,
    #[error("Missing metadata value")]
    MissingMetadataValue,
    #[error("State info out of order")]
    OutOfOrderStateInfo,
    #[error("Unknown metadata key")]
    UnknownMetadataKey,
    #[error("DMI metadata does not match the image layout")]
    ImageSizeMismatch,
    #[error("DMI image is too large to open safely")]
    ImageTooLarge,
    #[error("Failed to find available directory")]
    FindDirError,
    #[error("Directory does not exist")]
    DirDoesNotExist,
    #[error("State has no frames or directions")]
    EmptyState,
    #[error("Only states with 2 to 8 directions can be split")]
    CannotSplit,
    #[error("Combined states have 1 to 8 directions")]
    InvalidDirections,
    #[error("Combining needs at least one state, and two to combine directions first")]
    NotEnoughStates,
}

#[derive(Debug)]
pub struct Dmi {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub states: Vec<State>,
}

impl Dmi {
    pub fn new(name: String, width: u32, height: u32) -> Dmi {
        Dmi {
            name,
            width,
            height,
            states: Vec::new(),
        }
    }
    pub fn open<P>(path: P) -> DmiResult<Self>
    where
        P: AsRef<Path>,
    {
        let metadata = read_dmi_metadata(&path)?;

        let mut dmi = Self::new(
            path.as_ref()
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unnamed")
                .into(),
            32,
            32,
        );

        dmi.set_metadata(&metadata)?;

        let (image_width, image_height) = Self::image_dimensions(&path)?;
        let (grid_width, grid_height) = dmi.validate_image_layout(image_width, image_height)?;

        let mut reader = ImageReader::open(&path)?;
        reader.set_format(image::ImageFormat::Png);

        let mut image = reader.decode()?;

        let mut index = 0;
        for state in dmi.states.iter_mut() {
            normalize_state_delays(state)?;

            for _ in 0..state.frame_count {
                for _ in 0..state.dirs {
                    let x = index % grid_width;
                    let y = index / grid_width;
                    if x >= grid_width || y >= grid_height {
                        return Err(DmiError::ImageSizeMismatch);
                    }
                    let image = image.crop(dmi.width * x, dmi.height * y, dmi.width, dmi.height);
                    if image.width() != dmi.width || image.height() != dmi.height {
                        return Err(DmiError::ImageSizeMismatch);
                    }
                    state.frames.push(image);
                    index += 1;
                }
            }
        }

        Ok(dmi)
    }
    pub fn save<P>(&self, path: P) -> DmiResult<()>
    where
        P: AsRef<Path>,
    {
        let frames = || {
            self.states
                .iter()
                .flat_map(|state| &state.frames)
                .map(|frame| {
                    Ok(match frame.as_rgba8() {
                        Some(rgba) => Cow::Borrowed(rgba),
                        None => Cow::Owned(frame.to_rgba8()),
                    })
                })
        };
        let total = self.states.iter().map(|state| state.frames.len()).sum();
        write_atlas(
            path,
            self.width,
            self.height,
            &self.get_metadata(),
            total,
            frames,
        )
    }
    /// Saves straight from the frame cache, reading one frame at a time instead of the whole DMI.
    pub fn save_serialized<P>(serialized: &SerializedDmi, path: P) -> DmiResult<()>
    where
        P: AsRef<Path>,
    {
        let temp = Path::new(&serialized.temp);
        if !temp.exists() {
            return Err(DmiError::DirDoesNotExist);
        }
        let metadata = Dmi {
            name: serialized.name.clone(),
            width: serialized.width,
            height: serialized.height,
            states: serialized
                .states
                .iter()
                .map(State::without_frames)
                .collect(),
        }
        .get_metadata();
        let frames = || {
            serialized.states.iter().flat_map(|state| {
                (0..state.frame_count * state.dirs).map(move |index| {
                    let path = frame_path(temp, &state.frame_key, index);
                    Ok(load_image_from_bytes(path)?.into_rgba8())
                })
            })
        };
        let total = serialized
            .states
            .iter()
            .map(|state| (state.frame_count * state.dirs) as usize)
            .sum();
        write_atlas(
            path,
            serialized.width,
            serialized.height,
            &metadata,
            total,
            frames,
        )
    }
    pub fn to_serialized<P>(&self, path: P, exact_path: bool) -> DmiResult<SerializedDmi>
    where
        P: AsRef<Path>,
    {
        let mut path = path.as_ref().to_path_buf();

        if !exact_path {
            path = find_directory(path.join(&self.name));
        }

        if path.exists() {
            remove_dir_all(&path)?;
        }

        create_dir_all(&path)?;

        let mut states = Vec::new();

        for state in self.states.iter() {
            states.push(state.to_serialized(&path)?);
        }

        Ok(SerializedDmi {
            name: self.name.clone(),
            width: self.width,
            height: self.height,
            states,
            temp: path.to_str().unwrap_or_default().to_string(),
        })
    }
    pub fn from_serialized(serialized: SerializedDmi) -> DmiResult<Dmi> {
        if !Path::new(&serialized.temp).exists() {
            return Err(DmiError::DirDoesNotExist);
        }

        let mut states = Vec::new();

        for state in serialized.states {
            states.push(State::from_serialized(state, &serialized.temp)?);
        }

        Ok(Self {
            name: serialized.name,
            width: serialized.width,
            height: serialized.height,
            states,
        })
    }
    /// Streams each frame to the temporary cache instead of retaining every cropped frame.
    /// This avoids the allocation spike that can crash Aseprite when opening large DMIs.
    pub fn open_serialized<P, Q>(source: P, temp: Q) -> DmiResult<SerializedDmi>
    where
        P: AsRef<Path>,
        Q: AsRef<Path>,
    {
        let source = source.as_ref();
        let metadata = read_dmi_metadata(source)?;
        let mut dmi = Self::new(
            source
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("unnamed")
                .into(),
            32,
            32,
        );
        dmi.set_metadata(&metadata)?;

        let (image_width, image_height) = Self::image_dimensions(source)?;
        let (grid_width, _) = dmi.validate_image_layout(image_width, image_height)?;
        dmi.validate_streaming_import_memory(image_width, image_height)?;

        let temp = find_directory(temp.as_ref().join(&dmi.name));
        create_dir_all(&temp)?;

        let result = (|| {
            let mut reader = ImageReader::open(source)?;
            reader.set_format(image::ImageFormat::Png);
            let image = reader.decode()?.into_rgba8();
            let mut states = Vec::new();
            let mut tile_index = 0_u64;

            for state in dmi.states.iter_mut() {
                normalize_state_delays(state)?;
                let frame_key = frame_key(&temp, &state.name)?;
                let mut frame_index = 0_u32;

                for _ in 0..state.frame_count {
                    for _ in 0..state.dirs {
                        let x = u32::try_from(tile_index % u64::from(grid_width))
                            .map_err(|_| DmiError::ImageSizeMismatch)?;
                        let y = u32::try_from(tile_index / u64::from(grid_width))
                            .map_err(|_| DmiError::ImageSizeMismatch)?;
                        write_tile_bytes(
                            &image,
                            dmi.width * x,
                            dmi.height * y,
                            dmi.width,
                            dmi.height,
                            frame_path(&temp, &frame_key, frame_index),
                        )?;
                        tile_index = tile_index
                            .checked_add(1)
                            .ok_or(DmiError::ImageSizeMismatch)?;
                        frame_index = frame_index
                            .checked_add(1)
                            .ok_or(DmiError::ImageSizeMismatch)?;
                    }
                }

                states.push(SerializedState {
                    name: state.name.clone(),
                    dirs: state.dirs,
                    frame_key,
                    frame_count: state.frame_count,
                    delays: state.delays.clone(),
                    loop_: state.loop_,
                    rewind: state.rewind,
                    movement: state.movement,
                    hotspots: state.hotspots.clone(),
                });
            }

            Ok(SerializedDmi {
                name: dmi.name.clone(),
                width: dmi.width,
                height: dmi.height,
                states,
                temp: temp.to_str().unwrap_or_default().to_string(),
            })
        })();

        if result.is_err() {
            let _ = remove_dir_all(&temp);
        }

        result
    }
    /// Scales every frame in the frame cache to `width` x `height`.
    pub fn resize_serialized(
        serialized: &SerializedDmi,
        width: u32,
        height: u32,
        method: imageops::FilterType,
    ) -> DmiResult<()> {
        edit_cached_frames(serialized, |frame| {
            frame.resize_exact(width, height, method)
        })
    }
    /// Crops every frame in the frame cache to the given rectangle.
    pub fn crop_serialized(
        serialized: &SerializedDmi,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) -> DmiResult<()> {
        edit_cached_frames(serialized, |frame| frame.crop_imm(x, y, width, height))
    }
    /// Pastes every frame in the frame cache at (`x`, `y`) of a new transparent
    /// `width` x `height` canvas.
    pub fn expand_serialized(
        serialized: &SerializedDmi,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) -> DmiResult<()> {
        edit_cached_frames(serialized, |frame| {
            let mut canvas = DynamicImage::new_rgba8(width, height);
            imageops::replace(&mut canvas, frame, i64::from(x), i64::from(y));
            canvas
        })
    }

    fn image_dimensions<P>(path: P) -> DmiResult<(u32, u32)>
    where
        P: AsRef<Path>,
    {
        let mut reader = ImageReader::open(path)?;
        reader.set_format(image::ImageFormat::Png);
        Ok(reader.into_dimensions()?)
    }

    fn validate_streaming_import_memory(
        &self,
        image_width: u32,
        image_height: u32,
    ) -> DmiResult<()> {
        let atlas_bytes = rgba_bytes(image_width, image_height)?;
        let frame_bytes = rgba_bytes(self.width, self.height)?;
        let working_set = atlas_bytes
            .checked_add(frame_bytes.checked_mul(2).ok_or(DmiError::ImageTooLarge)?)
            .ok_or(DmiError::ImageTooLarge)?;

        if working_set > MAX_STREAMING_IMPORT_BYTES {
            return Err(DmiError::ImageTooLarge);
        }

        Ok(())
    }

    fn validate_image_layout(&self, image_width: u32, image_height: u32) -> DmiResult<(u32, u32)> {
        if self.width == 0 || self.height == 0 {
            return Err(DmiError::ImageSizeMismatch);
        }

        let grid_width = image_width / self.width;
        let grid_height = image_height / self.height;
        if grid_width == 0 || grid_height == 0 {
            return Err(DmiError::ImageSizeMismatch);
        }

        let available_tiles = u64::from(grid_width)
            .checked_mul(u64::from(grid_height))
            .ok_or(DmiError::ImageSizeMismatch)?;
        let required_tiles = self.states.iter().try_fold(0_u64, |total, state| {
            let state_tiles = u64::from(state.frame_count)
                .checked_mul(u64::from(state.dirs))
                .ok_or(DmiError::ImageSizeMismatch)?;
            total
                .checked_add(state_tiles)
                .ok_or(DmiError::ImageSizeMismatch)
        })?;

        if required_tiles > available_tiles {
            return Err(DmiError::ImageSizeMismatch);
        }

        Ok((grid_width, grid_height))
    }
}

#[derive(Debug)]
pub struct State {
    pub name: String,
    pub dirs: u32,
    pub frames: Vec<DynamicImage>,
    pub frame_count: u32,
    pub delays: Vec<f32>,
    pub loop_: u32,
    pub rewind: bool,
    pub movement: bool,
    pub hotspots: Vec<String>,
}

impl State {
    fn new(name: String) -> Self {
        State {
            name,
            dirs: 1,
            frames: Vec::new(),
            frame_count: 0,
            delays: Vec::new(),
            loop_: 0,
            rewind: false,
            movement: false,
            hotspots: Vec::new(),
        }
    }
    pub fn new_blank(name: String, width: u32, height: u32) -> Self {
        let mut state = Self::new(name);
        state.frames.push(DynamicImage::new_rgba8(width, height));
        state.frame_count = 1;
        state
    }
    pub fn to_serialized<P>(&self, path: P) -> DmiResult<SerializedState>
    where
        P: AsRef<OsStr>,
    {
        let path = Path::new(&path);

        if !path.exists() {
            create_dir_all(path)?;
        }

        let frame_key = frame_key(path, &self.name)?;

        let mut index: u32 = 0;
        for frame in 0..self.frame_count {
            for direction in 0..self.dirs {
                let image = &self.frames[(frame * self.dirs + direction) as usize];
                let path = frame_path(path, &frame_key, index);
                save_image_as_bytes(image, &path)?;
                index += 1;
            }
        }

        Ok(SerializedState {
            name: self.name.clone(),
            dirs: self.dirs,
            frame_key,
            frame_count: self.frame_count,
            delays: self.delays.clone(),
            loop_: self.loop_,
            rewind: self.rewind,
            movement: self.movement,
            hotspots: self.hotspots.clone(),
        })
    }
    pub fn from_serialized<P>(serialized: SerializedState, path: P) -> DmiResult<Self>
    where
        P: AsRef<OsStr>,
    {
        let mut state = Self::without_frames(&serialized);
        for frame in 0..(serialized.frame_count * serialized.dirs) {
            let path = frame_path(Path::new(&path), &serialized.frame_key, frame);
            state.frames.push(load_image_from_bytes(path)?);
        }
        Ok(state)
    }
    /// The state's metadata, with no frames loaded.
    fn without_frames(serialized: &SerializedState) -> Self {
        Self {
            name: serialized.name.clone(),
            dirs: serialized.dirs,
            frames: Vec::new(),
            frame_count: serialized.frame_count,
            delays: serialized.delays.clone(),
            loop_: serialized.loop_,
            rewind: serialized.rewind,
            movement: serialized.movement,
            hotspots: serialized.hotspots.clone(),
        }
    }
    pub fn into_clipboard(self) -> DmiResult<ClipboardState> {
        let frames = self
            .frames
            .iter()
            .map(image_to_base64)
            .collect::<Result<Vec<_>, _>>()?;

        Ok(ClipboardState {
            name: self.name,
            dirs: self.dirs,
            frames,
            delays: self.delays,
            loop_: self.loop_,
            rewind: self.rewind,
            movement: self.movement,
            hotspots: self.hotspots,
        })
    }
    pub fn from_clipboard(state: ClipboardState, width: u32, height: u32) -> DmiResult<Self> {
        let mut frames = Vec::new();

        for frame in state.frames.iter() {
            let base64 = frame
                .split(',')
                .nth(1)
                .ok_or_else(|| DmiError::MissingData)?;
            let image_data = general_purpose::STANDARD.decode(base64)?;
            let reader = ImageReader::with_format(Cursor::new(image_data), image::ImageFormat::Png);
            let mut image = reader.decode()?;

            if image.width() != width || image.height() != height {
                image = image.resize(width, height, imageops::FilterType::Nearest);
            }

            frames.push(image);
        }

        let frame_count = state.frames.len() as u32 / state.dirs;

        Ok(Self {
            name: state.name,
            dirs: state.dirs,
            frames,
            frame_count,
            delays: state.delays,
            loop_: state.loop_,
            rewind: state.rewind,
            movement: state.movement,
            hotspots: state.hotspots,
        })
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct SerializedDmi {
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub states: Vec<SerializedState>,
    pub temp: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct SerializedState {
    pub name: String,
    pub dirs: u32,
    pub frame_key: String,
    pub frame_count: u32,
    pub delays: Vec<f32>,
    pub loop_: u32,
    pub rewind: bool,
    pub movement: bool,
    pub hotspots: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct ClipboardState {
    pub name: String,
    pub dirs: u32,
    pub frames: Vec<String>,
    pub delays: Vec<f32>,
    pub loop_: u32,
    pub rewind: bool,
    pub movement: bool,
    pub hotspots: Vec<String>,
}

fn normalize_state_delays(state: &mut State) -> DmiResult<()> {
    let frame_count = state.frame_count as usize;
    if !state.delays.is_empty() {
        let delay_count = state.delays.len();
        match delay_count.cmp(&frame_count) {
            Ordering::Less => {
                let last_delay = *state.delays.last().ok_or(DmiError::MissingData)?;
                let additional_delays = vec![last_delay; frame_count - delay_count];
                state.delays.extend(additional_delays);
            }
            Ordering::Greater => state.delays.truncate(frame_count),
            Ordering::Equal => {}
        }
    } else if state.frame_count > 1 {
        state.delays = vec![1.; frame_count];
    }

    Ok(())
}

fn frame_key(path: &Path, name: &str) -> DmiResult<String> {
    let safe_name = sanitize_filename(name);
    let safe_name = if safe_name.is_empty() {
        "state".to_string()
    } else {
        safe_name
    };
    let mut index = 1_u32;

    loop {
        let candidate_key = format!("{safe_name}.{index}");
        let test_path = frame_path(path, &candidate_key, 0);
        if !test_path.exists() {
            return Ok(candidate_key);
        }

        index = index.checked_add(1).ok_or(DmiError::FindDirError)?;
    }
}

fn rgba_bytes(width: u32, height: u32) -> DmiResult<u64> {
    u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(DmiError::ImageTooLarge)
}

/// Writes `total` frames into the DMI's square-ish grid, one row of tiles at a time, so only a
/// band of the atlas is ever in memory. `frames` is called once per pass over the image.
fn write_atlas<P, F, I, C>(
    path: P,
    tile_width: u32,
    tile_height: u32,
    metadata: &str,
    total: usize,
    frames: F,
) -> DmiResult<()>
where
    P: AsRef<Path>,
    F: Fn() -> I,
    I: Iterator<Item = DmiResult<C>>,
    C: Borrow<image::RgbaImage>,
{
    let (sqrt, width, height) = optimal_size(total, tile_width, tile_height);
    let columns = sqrt as usize;
    let (tile_w, tile_h) = (tile_width as usize, tile_height as usize);
    let row_stride = width as usize * 4;
    png::write_dmi_png(width, height, path, metadata, |sink| {
        let mut frames = frames();
        let mut band = vec![0u8; row_stride * tile_h];
        for _ in 0..height as usize / tile_h {
            band.fill(0);
            for (column, frame) in frames.by_ref().take(columns).enumerate() {
                let frame = frame?;
                let frame: &image::RgbaImage = frame.borrow();
                let frame_stride = frame.width() as usize * 4;
                let copy_w = frame_stride.min(tile_w * 4);
                let rows = frame.as_raw().chunks_exact(frame_stride).take(tile_h);
                for (y, src) in rows.enumerate() {
                    let start = y * row_stride + column * tile_w * 4;
                    band[start..start + copy_w].copy_from_slice(&src[..copy_w]);
                }
            }
            sink(&band)?;
        }
        Ok(())
    })
}

/// The cache file of a state's frame image: `index` = frame * dirs + dir.
fn frame_path(dir: &Path, frame_key: &str, index: u32) -> PathBuf {
    dir.join(format!("{frame_key}.{index}.bytes"))
}

fn save_image_as_bytes<P: AsRef<Path>>(image: &DynamicImage, path: P) -> DmiResult<()> {
    // Frames are normally RGBA8 already; only convert (and copy) when they aren't.
    let converted;
    let rgba = match image.as_rgba8() {
        Some(rgba) => rgba,
        None => {
            converted = image.to_rgba8();
            &converted
        }
    };
    write_frame_bytes(path, rgba.width(), rgba.height(), rgba.as_raw())
}

/// Writes a frame cache file: the width and height as text lines, then the RGBA pixels.
pub fn write_frame_bytes<P: AsRef<Path>>(
    path: P,
    width: u32,
    height: u32,
    rgba: &[u8],
) -> DmiResult<()> {
    if u64::try_from(rgba.len()).ok() != Some(rgba_bytes(width, height)?) {
        return Err(DmiError::MissingData);
    }

    let mut writer = BufWriter::new(File::create(path)?);
    write!(writer, "{width}\n{height}\n")?;
    writer.write_all(rgba)?;
    writer.flush()?;

    Ok(())
}

/// Writes the `width` x `height` tile at pixel (`left`, `top`) of `atlas` as a frame cache file,
/// straight from the atlas rows without an intermediate copy of the tile.
fn write_tile_bytes<P: AsRef<Path>>(
    atlas: &image::RgbaImage,
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    path: P,
) -> DmiResult<()> {
    let stride = atlas.width() as usize * 4;
    let tile_stride = width as usize * 4;
    let mut writer = BufWriter::new(File::create(path)?);
    write!(writer, "{width}\n{height}\n")?;
    for y in top..top + height {
        let start = y as usize * stride + left as usize * 4;
        writer.write_all(&atlas.as_raw()[start..start + tile_stride])?;
    }
    writer.flush()?;

    Ok(())
}

fn load_image_from_bytes<P: AsRef<Path>>(path: P) -> DmiResult<DynamicImage> {
    let file = File::open(path)?;
    let file_len = file.metadata()?.len();
    let mut reader = BufReader::new(file);

    let mut line = String::new();
    let mut header_len = 0_u64;
    let mut dimensions = [0_u32; 2];
    for dimension in &mut dimensions {
        line.clear();
        let read = reader.read_line(&mut line)?;
        if read == 0 || !line.ends_with('\n') {
            return Err(DmiError::MissingData);
        }
        header_len += read as u64;
        *dimension = line.trim().parse()?;
    }
    let [width, height] = dimensions;

    let expected_len = rgba_bytes(width, height)?;
    if file_len.saturating_sub(header_len) < expected_len {
        return Err(DmiError::MissingData);
    }

    // Read the pixels straight into the image buffer.
    let mut pixels = vec![0u8; expected_len as usize];
    reader.read_exact(&mut pixels)?;
    let image =
        ImageBuffer::<Rgba<u8>, _>::from_raw(width, height, pixels).ok_or(DmiError::MissingData)?;

    Ok(DynamicImage::ImageRgba8(image))
}

/// Rewrites every frame of a DMI in the frame cache through `edit`, one frame at a time instead
/// of loading the whole DMI.
fn edit_cached_frames(
    serialized: &SerializedDmi,
    edit: impl Fn(&DynamicImage) -> DynamicImage,
) -> DmiResult<()> {
    let temp = Path::new(&serialized.temp);
    if !temp.exists() {
        return Err(DmiError::DirDoesNotExist);
    }
    for state in &serialized.states {
        for index in 0..state.frame_count * state.dirs {
            let path = frame_path(temp, &state.frame_key, index);
            save_image_as_bytes(&edit(&load_image_from_bytes(&path)?), path)?;
        }
    }
    Ok(())
}
