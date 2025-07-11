use mlua::prelude::*;
use native_dialog::DialogBuilder;
use std::cmp::Ordering;
use std::ffi::OsStr;
use std::fs::{self, read_dir, remove_dir_all};
use std::path::Path;

use crate::dmi::*;
use crate::errors::ExternalError;
use crate::macros::safe;
use crate::utils::check_latest_version;

#[mlua::lua_module(name = "dmi_module")]
fn module(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;

    exports.set("new_file", lua.create_function(safe!(new_file))?)?;
    exports.set("open_file", lua.create_function(safe!(open_file))?)?;
    exports.set("save_file", lua.create_function(safe!(save_file))?)?;
    exports.set("new_state", lua.create_function(safe!(new_state))?)?;
    exports.set("copy_state", lua.create_function(safe!(copy_state))?)?;
    exports.set("paste_state", lua.create_function(safe!(paste_state))?)?;
    exports.set("resize", lua.create_function(safe!(resize))?)?;
    exports.set("crop", lua.create_function(safe!(crop))?)?;
    exports.set("expand", lua.create_function(safe!(expand))?)?;
    exports.set("overlay_color", lua.create_function(overlay_color)?)?;
    exports.set("remove_dir", lua.create_function(safe!(remove_dir))?)?;
    exports.set("exists", lua.create_function(exists)?)?;
    exports.set("check_update", lua.create_function(check_update)?)?;
    exports.set("open_repo", lua.create_function(safe!(open_repo))?)?;
    exports.set("instances", lua.create_function(instances)?)?;
    exports.set("save_dialog", lua.create_function(safe!(save_dialog))?)?;
    exports.set("import_png", lua.create_function(safe!(import_png))?)?;

    Ok(exports)
}

fn new_file(
    lua: &Lua,
    (name, width, height, temp): (String, u32, u32, String),
) -> LuaResult<LuaTable> {
    let dmi = Dmi::new(name, width, height).to_serialized(temp, false)?;
    let table = dmi.into_lua_table(lua)?;

    Ok(table)
}

fn open_file(lua: &Lua, (filename, temp): (String, String)) -> LuaResult<LuaTable> {
    if !Path::new(&filename).is_file() {
        Err("File does not exist".to_string()).into_lua_err()?
    }

    let dmi = Dmi::open(filename)?.to_serialized(temp, false)?;
    let table: LuaTable = dmi.into_lua_table(lua)?;

    Ok(table)
}

fn save_file(_: &Lua, (dmi, filename): (LuaTable, String)) -> LuaResult<LuaValue> {
    let dmi = SerializedDmi::from_lua_table(dmi)?;
    let dmi = Dmi::from_serialized(dmi)?;
    dmi.save(filename)?;

    Ok(LuaValue::Nil)
}

fn new_state(
    lua: &Lua,
    (width, height, temp, name): (u32, u32, String, Option<String>),
) -> LuaResult<LuaTable> {
    if !Path::new(&temp).exists() {
        Err("Temp directory does not exist".to_string()).into_lua_err()?
    }

    let state_name = name.unwrap_or(String::new());
    let state = State::new_blank(state_name, width, height).to_serialized(temp)?;
    let table = state.into_lua_table(lua)?;

    Ok(table)
}

fn copy_state(_: &Lua, (state, temp): (LuaTable, String)) -> LuaResult<LuaValue> {
    if !Path::new(&temp).exists() {
        Err("Temp directory does not exist".to_string()).into_lua_err()?
    }

    let state = SerializedState::from_lua_table(state)?;
    let state = State::from_serialized(state, temp)?.into_clipboard()?;
    let state = serde_json::to_string(&state).map_err(ExternalError::Serde)?;

    let mut clipboard = arboard::Clipboard::new().map_err(ExternalError::Arboard)?;
    clipboard.set_text(state).map_err(ExternalError::Arboard)?;

    Ok(LuaValue::Nil)
}

fn paste_state(lua: &Lua, (width, height, temp): (u32, u32, String)) -> LuaResult<LuaTable> {
    if !Path::new(&temp).exists() {
        Err("Temp directory does not exist".to_string()).into_lua_err()?
    }

    let mut clipboard = arboard::Clipboard::new().map_err(ExternalError::Arboard)?;
    let state = clipboard.get_text().map_err(ExternalError::Arboard)?;
    let state = serde_json::from_str::<ClipboardState>(&state).map_err(ExternalError::Serde)?;
    let state = State::from_clipboard(state, width, height)?.to_serialized(temp)?;
    let table = state.into_lua_table(lua)?;

    Ok(table)
}

fn resize(
    _: &Lua,
    (dmi, width, height, method): (LuaTable, u32, u32, String),
) -> LuaResult<LuaValue> {
    let dmi = SerializedDmi::from_lua_table(dmi)?;

    let temp = dmi.temp.clone();
    let method = match method.as_str() {
        "nearest" => image::imageops::FilterType::Nearest,
        "triangle" => image::imageops::FilterType::Triangle,
        "catmullrom" => image::imageops::FilterType::CatmullRom,
        "gaussian" => image::imageops::FilterType::Gaussian,
        "lanczos3" => image::imageops::FilterType::Lanczos3,
        _ => unreachable!(),
    };

    let mut dmi = Dmi::from_serialized(dmi)?;
    dmi.resize(width, height, method);
    dmi.to_serialized(temp, true)?;

    Ok(LuaValue::Nil)
}

fn crop(
    _: &Lua,
    (dmi, x, y, width, height): (LuaTable, u32, u32, u32, u32),
) -> LuaResult<LuaValue> {
    let dmi = SerializedDmi::from_lua_table(dmi)?;
    let temp = dmi.temp.clone();

    let mut dmi = Dmi::from_serialized(dmi)?;
    dmi.crop(x, y, width, height);
    dmi.to_serialized(temp, true)?;

    Ok(LuaValue::Nil)
}

fn expand(
    _: &Lua,
    (dmi, x, y, width, height): (LuaTable, u32, u32, u32, u32),
) -> LuaResult<LuaValue> {
    let dmi = SerializedDmi::from_lua_table(dmi)?;
    let temp = dmi.temp.clone();

    let mut dmi = Dmi::from_serialized(dmi)?;
    dmi.expand(x, y, width, height);
    dmi.to_serialized(temp, true)?;

    Ok(LuaValue::Nil)
}

fn overlay_color(
    _: &Lua,
    (r, g, b, width, height, bytes): (u8, u8, u8, u32, u32, LuaMultiValue),
) -> LuaResult<LuaMultiValue> {
    use image::{imageops, EncodableLayout, ImageBuffer, Rgba};

    let mut buf = Vec::new();
    for byte in bytes {
        if let LuaValue::Integer(byte) = byte {
            buf.push(byte as u8);
        }
    }

    if let Some(top) = ImageBuffer::from_vec(width, height, buf) {
        let mut bottom = ImageBuffer::from_pixel(width, height, Rgba([r, g, b, 255]));
        imageops::overlay(&mut bottom, &top, 0, 0);

        let bytes = bottom
            .as_bytes()
            .iter()
            .map(|byte| LuaValue::Integer(*byte as i64))
            .collect();

        return Ok(LuaMultiValue::from_vec(bytes));
    }

    Ok(LuaMultiValue::from_vec(vec![LuaValue::Nil]))
}

fn remove_dir(_: &Lua, (path, soft): (String, bool)) -> LuaResult<LuaValue> {
    let path = Path::new(&path);

    if path.is_dir() {
        if !soft {
            remove_dir_all(path)?;
        } else if read_dir(path)?.next().is_none() {
            fs::remove_dir(path)?;
        }
    }

    Ok(LuaValue::Nil)
}

fn exists(_: &Lua, path: String) -> LuaResult<bool> {
    let path = Path::new(&path);

    Ok(path.exists())
}

fn save_dialog(
    _: &Lua,
    (title, filename, location): (String, String, String),
) -> LuaResult<String> {
    let dialog = DialogBuilder::file()
        .set_title(&title)
        .set_filename(&filename)
        .set_location(&location)
        .add_filter("dmi files", ["dmi"])
        .save_single_file();

    if let Ok(Some(file)) = dialog.show() {
        if let Some(file) = file.to_str() {
            return Ok(file.to_string());
        }
    }

    Ok(String::new())
}

fn instances(_: &Lua, _: ()) -> LuaResult<usize> {
    let mut system = sysinfo::System::new();
    let refresh_kind =
        sysinfo::ProcessRefreshKind::nothing().with_exe(sysinfo::UpdateKind::OnlyIfNotSet);
    system.refresh_processes_specifics(sysinfo::ProcessesToUpdate::All, true, refresh_kind);

    Ok(system.processes_by_name(OsStr::new("aseprite")).count())
}

fn check_update(_: &Lua, (): ()) -> LuaResult<bool> {
    let version = check_latest_version();

    if let Ok(Ordering::Less) = version {
        return Ok(true);
    }

    Ok(false)
}

fn open_repo(_: &Lua, path: Option<String>) -> LuaResult<LuaValue> {
    let url = if let Some(path) = path {
        format!("{}/{}", env!("CARGO_PKG_REPOSITORY"), path)
    } else {
        env!("CARGO_PKG_REPOSITORY").to_string()
    };

    if open::that(&url).is_err() {
        return Err("Failed to open browser".to_string()).into_lua_err();
    }

    Ok(LuaValue::Nil)
}

fn import_png(lua: &Lua, (dmi_table, filepath): (LuaTable, String)) -> LuaResult<LuaTable> {
    use crate::dmi::{Dmi, SerializedDmi, State};
    use image::ImageReader;

    // Get temp dir before moving dmi_table
    let temp = dmi_table
        .get::<String>("temp")
        .map_err(|_| mlua::Error::external("DMI temp directory missing"))?;
    // Deserialize the DMI from Lua
    let mut dmi = Dmi::from_serialized(SerializedDmi::from_lua_table(dmi_table)?)?;
    let dmi_width = dmi.width;
    let dmi_height = dmi.height;

    // Open the PNG
    let img = ImageReader::open(&filepath)
        .map_err(mlua::Error::external)?
        .decode()
        .map_err(mlua::Error::external)?;
    let png_width = img.width();
    let png_height = img.height();
    let tiles_x = png_width.div_ceil(dmi_width);
    let tiles_y = png_height.div_ceil(dmi_height);

    let mut new_states = Vec::new();
    for y in (0..tiles_y).rev() {
        // bottom to top
        for x in 0..tiles_x {
            // Name format is x,y, where 0,0 is the bottom-left corner
            // So we need to invert the y coordinate for naming
            let name = format!("{},{}", x, tiles_y - y - 1);
            let mut state = State::new_blank(name, dmi_width, dmi_height);
            // Crop region (may be partial)
            let left = x * dmi_width;
            let top = y * dmi_height;
            let crop_w = dmi_width.min(png_width.saturating_sub(left));
            let crop_h = dmi_height.min(png_height.saturating_sub(top));
            let mut tile = img.crop_imm(left, top, crop_w, crop_h);
            // If tile is smaller than dmi size, paste onto transparent
            if tile.width() != dmi_width || tile.height() != dmi_height {
                let mut full = image::DynamicImage::new_rgba8(dmi_width, dmi_height);
                image::imageops::replace(&mut full, &tile, 0, 0);
                tile = full;
            }
            state.frames[0] = tile;
            new_states.push(state);
        }
    }
    // Add new states to DMI
    dmi.states.extend(new_states);
    // Serialize and return as LuaTable
    let serialized = dmi.to_serialized(temp, true)?;
    serialized.into_lua_table(lua)
}

trait IntoLuaTable {
    fn into_lua_table(self, lua: &Lua) -> LuaResult<LuaTable>;
}

trait FromLuaTable {
    type Result;
    fn from_lua_table(table: LuaTable) -> LuaResult<Self::Result>;
}

impl IntoLuaTable for SerializedState {
    fn into_lua_table(self, lua: &Lua) -> LuaResult<LuaTable> {
        let table = lua.create_table()?;

        table.set("name", self.name)?;
        table.set("dirs", self.dirs)?;
        table.set("frame_key", self.frame_key)?;
        table.set("frame_count", self.frame_count)?;
        table.set("delays", self.delays)?;
        table.set("loop", self.loop_)?;
        table.set("rewind", self.rewind)?;
        table.set("movement", self.movement)?;
        table.set("hotspots", self.hotspots)?;

        Ok(table)
    }
}

impl IntoLuaTable for SerializedDmi {
    fn into_lua_table(self, lua: &Lua) -> LuaResult<LuaTable> {
        let table = lua.create_table()?;
        let mut states = Vec::new();

        for state in self.states.into_iter() {
            let table = state.into_lua_table(lua)?;
            states.push(table);
        }

        table.set("name", self.name)?;
        table.set("width", self.width)?;
        table.set("height", self.height)?;
        table.set("states", states)?;
        table.set("temp", self.temp)?;

        Ok(table)
    }
}

impl FromLuaTable for SerializedState {
    type Result = SerializedState;
    fn from_lua_table(table: LuaTable) -> LuaResult<Self::Result> {
        let name = table.get::<String>("name")?;
        let dirs = table.get::<u32>("dirs")?;
        let frame_key = table.get::<String>("frame_key")?;
        let frame_count = table.get::<u32>("frame_count")?;
        let delays = table.get::<Vec<f32>>("delays")?;
        let loop_ = table.get::<u32>("loop")?;
        let rewind = table.get::<bool>("rewind")?;
        let movement = table.get::<bool>("movement")?;
        let hotspots = table.get::<Vec<String>>("hotspots")?;

        Ok(SerializedState {
            name,
            dirs,
            frame_key,
            frame_count,
            delays,
            loop_,
            rewind,
            movement,
            hotspots,
        })
    }
}

impl FromLuaTable for SerializedDmi {
    type Result = SerializedDmi;
    fn from_lua_table(table: LuaTable) -> LuaResult<Self::Result> {
        let name = table.get::<String>("name")?;
        let width = table.get::<u32>("width")?;
        let height = table.get::<u32>("height")?;
        let states_table = table.get::<Vec<LuaTable>>("states")?;
        let temp = table.get::<String>("temp")?;

        let mut states = Vec::new();

        for table in states_table {
            states.push(SerializedState::from_lua_table(table)?);
        }

        Ok(SerializedDmi {
            name,
            width,
            height,
            states,
            temp,
        })
    }
}
