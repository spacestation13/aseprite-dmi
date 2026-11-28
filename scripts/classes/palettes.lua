--- Palette data and the codebase palette registry, UI-free (the dialog lives in palette_dialogs.lua).
---
--- A palette here is a plain table so it can carry entry names (Aseprite's Lua Palette can't):
--- `{ name = string|nil, colors = { { r, g, b, a, name = string|nil }, ... } }`.
--- @class Palettes
Palettes = {}

--- @class PaletteColor
--- @field r integer
--- @field g integer
--- @field b integer
--- @field a integer
--- @field name string|nil

--- @class PaletteData
--- @field name string|nil
--- @field colors PaletteColor[]

local pc = app.pixelColor

local function clamp_byte(value)
	return math.max(0, math.min(255, math.floor(tonumber(value) or 0)))
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("a")
	file:close()
	return text
end

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

--- Parses a GIMP palette (.gpl). Supports Aseprite's `Channels: RGBA` extension and entry names
--- with spaces.
--- @param text string
--- @return PaletteData|nil palette
--- @return string|nil error
function Palettes.parse_gpl(text)
	text = text:gsub("^\239\187\191", "") -- UTF-8 BOM
	local lines = {}
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, (line:gsub("\r$", "")))
	end
	if not lines[1] or lines[1]:match("^%s*(.-)%s*$") ~= "GIMP Palette" then
		return nil, "Not a GIMP palette (first line must be \"GIMP Palette\")"
	end

	local palette = { colors = {} }
	local alpha = false
	for i = 2, #lines do
		local line = lines[i]:match("^%s*(.-)%s*$")
		if line ~= "" and not line:starts_with("#") then
			local key, value = line:match("^(%a+):%s*(.-)$")
			if key == "Name" then
				palette.name = value
			elseif key == "Channels" then
				alpha = value:upper() == "RGBA"
			elseif not key then
				local numbers, rest = {}, line
				local count = alpha and 4 or 3
				for _ = 1, count do
					local number, tail = rest:match("^(%d+)%s*(.*)$")
					if not number then break end
					table.insert(numbers, tonumber(number))
					rest = tail
				end
				if #numbers == count then
					local name = rest ~= "" and rest or nil
					if name == "Untitled" then name = nil end
					table.insert(palette.colors, {
						r = clamp_byte(numbers[1]),
						g = clamp_byte(numbers[2]),
						b = clamp_byte(numbers[3]),
						a = alpha and clamp_byte(numbers[4]) or 255,
						name = name,
					})
				end
			end
		end
	end
	return palette
end

--- Serializes a palette as a GIMP palette (`Channels: RGBA` only when a color isn't opaque).
--- Every color line gets a name ("Untitled" when it has none, like Aseprite writes): Aseprite
--- skips color lines without one.
--- @param palette PaletteData
--- @param comment string|nil Written as a `#` comment line after the header.
--- @return string
function Palettes.to_gpl(palette, comment)
	local alpha = false
	for _, color in ipairs(palette.colors) do
		if color.a ~= 255 then alpha = true end
	end

	local lines = { "GIMP Palette" }
	if palette.name then
		table.insert(lines, "Name: " .. palette.name:gsub("[\r\n]", " "))
	end
	if alpha then
		table.insert(lines, "Channels: RGBA")
	end
	if comment then
		table.insert(lines, "# " .. comment:gsub("[\r\n]", " "))
	end
	table.insert(lines, "#")
	for _, color in ipairs(palette.colors) do
		local line = string.format("%3d %3d %3d", color.r, color.g, color.b)
		if alpha then line = line .. string.format(" %3d", color.a) end
		local name = color.name and color.name:gsub("[\r\n]", " ") or ""
		line = line .. "\t" .. (name ~= "" and name or "Untitled")
		table.insert(lines, line)
	end
	return table.concat(lines, "\n") .. "\n"
end

--- Parses a .hex palette (one RRGGBB or AARRGGBB per line, as Lospec exports).
--- @param text string
--- @return PaletteData|nil palette
--- @return string|nil error
function Palettes.parse_hex(text)
	local palette = { colors = {} }
	for line in text:gmatch("[^\r\n]+") do
		local hex = line:match("^%s*#?(%x+)%s*$")
		if hex and (#hex == 6 or #hex == 8) then
			local value = tonumber(hex, 16)
			local a = #hex == 8 and (value >> 24) & 0xff or 255
			table.insert(palette.colors, {
				r = (value >> 16) & 0xff, g = (value >> 8) & 0xff, b = value & 0xff, a = a,
			})
		end
	end
	if #palette.colors == 0 then
		return nil, "No colors found"
	end
	return palette
end

--- Unique colors of an image in reading order (alpha 0 skipped), e.g. a palette strip PNG.
--- @param path string
--- @return PaletteData|nil palette
--- @return string|nil error
function Palettes.read_image(path)
	local ok, image = pcall(Image, { fromFile = path })
	if not ok or not image then
		return nil, "Could not open image: " .. path
	end
	local rgb = Image(image.width, image.height, ColorMode.RGB)
	rgb:drawImage(image)

	local palette = { colors = {} }
	local seen = {}
	local bytes = rgb.bytes
	for i = 1, #bytes, 4 do
		local r, g, b, a = bytes:byte(i, i + 3)
		local key = pc.rgba(r, g, b, a)
		if a > 0 and not seen[key] then
			seen[key] = true
			table.insert(palette.colors, { r = r, g = g, b = b, a = a })
		end
	end
	return palette
end

--- Reads a palette file: format "gpl", "hex" or "png" (default: from the extension).
--- @param path string
--- @param format string|nil
--- @return PaletteData|nil palette
--- @return string|nil error
function Palettes.read(path, format)
	format = (format or app.fs.fileExtension(path)):lower()
	if format == "png" then
		return Palettes.read_image(path)
	end
	local text = read_file(path)
	if not text then
		return nil, "Could not read " .. path
	end
	if format == "hex" or format == "txt" then
		return Palettes.parse_hex(text)
	end
	return Palettes.parse_gpl(text)
end

--- Writes a palette as .gpl.
--- @param palette PaletteData
--- @param path string
--- @param comment string|nil See Palettes.to_gpl.
--- @return boolean ok
--- @return string|nil error
function Palettes.write_gpl(palette, path, comment)
	local file = io.open(path, "wb")
	if not file then
		return false, "Could not write " .. path
	end
	file:write(Palettes.to_gpl(palette, comment))
	file:close()
	return true
end

--- A file title safe on every platform.
--- @param name string
--- @return string
function Palettes.file_title(name)
	local title = name:gsub("[<>:\"/\\|%?%*%c]", "_"):match("^[%s%.]*(.-)[%s%.]*$")
	if title == "" or title:lower() == "default" then
		title = "palette"
	end
	return title
end

--- Aseprite's user palettes folder: .gpl files there show up in the palette Presets list.
--- @return string
function Palettes.presets_dir()
	return app.fs.joinPath(app.fs.userConfigPath, "palettes")
end

--- Comment marking presets this extension installed (they may be replaced without asking).
local INSTALLED_MARK = "Installed by the DMI Editor extension"

--- Path of the preset `<name>.gpl` in the Presets folder.
--- @param name string
--- @return string
function Palettes.preset_path(name)
	return app.fs.joinPath(Palettes.presets_dir(), Palettes.file_title(name) .. ".gpl")
end

--- Whether the preset file was installed by this extension.
--- @param path string
--- @return boolean
local function installed_by_us(path)
	local file = io.open(path, "rb")
	if not file then return false end
	local head = file:read(4096) or ""
	file:close()
	return head:find("# " .. INSTALLED_MARK, 1, true) ~= nil
end

--- Saves a palette into the Presets folder as `<name>.gpl`. A preset this extension installed
--- earlier is replaced; any other existing file only with `replace`, else nothing is written
--- and the third result is true (ask the user, then call again with `replace`).
--- @param palette PaletteData
--- @param name string|nil Preset name, defaults to the palette name.
--- @param replace boolean|nil Replace a preset that isn't ours.
--- @return string|nil path
--- @return string|nil error
--- @return boolean|nil exists A preset of that name exists and wasn't replaced.
function Palettes.install(palette, name, replace)
	local path = Palettes.preset_path(name or palette.name or "palette")
	if not replace and app.fs.isFile(path) and not installed_by_us(path) then
		return nil, "A preset named \"" .. app.fs.fileTitle(path) .. "\" already exists.", true
	end
	app.fs.makeAllDirectories(Palettes.presets_dir())
	local ok, err = Palettes.write_gpl(palette, path, INSTALLED_MARK)
	if not ok then return nil, err end
	return path
end

--------------------------------------------------------------------------------
-- Codebase palette registry (registry/palettes.json)
--------------------------------------------------------------------------------

--- @class PaletteEntry
--- @field id string
--- @field name string
--- @field codebase string|nil
--- @field url string
--- @field format string|nil "gpl" (default from the URL), "hex" or "png".
--- @field description string|nil
--- @field guidelines string|nil
--- @field homepage string|nil
--- @field license string|nil

--- Valid entries of a palettes registry, in file order. Entries without id/name/url, or whose
--- url is outside this repository (Registry.is_allowed), are skipped.
--- @param registry table|nil Decoded palettes.json.
--- @return PaletteEntry[]
function Palettes.entries(registry)
	local entries = {}
	if type(registry) ~= "table" or type(registry.palettes) ~= "table" then
		return entries
	end
	for _, entry in ipairs(registry.palettes) do
		if type(entry) == "table" and type(entry.id) == "string" and type(entry.name) == "string"
			and Registry.is_allowed(entry.url) then
			table.insert(entries, entry)
		end
	end
	return entries
end

--- Loads a registry entry's palette (downloads it with `online`, see Registry.asset).
--- @param entry PaletteEntry
--- @param options Registry.Options|nil
--- @return PaletteData|nil palette
--- @return Registry.Info info
function Palettes.load_entry(entry, options)
	local path, info = Registry.asset(entry.url, options)
	if not path then
		return nil, info
	end
	local palette, err = Palettes.read(path, entry.format)
	if not palette then
		info.error = err
		return nil, info
	end
	palette.name = entry.name
	return palette, info
end
