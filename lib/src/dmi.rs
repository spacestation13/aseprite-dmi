use base64::{Engine as _, engine::general_purpose};
use image::{DynamicImage, ImageReader};
use image::{ImageBuffer, Rgba, imageops};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::ffi::OsStr;
use std::fs::{File, create_dir_all, remove_dir_all};
use std::io::{BufWriter, Cursor, Read as _, Write as _};
use std::path::Path;
use thiserror::Error;

use crate::utils::{find_directory, image_to_base64, optimal_size, sanitize_filename};

mod metadata;
mod png;

pub use png::{read_dmi_metadata, save_rgba_dmi};

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
        let total_frames = self
            .states
            .iter()
            .map(|state| state.frames.len() as u32)
            .sum::<u32>() as usize;

        let (sqrt, width, height) = optimal_size(total_frames, self.width, self.height);

        let mut image_buffer = ImageBuffer::new(width, height);

        let mut index: u32 = 0;
        for state in self.states.iter() {
            for frame in state.frames.iter() {
                let (x, y) = (
                    (index as f32 % sqrt) as u32 * self.width,
                    (index as f32 / sqrt) as u32 * self.height,
                );
                imageops::replace(&mut image_buffer, frame, x as i64, y as i64);
                index += 1;
            }
        }

        png::write_dmi_png(
            width,
            height,
            image_buffer.as_raw(),
            path,
            &self.get_metadata(),
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
            let image = reader.decode()?;
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
                        let frame_image =
                            image.crop_imm(dmi.width * x, dmi.height * y, dmi.width, dmi.height);
                        let path = temp.join(format!("{frame_key}.{frame_index}.bytes"));
                        save_image_as_bytes(&frame_image, path)?;
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
    pub fn resize(&mut self, width: u32, height: u32, method: image::imageops::FilterType) {
        self.width = width;
        self.height = height;
        for state in self.states.iter_mut() {
            state.resize(width, height, method);
        }
    }
    pub fn crop(&mut self, x: u32, y: u32, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        for state in self.states.iter_mut() {
            state.crop(x, y, width, height);
        }
    }
    pub fn expand(&mut self, x: u32, y: u32, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        for state in self.states.iter_mut() {
            state.expand(x, y, width, height);
        }
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
                let path = Path::new(&path).join(format!("{frame_key}.{index}.bytes"));
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
        let mut frames = Vec::new();

        for frame in 0..(serialized.frame_count * serialized.dirs) {
            let path = Path::new(&path).join(format!("{}.{}.bytes", serialized.frame_key, frame));
            let image = load_image_from_bytes(path)?;
            frames.push(image);
        }

        Ok(Self {
            name: serialized.name,
            dirs: serialized.dirs,
            frames,
            frame_count: serialized.frame_count,
            delays: serialized.delays,
            loop_: serialized.loop_,
            rewind: serialized.rewind,
            movement: serialized.movement,
            hotspots: serialized.hotspots,
        })
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
    pub fn resize(&mut self, width: u32, height: u32, method: imageops::FilterType) {
        for frame in self.frames.iter_mut() {
            *frame = frame.resize_exact(width, height, method);
        }
    }
    pub fn crop(&mut self, x: u32, y: u32, width: u32, height: u32) {
        for frame in self.frames.iter_mut() {
            *frame = frame.crop(x, y, width, height);
        }
    }
    pub fn expand(&mut self, x: u32, y: u32, width: u32, height: u32) {
        for frame in self.frames.iter_mut() {
            let mut bottom = DynamicImage::new_rgba8(width, height);
            imageops::replace(&mut bottom, frame, x as i64, y as i64);
            *frame = bottom;
        }
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

#[derive(Serialize, Deserialize, Debug)]
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
        let test_path = path.join(format!("{candidate_key}.0.bytes"));
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

fn save_image_as_bytes<P: AsRef<Path>>(image: &DynamicImage, path: P) -> DmiResult<()> {
    let pixels = image.to_rgba8();

    let mut writer = BufWriter::new(File::create(path)?);
    write!(writer, "{}\n{}\n", image.width(), image.height())?;
    writer.write_all(pixels.as_raw())?;

    Ok(())
}

fn load_image_from_bytes<P: AsRef<Path>>(path: P) -> DmiResult<DynamicImage> {
    let mut bytes = Vec::new();

    let mut file = File::open(path)?;
    file.read_to_end(&mut bytes)?;

    let width_nl = bytes
        .iter()
        .position(|&b| b == 0x0A)
        .ok_or(DmiError::MissingData)?;
    let height_nl = bytes[width_nl + 1..]
        .iter()
        .position(|&b| b == 0x0A)
        .map(|p| p + width_nl + 1)
        .ok_or(DmiError::MissingData)?;

    let width: u32 = std::str::from_utf8(&bytes[..width_nl])
        .map_err(|_| DmiError::MissingData)?
        .trim()
        .parse()?;
    let height: u32 = std::str::from_utf8(&bytes[width_nl + 1..height_nl])
        .map_err(|_| DmiError::MissingData)?
        .trim()
        .parse()?;

    let pixel_data = &bytes[height_nl + 1..];
    let expected_len = (width as usize)
        .saturating_mul(height as usize)
        .saturating_mul(4);
    if pixel_data.len() < expected_len {
        return Err(DmiError::MissingData);
    }

    let mut image_buffer: ImageBuffer<Rgba<u8>, Vec<u8>> = ImageBuffer::new(width, height);
    let mut index = 0;
    for pixel in image_buffer.pixels_mut() {
        pixel[0] = pixel_data[index];
        pixel[1] = pixel_data[index + 1];
        pixel[2] = pixel_data[index + 2];
        pixel[3] = pixel_data[index + 3];
        index += 4;
    }

    Ok(DynamicImage::ImageRgba8(image_buffer))
}
