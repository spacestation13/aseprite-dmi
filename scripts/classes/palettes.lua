--- Palette data and color checks, UI-free (dialogs live in palette_dialogs.lua).
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

--- Key of a color ignoring alpha, for "is this color in the palette" checks.
local function rgb_key(r, g, b)
	return (r << 16) | (g << 8) | b
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
-- Aseprite palettes and sprites
--------------------------------------------------------------------------------

--- @param palette PaletteData
--- @return Palette
function Palettes.to_palette(palette)
	local result = Palette(math.max(1, #palette.colors))
	for i, color in ipairs(palette.colors) do
		result:setColor(i - 1, Color { r = color.r, g = color.g, b = color.b, a = color.a })
	end
	return result
end

--- @param palette Palette
--- @param name string|nil
--- @return PaletteData
function Palettes.from_palette(palette, name)
	local result = { name = name, colors = {} }
	for i = 0, #palette - 1 do
		local color = palette:getColor(i)
		table.insert(result.colors, { r = color.red, g = color.green, b = color.blue, a = color.alpha })
	end
	return result
end

--- Replaces the palette of sprites (one undoable step per sprite).
--- @param sprites Sprite[]
--- @param palette PaletteData
function Palettes.apply(sprites, palette)
	for _, sprite in ipairs(sprites) do
		app.transaction("Load Palette", function()
			sprite:setPalette(Palettes.to_palette(palette))
		end)
	end
end

--- The open state sprite (StateSprite) showing `sprite` in a DMI editor, or nil. Read-only:
--- runs from sitechange listeners, so it never changes editor state; entries of closed state
--- tabs (deleted sprites) are skipped.
--- @param sprite Sprite|nil
--- @return StateSprite|nil
function Palettes.state_sprite_of(sprite)
	if not sprite then return nil end
	for _, editor in ipairs(open_editors or {}) do
		if not editor.closed then
			for _, state_sprite in ipairs(editor.open_sprites) do
				if state_sprite.sprite == sprite and Editor.is_sprite_open(state_sprite.sprite) then
					return state_sprite
				end
			end
		end
	end
	return nil
end

--- The sprite, or with `all_states` every open state sprite of the DMI it belongs to (closed
--- state tabs skipped).
--- @param sprite Sprite
--- @param all_states boolean|nil
--- @return Sprite[]
function Palettes.target_sprites(sprite, all_states)
	local state_sprite = all_states and Palettes.state_sprite_of(sprite)
	if state_sprite then
		local sprites = {}
		for _, other in ipairs(state_sprite.editor.open_sprites) do
			if Editor.is_sprite_open(other.sprite) then
				table.insert(sprites, other.sprite)
			end
		end
		return sprites
	end
	return { sprite }
end

--- Palette from color counts (libdmi.collect_colors), most used first.
--- @param counts { r: integer, g: integer, b: integer, a: integer, count: integer }[]
--- @param max integer|nil Keep at most this many colors (nil/0: all).
--- @param name string|nil
--- @return PaletteData
function Palettes.from_counts(counts, max, name)
	local palette = { name = name, colors = {} }
	for i, color in ipairs(counts) do
		if max and max > 0 and i > max then break end
		table.insert(palette.colors, { r = color.r, g = color.g, b = color.b, a = color.a })
	end
	return palette
end

--- Colors of .dmi/.png files by frequency.
--- @param paths string[]
--- @param max integer|nil
--- @param name string|nil
--- @return PaletteData|nil palette
--- @return table|nil counts
--- @return string|nil error
function Palettes.collect(paths, max, name)
	local counts, err = libdmi.collect_colors(paths)
	if not counts then
		return nil, nil, err
	end
	return Palettes.from_counts(counts, max, name), counts
end

--------------------------------------------------------------------------------
-- Color check
--------------------------------------------------------------------------------

--- Image layers (inside groups too), bottom to top; reference and tilemap layers skipped.
--- @param layers Layer[]
--- @param out Layer[]|nil
--- @return Layer[]
local function image_layers(layers, out)
	out = out or {}
	for _, layer in ipairs(layers) do
		if layer.isGroup then
			image_layers(layer.layers, out)
		elseif layer.isImage and not layer.isReference and not layer.isTilemap then
			table.insert(out, layer)
		end
	end
	return out
end

--- Calls `fn(x, y, r, g, b, a)` for every visible pixel of a cel (alpha > 0; in indexed mode
--- the transparent index is skipped), in the sprite's color mode.
local function each_pixel(sprite, cel, fn)
	local image = cel.image
	local bytes = image.bytes
	local width = image.width
	local mode = image.colorMode
	if mode == ColorMode.RGB then
		for i = 1, #bytes, 4 do
			local r, g, b, a = bytes:byte(i, i + 3)
			if a > 0 then
				local p = (i - 1) // 4
				fn(p % width, p // width, r, g, b, a)
			end
		end
	elseif mode == ColorMode.GRAYSCALE then
		for i = 1, #bytes, 2 do
			local v, a = bytes:byte(i, i + 1)
			if a > 0 then
				local p = (i - 1) // 2
				fn(p % width, p // width, v, v, v, a)
			end
		end
	elseif mode == ColorMode.INDEXED then
		local palette = sprite.palettes[1]
		local transparent = sprite.transparentColor
		local cache = {}
		for i = 1, #bytes do
			local index = bytes:byte(i)
			if index ~= transparent and index < #palette then
				local color = cache[index]
				if not color then
					local c = palette:getColor(index)
					color = { c.red, c.green, c.blue, c.alpha }
					cache[index] = color
				end
				if color[4] > 0 then
					fn((i - 1) % width, (i - 1) // width, color[1], color[2], color[3], color[4])
				end
			end
		end
	end
end

--- Set of colors (RGB keys) in a palette; fully transparent entries don't count.
--- @param palette Palette|PaletteData
--- @return table<integer, boolean>
function Palettes.color_set(palette)
	local set = {}
	if type(palette) == "table" then
		for _, c in ipairs(palette.colors) do
			if c.a > 0 then set[rgb_key(c.r, c.g, c.b)] = true end
		end
	else
		for i = 0, #palette - 1 do
			local c = palette:getColor(i)
			if c.alpha > 0 then set[rgb_key(c.red, c.green, c.blue)] = true end
		end
	end
	return set
end

local function count_keys(set)
	local n = 0
	for _ in pairs(set) do n = n + 1 end
	return n
end

--- @class ColorReport
--- @field colors integer Unique colors (RGBA, alpha 0 excluded) in the whole sprite.
--- @field pixels integer Visible pixels counted.
--- @field palette_size integer Colors in the palette checked against.
--- @field layers { name: string, colors: integer, frames: integer[] }[] Unique colors per layer, and per layer per frame (0: empty).
--- @field frames integer[] Unique colors per frame (all layers).
--- @field off_palette { r: integer, g: integer, b: integer, a: integer, count: integer }[] Colors whose RGB isn't in the palette, most used first.
--- @field off_pixels integer Pixels using those colors.

--- Counts the colors of a sprite and those missing from a palette. A pixel matches a palette
--- entry by RGB (its alpha is ignored, so translucent shading of a palette color passes).
--- @param sprite Sprite
--- @param palette Palette|PaletteData|nil Defaults to the sprite's palette.
--- @return ColorReport
function Palettes.check(sprite, palette)
	local in_palette = Palettes.color_set(palette or sprite.palettes[1])
	local report = {
		colors = 0, pixels = 0, palette_size = count_keys(in_palette),
		layers = {}, frames = {}, off_palette = {}, off_pixels = 0,
	}

	local all = {}
	local frame_sets = {}
	local off = {}
	for i = 1, #sprite.frames do
		frame_sets[i] = {}
	end

	for _, layer in ipairs(image_layers(sprite.layers)) do
		local layer_set = {}
		local entry = { name = layer.name, colors = 0, frames = {} }
		for i = 1, #sprite.frames do
			entry.frames[i] = 0
		end
		for _, cel in ipairs(layer.cels) do
			local cel_set = {}
			local frame_set = frame_sets[cel.frameNumber]
			each_pixel(sprite, cel, function(_, _, r, g, b, a)
				local key = pc.rgba(r, g, b, a)
				cel_set[key] = true
				layer_set[key] = true
				frame_set[key] = true
				local count = all[key]
				all[key] = (count or 0) + 1
				report.pixels = report.pixels + 1
				if not in_palette[rgb_key(r, g, b)] then
					report.off_pixels = report.off_pixels + 1
					local o = off[key]
					if not o then
						o = { r = r, g = g, b = b, a = a, count = 0 }
						off[key] = o
					end
					o.count = o.count + 1
				end
			end)
			entry.frames[cel.frameNumber] = count_keys(cel_set)
		end
		entry.colors = count_keys(layer_set)
		table.insert(report.layers, entry)
	end

	report.colors = count_keys(all)
	for i = 1, #sprite.frames do
		report.frames[i] = count_keys(frame_sets[i])
	end
	for _, o in pairs(off) do
		table.insert(report.off_palette, o)
	end
	table.sort(report.off_palette, function(x, y)
		if x.count ~= y.count then return x.count > y.count end
		return pc.rgba(x.r, x.g, x.b, x.a) < pc.rgba(y.r, y.g, y.b, y.a)
	end)
	return report
end

--- Selection of the pixels of one frame (all image layers) whose color isn't in the palette.
--- @param sprite Sprite
--- @param frame integer Frame number.
--- @param palette Palette|PaletteData|nil Defaults to the sprite's palette.
--- @return Selection selection
--- @return integer pixels Selected pixel count (overlapping layers count once per layer).
function Palettes.off_palette_selection(sprite, frame, palette)
	local in_palette = Palettes.color_set(palette or sprite.palettes[1])
	local selection = Selection()
	local pixels = 0

	for _, layer in ipairs(image_layers(sprite.layers)) do
		local cel = layer:cel(frame)
		if cel then
			local origin = cel.position
			-- Merge horizontal runs into one rectangle each.
			local run_x, run_y, run_end
			local function flush()
				if run_x then
					selection:add(Rectangle(origin.x + run_x, origin.y + run_y, run_end - run_x + 1, 1))
					run_x = nil
				end
			end
			each_pixel(sprite, cel, function(x, y, r, g, b)
				if not in_palette[rgb_key(r, g, b)] then
					pixels = pixels + 1
					if run_x and y == run_y and x == run_end + 1 then
						run_end = x
					else
						flush()
						run_x, run_y, run_end = x, y, x
					end
				end
			end)
			flush()
		end
	end
	return selection, pixels
end

--- Selects the off-palette pixels of a frame (undoable).
--- @param sprite Sprite
--- @param frame integer
--- @return integer pixels
function Palettes.select_off_palette(sprite, frame)
	local selection, pixels = Palettes.off_palette_selection(sprite, frame)
	app.transaction("Select Off-Palette Pixels", function()
		sprite.selection = selection
	end)
	return pixels
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
