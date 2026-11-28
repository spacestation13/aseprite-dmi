--- The `File > DMI Editor > Codebase Palettes` dialog (logic in palettes.lua and registry.lua).
--- @class PaletteDialogs
PaletteDialogs = {}

local PREVIEW_WIDTH = 300
local PREVIEW_HEIGHT = 96
local GROUP_GAP = 5

--- Runs `fn` once on the next UI tick (lets a dialog appear before slow work).
local function defer(fn)
	local timer
	timer = Timer {
		interval = 0.05,
		ontick = function()
			timer:stop()
			fn()
		end,
	}
	timer:start()
end

local GROUP_GAP = 5

local function hex(color)
	local text = string.format("#%02X%02X%02X", color.r, color.g, color.b)
	if color.a ~= 255 then
		text = text .. string.format(" a%d", color.a)
	end
	return text
end

--- Shows a non-modal dialog where it was last closed (position kept in plugin preferences,
--- kept inside the main window).
local function show_remembered(dialog, key)
	dialog:show { wait = false }
	local saved = Preferences.plugin.preferences[key]
	if type(saved) == "table" and saved.x and saved.y then
		local bounds = dialog.bounds
		local x, y = saved.x, saved.y
		if app.window then
			x = math.max(0, math.min(x, app.window.width - bounds.width))
			y = math.max(0, math.min(y, app.window.height - bounds.height))
		end
		dialog.bounds = Rectangle(x, y, bounds.width, bounds.height)
	end
	-- Canvases repainted before show() aren't painted again on their own.
	dialog:repaint()
end

--- Installs a preset, asking before replacing one this extension didn't install.
--- @return string|nil path
--- @return string|nil error
local function install_preset(palette, name)
	local path, err, exists = Palettes.install(palette, name)
	if exists then
		local choice = app.alert {
			title = "Install to Presets",
			text = { err, "Replace it?" },
			buttons = { "&Replace", "&Cancel" },
		}
		if choice ~= 1 then
			return nil
		end
		path, err = Palettes.install(palette, name, true)
	end
	return path, err
end

--------------------------------------------------------------------------------
-- Swatches
--------------------------------------------------------------------------------

--- Ramp of a named color: "Red-2" -> "Red".
local function ramp_of(color)
	return color.name and color.name:match("^(.-)[%s%-_]*%d+$") or nil
end

--- Swatch rectangles: named ramps stay on one row when they fit, other colors flow.
--- @return Rectangle[] rects
--- @return number height
local function layout_swatches(colors, width, size)
	local rects = {}
	local x, y = 0, 0
	local i = 1
	while i <= #colors do
		local ramp = ramp_of(colors[i])
		local last = i
		if ramp then
			while last < #colors and ramp_of(colors[last + 1]) == ramp do
				last = last + 1
			end
		end
		local group_width = (last - i + 1) * size
		if x > 0 and x + group_width > width then
			x, y = 0, y + size + 2
		end
		for j = i, last do
			if x + size > width then
				x, y = 0, y + size + 2
			end
			-- Loose colors get a 1 px gap so neighbours stay apart; ramps stay solid strips.
			local inset = (not ramp and size >= 6) and 1 or 0
			rects[j] = Rectangle(x, y, size - inset, size - inset)
			x = x + size
		end
		x = x + (ramp and GROUP_GAP or 0)
		i = last + 1
	end
	return rects, (#colors > 0) and (y + size) or 0
end

--- Largest swatches (16 px down to 3) that fit the area.
local function fit_swatches(colors, width, height)
	for size = 16, 3, -1 do
		local rects, used = layout_swatches(colors, width, size)
		if used <= height then
			return rects
		end
	end
	return (layout_swatches(colors, width, 3))
end

--- Lines of `text` wrapped to `width` pixels (paragraphs split at newlines).
local function wrap(ctx, text, width)
	local lines = {}
	for paragraph in text:gmatch("[^\n]+") do
		local line = ""
		for word in paragraph:gmatch("%S+") do
			local candidate = line == "" and word or (line .. " " .. word)
			if line ~= "" and ctx:measureText(candidate).width > width then
				table.insert(lines, line)
				line = word
			else
				line = candidate
			end
		end
		table.insert(lines, line)
	end
	return lines
end

--------------------------------------------------------------------------------
-- Codebase Palettes
--------------------------------------------------------------------------------

--- Opens the Codebase Palettes dialog: a list of the registry's palettes, the selected one's
--- swatches and notes, and a button installing it into Aseprite's palette Presets. The dialog
--- keeps one size whatever is selected or hovered. Download failures are never shown: the
--- registry falls back to its cache and the bundled copy.
--- @return Dialog dialog
function PaletteDialogs.codebase()
	local registry = Registry.load("palettes", { online = true })
	local state = {
		entries = Palettes.entries(registry),
		index = 1,
		palettes = {}, -- entry id -> PaletteData, or false when unusable
		hovered = nil,
		status = "",
		swatches = {}, -- rectangles in the detail canvas, set by its onpaint
	}

	local function palette_of(entry)
		local palette = state.palettes[entry.id]
		if palette == nil then
			palette = Palettes.load_entry(entry, { online = true }) or false
			state.palettes[entry.id] = palette
		end
		return palette
	end

	local dialog

	function state.select(index)
		if index < 1 or index > #state.entries or index == state.index then return end
		state.index, state.hovered, state.status = index, nil, ""
		palette_of(state.entries[index])
		dialog:repaint()
	end

	local function install()
		local entry = state.entries[state.index]
		local palette = entry and palette_of(entry)
		if not palette then
			app.alert { title = "Install to Presets", text = "This palette can't be read." }
			return
		end
		local path, err = install_preset(palette, entry.name)
		if err then
			app.alert { title = "Install to Presets", text = err }
		elseif path then
			state.status = "Installed: Palette > Presets > " .. app.fs.fileTitle(path)
			dialog:repaint()
		end
	end

	dialog = Dialog {
		title = "Codebase Palettes",
		onclose = function()
			local bounds = dialog.bounds
			Preferences.plugin.preferences.palettes_position = { x = bounds.x, y = bounds.y }
		end,
	}

	dialog:canvas {
		id = "list",
		width = SIDEBAR_WIDTH,
		height = HEIGHT,
		onpaint = function(ev)
			local ctx = ev.context
			ctx.color = app.theme.color.background
			ctx:fillRect(Rectangle(0, 0, ctx.width, ctx.height))
			for i, entry in ipairs(state.entries) do
				local y = (i - 1) * ROW_HEIGHT
				local text_height = ctx:measureText(entry.name).height
				if i == state.index then
					ctx.color = app.theme.color.selected
					ctx:fillRect(Rectangle(0, y, ctx.width, ROW_HEIGHT))
					ctx.color = app.theme.color.selected_text
				else
					ctx.color = app.theme.color.text
				end
				ctx:fillText(entry.name, PAD, y + (ROW_HEIGHT - text_height) // 2)
			end
		end,
		onmousedown = function(ev)
			state.select(ev.y // ROW_HEIGHT + 1)
		end,
		onmousemove = function(ev)
			state.mouse = { x = ev.x, y = ev.y }
		end,
		onkeydown = function(ev)
			if ev.code == "ArrowUp" then
				state.select(state.index - 1)
			elseif ev.code == "ArrowDown" then
				state.select(state.index + 1)
			end
		end,
	}

	dialog:canvas {
		id = "detail",
		width = DETAIL_WIDTH,
		height = HEIGHT,
		onpaint = function(ev)
			local ctx = ev.context
			local entry = state.entries[state.index]
			local palette = entry and palette_of(entry)
			local function text(value, x, y, color)
				ctx.color = color or app.theme.color.text
				ctx:fillText(value, x, y)
			end
			if not entry then
				text("No palettes available", PAD, PAD)
				return
			end

			text(palette and string.format("%s - %d colors", entry.name, #palette.colors) or entry.name, 0, PAD)
			local colors = palette and palette.colors or {}
			local rects = fit_swatches(colors, ctx.width, SWATCHES_HEIGHT)
			state.swatches = {}
			for i, color in ipairs(colors) do
				local rect = Rectangle(rects[i].x, rects[i].y + SWATCHES_TOP, rects[i].width, rects[i].height)
				state.swatches[i] = rect
				if color.a < 255 then
					local half = rect.width // 2
					ctx.color = Color { r = 204, g = 204, b = 204 }
					ctx:fillRect(rect)
					ctx.color = Color { r = 255, g = 255, b = 255 }
					ctx:fillRect(Rectangle(rect.x, rect.y, half, half))
					ctx:fillRect(Rectangle(rect.x + half, rect.y + half, rect.width - half, rect.height - half))
				end
				ctx.color = Color { r = color.r, g = color.g, b = color.b, a = color.a }
				ctx:fillRect(rect)
			end

			local hovered = state.hovered
			if hovered then
				text(hex(hovered) .. (hovered.name and ("  " .. hovered.name) or ""), 0, HOVER_TOP)
			end

			local y = TEXT_TOP
			for _, note in ipairs { entry.description, entry.guidelines } do
				if note and note ~= "" then
					for _, line in ipairs(wrap(ctx, note, ctx.width)) do
						text(line, 0, y)
						y = y + ctx:measureText(line).height + 2
					end
					y = y + 6
				end
			end

			text(state.status, 0, ctx.height - STATUS_HEIGHT)
		end,
		onmousemove = function(ev)
			local hovered = nil
			for i, rect in pairs(state.swatches) do
				if rect:contains(Point(ev.x, ev.y)) then
					hovered = state.palettes[state.entries[state.index].id].colors[i]
					break
				end
			end
			if hovered ~= state.hovered then
				state.hovered = hovered
				dialog:repaint()
			end
		end,
	}

	dialog:newrow()
	dialog:button {
		id = "install",
		text = "&Install to Presets",
		focus = true,
		onclick = install,
	}
	dialog:button {
		text = "&Close",
		onclick = function() dialog:close() end,
	}

	if #state.entries > 0 then
		palette_of(state.entries[1])
	end
	show_remembered(dialog, "palettes_position")

	PaletteDialogs.codebase_state = state
	return dialog
end
