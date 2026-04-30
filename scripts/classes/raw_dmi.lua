RawDmi = {
	sprites = {},
	plugin_path = nil,
}

local RAW_DMI_MARKER = "\n__aseprite_dmi_raw__\n"

--- @param sprite Sprite|nil
--- @return boolean
local function has_raw_marker(sprite)
	return sprite ~= nil
		and type(sprite.data) == "string"
		and sprite.data:find(RAW_DMI_MARKER, 1, true) ~= nil
end

--- Marks a sprite as a raw DMI spritesheet for later saves.
--- @param sprite Sprite|nil
local function mark_raw_sprite(sprite)
	if not sprite then
		return
	end

	RawDmi.sprites[sprite] = true

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

--- Returns true if sprite is opened in raw DMI mode.
--- @param sprite Sprite|nil
--- @return boolean
function RawDmi.is_sprite(sprite)
	return sprite ~= nil and (RawDmi.sprites[sprite] == true or has_raw_marker(sprite)) or false
end

--- Starts raw DMI open flow. Opens a file dialog, loads the selected .dmi
--- file using Aseprite's native PNG loader (bypasses our format handler to
--- avoid OOM on large files), and marks the sprite as raw.
function RawDmi.open()
	local dlg = Dialog("Open Raw DMI")
	dlg:file {
		id = "path",
		title = "Select DMI File",
		open = true,
		filetypes = { "dmi" },
		focus = true,
	}
	dlg:button { id = "ok", text = "OK", focus = true }
	dlg:button { id = "cancel", text = "Cancel" }
	dlg:show()

	if not dlg.data.ok then
		return
	end

	local dmi_path = dlg.data.path
	if not dmi_path or #dmi_path == 0 or not app.fs.isFile(dmi_path) then
		return
	end

	-- DMI files are valid PNG files. Copy to a .png temp path so Aseprite's
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

	-- Restore the original .dmi filename so saves go through our onsave handler
	sprite.filename = dmi_path
	mark_raw_sprite(sprite)
end

--- Clears raw DMI state for sprite being closed.
--- @param sprite Sprite|nil
function RawDmi.before_close(sprite)
	if sprite then
		RawDmi.sprites[sprite] = nil
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
