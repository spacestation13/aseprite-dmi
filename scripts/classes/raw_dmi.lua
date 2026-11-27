RawDmi = {
	sprites = {},
	sessions = {},
	plugin_path = nil,
}

--- @param sprite Sprite|nil
--- @return RawDmiSession|nil
local function read_session(sprite)
	if libdmi == nil or sprite == nil or type(sprite.data) ~= "string" then
		return nil
	end

	return libdmi.decode_raw_session(sprite.data)
end

--- @param sprite Sprite|nil
--- @return boolean
local function has_raw_marker(sprite)
	return libdmi ~= nil
		and sprite ~= nil
		and type(sprite.data) == "string"
		and libdmi.has_raw_session(sprite.data) == true
end

--- Marks a sprite as a raw DMI spritesheet for later saves.
--- @param sprite Sprite|nil
--- @param session RawDmiSession
local function mark_raw_sprite(sprite, session)
	if not sprite or not session then
		return
	end

	RawDmi.sprites[sprite] = true
	RawDmi.sessions[sprite] = session

	local record = libdmi.encode_raw_session(session)
	if record then
		sprite.data = (sprite.data or "") .. record
	end
end

--- Stores plugin path so raw DMI helpers can load the native library on demand.
--- @param plugin_path string
function RawDmi.initialize(plugin_path)
	RawDmi.plugin_path = plugin_path
end

--- Returns true if sprite is opened in raw DMI mode.
--- @param sprite Sprite|nil
--- @return boolean
function RawDmi.is_sprite(sprite)
	return sprite ~= nil and (RawDmi.sprites[sprite] == true or has_raw_marker(sprite)) or false
end

--- Returns the metadata captured when a raw DMI spritesheet was opened.
--- @param sprite Sprite|nil
--- @return table|nil
function RawDmi.get_session(sprite)
	if sprite == nil then
		return nil
	end

	return RawDmi.sessions[sprite] or read_session(sprite)
end

--- Saves a raw DMI spritesheet while retaining its original metadata.
--- @param sprite Sprite
--- @param filename string
--- @return boolean saved
function RawDmi.save(sprite, filename)
	local session = RawDmi.get_session(sprite)
	if not session then
		app.alert {
			title = DIALOG_NAME,
			text = "Raw DMI metadata is unavailable. Save as PNG or reopen the original DMI in Advanced mode.",
		}
		return false
	end

	if sprite.width ~= session.original_width or sprite.height ~= session.original_height then
		app.alert {
			title = DIALOG_NAME,
			text = "Raw DMI save requires the original canvas dimensions. Restore the canvas size or save as PNG.",
		}
		return false
	end

	local image = Image(ImageSpec {
		width = sprite.width,
		height = sprite.height,
		colorMode = ColorMode.RGB,
		transparentColor = app.pixelColor.rgba(0, 0, 0, 0),
	})
	image:drawSprite(sprite, 1)

	local _, save_error = libdmi.save_rgba_dmi(
		image.width,
		image.height,
		image.bytes,
		filename,
		session.metadata,
		Preferences.getBlackNearTransparent()
	)
	if save_error then
		app.alert { title = DIALOG_NAME, text = "Failed to save DMI: " .. save_error }
		return false
	end

	return true
end

--- Starts raw DMI open flow: picks a .dmi file and opens it with `RawDmi.open_file`.
function RawDmi.open()
	local dmi_path = libdmi.open_dialog("Open DMI", app.fs.userDocsPath, "dmi")
	if not dmi_path or #dmi_path == 0 or not app.fs.isFile(dmi_path) then
		return
	end

	RawDmi.open_file(dmi_path)
end

--- Opens a .dmi file as a spritesheet using Aseprite's native PNG loader (bypasses our
--- format handler to avoid OOM on large files), and marks the sprite as raw.
--- @param dmi_path string
--- @return Sprite|nil sprite
function RawDmi.open_file(dmi_path)
	-- DMI files are PNG files. libdmi copies it to a .png temp path so Aseprite's
	-- native PNG loader handles decompression (streaming, memory-efficient).
	local opened, open_error = libdmi.raw_open(dmi_path, TEMP_DIR)
	if not opened then
		app.alert {
			title = DIALOG_NAME,
			text = "Failed to open DMI: " .. (open_error or "unknown error"),
		}
		return nil
	end

	local sprite = app.open(opened.png)
	os.remove(opened.png)

	if not sprite then
		app.alert { title = DIALOG_NAME, text = "Failed to open DMI spritesheet" }
		return nil
	end

	if sprite.colorMode ~= ColorMode.RGB then
		app.command.ChangePixelFormat { format = "rgb" }
	end

	-- Restore the original .dmi filename so saves go through our onsave handler
	sprite.filename = dmi_path
	local session = opened.session
	mark_raw_sprite(sprite, session)
	sprite.gridBounds = Rectangle {
		x = 0,
		y = 0,
		width = session.cell_width,
		height = session.cell_height,
	}
	return sprite
end

--- Clears raw DMI state for sprite being closed.
--- @param sprite Sprite|nil
function RawDmi.before_close(sprite)
	if sprite then
		RawDmi.sprites[sprite] = nil
		RawDmi.sessions[sprite] = nil
	end
end

--- Handles raw DMI close command.
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

	return false
end
