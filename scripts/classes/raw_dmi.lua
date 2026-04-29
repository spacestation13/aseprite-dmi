--- @diagnostic disable: lowercase-global

--- Raw DMI helpers.
RawDmi = {
	sprites = {},
	filenames = {},
	opening = false,
	plugin_path = nil,
}

local RAW_DMI_MARKER = "\n__aseprite_dmi_raw__\n"

--- @param filename string|nil
--- @return boolean
local function is_dmi_filename(filename)
	return filename ~= nil and filename:lower():ends_with(".dmi")
end

--- @param sprite Sprite|nil
--- @return boolean
local function has_raw_marker(sprite)
	return sprite ~= nil
		and type(sprite.data) == "string"
		and sprite.data:find(RAW_DMI_MARKER, 1, true) ~= nil
end

--- Marks a sprite as a raw DMI spritesheet for later saves.
--- @param sprite Sprite|nil
--- @param filename string|nil
local function mark_raw_sprite(sprite, filename)
	if not sprite then
		return
	end

	RawDmi.sprites[sprite] = true
	if filename and #filename > 0 then
		RawDmi.filenames[sprite] = filename
	end

	local data = sprite.data or ""
	if not data:find(RAW_DMI_MARKER, 1, true) then
		sprite.data = data .. RAW_DMI_MARKER
	end
end

--- Stores plugin path so raw DMI helpers can load the native library on demand.
--- @param plugin_path string
function RawDmi.initialize(plugin_path)
	RawDmi.plugin_path = plugin_path
end

--- Ensures the Rust library is loaded before raw file operations that use it.
local function ensure_lib()
	if not libdmi and RawDmi.plugin_path then
		loadlib(RawDmi.plugin_path)
	end
end

--- Shows native save dialog for raw DMI sprite export.
--- @param filename string
--- @return string?
local function choose_raw_dmi_save_filename(filename)
	ensure_lib()
	if not libdmi then
		return nil
	end

	return libdmi.save_raw_dialog("Save Raw DMI", app.fs.fileName(filename), app.fs.filePath(filename))
end

--- Returns true if sprite is opened in raw DMI mode.
--- @param sprite Sprite|nil
--- @return boolean
function RawDmi.is_sprite(sprite)
	return sprite ~= nil and (RawDmi.sprites[sprite] == true or has_raw_marker(sprite)) or false
end

--- Starts raw DMI open flow.
function RawDmi.open()
	RawDmi.opening = true
	app.command.OpenFile()
end

--- Finishes raw DMI open flow after OpenFile command.
--- @param sprite Sprite|nil
function RawDmi.after_open(sprite)
	if RawDmi.opening and sprite and is_dmi_filename(sprite.filename) then
		mark_raw_sprite(sprite, sprite.filename)
	end

	RawDmi.opening = false
end

--- Clears raw DMI state for sprite being closed.
--- @param sprite Sprite|nil
function RawDmi.before_close(sprite)
	if sprite then
		RawDmi.sprites[sprite] = nil
		RawDmi.filenames[sprite] = nil
	end
end

--- Returns the tracked filename for a raw DMI sprite.
--- @param sprite Sprite
--- @return string
local function raw_filename(sprite)
	return RawDmi.filenames[sprite]
		or (is_dmi_filename(sprite.filename) and sprite.filename)
		or app.fs.joinPath(app.fs.userDocsPath, "untitled.dmi")
end

--- Saves raw-open sprite as plain PNG bytes to destination filename.
--- @param sprite Sprite
--- @param filename string
--- @return boolean, string?
function RawDmi.save_sprite(sprite, filename)
	ensure_lib()
	if not libdmi then
		return false, "Native library is not loaded"
	end

	local ok, error = pcall(function()
		local image = Image(sprite)
		libdmi.save_rgba_png(image.width, image.height, image.bytes, filename)
	end)

	if not ok then
		return false, error
	end

	mark_raw_sprite(sprite, filename)
	return true
end

--- Saves the active raw DMI sprite using the tracked filename.
--- @return boolean, string?
function RawDmi.save_active()
	local sprite = app.sprite
	if not RawDmi.is_sprite(sprite) then
		return false, "Active sprite is not a raw DMI spritesheet"
	end

	return RawDmi.save_sprite(sprite, raw_filename(sprite --[[@as Sprite]]))
end

--- Saves the active raw DMI sprite to a user-selected filename.
--- @return boolean, string?
function RawDmi.save_active_as()
	local sprite = app.sprite
	if not RawDmi.is_sprite(sprite) then
		return false, "Active sprite is not a raw DMI spritesheet"
	end

	local filename = choose_raw_dmi_save_filename(raw_filename(sprite --[[@as Sprite]]))
	if not filename or #filename == 0 then
		return false, "Save canceled"
	end

	return RawDmi.save_sprite(sprite, filename)
end

--- Handles raw DMI save/close commands.
--- @param ev table
--- @return boolean handled
function RawDmi.beforecommand(ev)
	local sprite = app.sprite
	if not sprite then
		return false
	end

	if ev.name == "CloseFile" then
		RawDmi.before_close(sprite)
		return false
	end

	if not RawDmi.is_sprite(sprite) then
		return false
	end

	if ev.name == "SaveFile" then
		ev.stopPropagation()
		local ok, error = RawDmi.save_active()
		if not ok and error ~= "Save canceled" then
			app.alert { title = DIALOG_NAME, text = { "Failed to save raw DMI", error } }
		end
		return true
	elseif ev.name == "SaveFileAs" then
		ev.stopPropagation()
		local ok, error = RawDmi.save_active_as()
		if not ok and error ~= "Save canceled" then
			app.alert { title = DIALOG_NAME, text = { "Failed to save raw DMI", error } }
		end
		return true
	end

	return false
end
