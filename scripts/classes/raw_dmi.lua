RawDmi = {
	sprites = {},
	sessions = {},
	plugin_path = nil,
}

local RAW_DMI_MARKER = "\n__aseprite_dmi_raw__\n"
local RAW_DMI_SESSION_PREFIX = RAW_DMI_MARKER .. "v1\n"

--- @param session table
--- @return string
local function serialize_session(session)
	return RAW_DMI_SESSION_PREFIX
		.. session.original_width .. "\n"
		.. session.original_height .. "\n"
		.. session.cell_width .. "\n"
		.. session.cell_height .. "\n"
		.. #session.metadata .. "\n"
		.. session.metadata
end

--- @param sprite Sprite|nil
--- @return table|nil
local function read_session(sprite)
	if sprite == nil or type(sprite.data) ~= "string" then
		return nil
	end

	local prefix_start = sprite.data:find(RAW_DMI_SESSION_PREFIX, 1, true)
	if prefix_start == nil then
		return nil
	end

	local record = sprite.data:sub(prefix_start + #RAW_DMI_SESSION_PREFIX)
	local original_width, original_height, cell_width, cell_height, metadata_length, metadata_start = record:match(
		"^(%d+)\n(%d+)\n(%d+)\n(%d+)\n(%d+)\n()"
	)
	if metadata_start == nil then
		return nil
	end

	metadata_length = tonumber(metadata_length)
	local metadata_end = metadata_start + metadata_length - 1
	if #record < metadata_end then
		return nil
	end

	return {
		original_width = tonumber(original_width),
		original_height = tonumber(original_height),
		cell_width = tonumber(cell_width),
		cell_height = tonumber(cell_height),
		metadata = record:sub(metadata_start, metadata_end),
	}
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
--- @param session table
local function mark_raw_sprite(sprite, session)
	if not sprite or not session then
		return
	end

	RawDmi.sprites[sprite] = true
	RawDmi.sessions[sprite] = session

	local data = sprite.data or ""
	sprite.data = data .. serialize_session(session)
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
		session.metadata
	)
	if save_error then
		app.alert { title = DIALOG_NAME, text = "Failed to save DMI: " .. save_error }
		return false
	end

	return true
end

--- Starts raw DMI open flow. Opens a file dialog, loads the selected .dmi
--- file using Aseprite's native PNG loader (bypasses our format handler to
--- avoid OOM on large files), and marks the sprite as raw.
function RawDmi.open()
	local dmi_path = libdmi.open_dialog("Open DMI", app.fs.userDocsPath)
	if not dmi_path or #dmi_path == 0 or not app.fs.isFile(dmi_path) then
		return
	end

	local dmi_metadata, metadata_error = libdmi.read_dmi_metadata(dmi_path)
	if not dmi_metadata then
		app.alert {
			title = DIALOG_NAME,
			text = "Failed to read DMI metadata: " .. (metadata_error or "unknown error"),
		}
		return
	end

	-- DMI files are PNG files. Copy to a .png temp path so Aseprite's
	-- native PNG loader handles decompression (streaming, memory-efficient).
	local temp_path = app.fs.joinPath(TEMP_DIR, "raw_open.png")
	app.fs.makeDirectory(TEMP_DIR)

	local fin = io.open(dmi_path, "rb")
	if not fin then
		app.alert { title = DIALOG_NAME, text = "Failed to open file: " .. dmi_path }
		return
	end
	local data = fin:read("*a")
	fin:close()

	local fout = io.open(temp_path, "wb")
	if not fout then
		app.alert { title = DIALOG_NAME, text = "Failed to create temp file" }
		return
	end
	fout:write(data)
	fout:close()

	-- Open as .png (uses native PNG loader, no Lua byte buffer overhead)
	local sprite = app.open(temp_path)
	os.remove(temp_path)

	if not sprite then
		app.alert { title = DIALOG_NAME, text = "Failed to open DMI spritesheet" }
		return
	end

	if sprite.colorMode ~= ColorMode.RGB then
		app.command.ChangePixelFormat { format = "rgb" }
	end

	-- Restore the original .dmi filename so saves go through our onsave handler
	sprite.filename = dmi_path
	mark_raw_sprite(sprite, {
		original_width = sprite.width,
		original_height = sprite.height,
		cell_width = dmi_metadata.width,
		cell_height = dmi_metadata.height,
		metadata = dmi_metadata.metadata,
	})
	sprite.gridBounds = Rectangle {
		x = 0,
		y = 0,
		width = dmi_metadata.width,
		height = dmi_metadata.height,
	}
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
