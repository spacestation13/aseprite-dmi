--- Dialogs of `File > DMI Editor > Palettes` (logic in palettes.lua and registry.lua).
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

local function hex(color)
	local text = string.format("#%02X%02X%02X", color.r, color.g, color.b)
	if color.a and color.a ~= 255 then
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

local function remember_position(dialog, key)
	local bounds = dialog.bounds
	Preferences.plugin.preferences[key] = { x = bounds.x, y = bounds.y }
end

--- Calls `fn` whenever the active sprite/frame changes; returns a function that stops it (call
--- it from the dialog's onclose). Never call this from inside an app.events callback.
local function watch_site(fn)
	local id = app.events:on("sitechange", fn)
	return function()
		if id then
			app.events:off(id)
			id = nil
		end
	end
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
			return nil, "Not installed: " .. err
		end
		path, err = Palettes.install(palette, name, true)
	end
	return path, err
end

--- Updates the controls that depend on the active sprite (Apply, Install, the "all open
--- states" check) of the Codebase Palettes / Palette from DMI dialogs.
local function update_sprite_controls(dialog, state)
	state.can_apply = state.palette ~= nil and app.sprite ~= nil
	state.shows_all_states = Palettes.state_sprite_of(app.sprite) ~= nil
	dialog:modify { id = "apply", enabled = state.can_apply }
	dialog:modify { id = "install", enabled = state.palette ~= nil }
	dialog:modify { id = "all_states", visible = state.shows_all_states }
end

--------------------------------------------------------------------------------
-- Swatch preview
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

--- Largest swatches (16 px down to 3) that fit the canvas.
local function fit_swatches(colors, width, height)
	for size = 16, 3, -1 do
		local rects, used = layout_swatches(colors, width, size)
		if used <= height then
			return rects
		end
	end
	return (layout_swatches(colors, width, 3))
end

--- "#RRGGBB  Name  (12 px)".
local function describe_color(color)
	local text = hex(color)
	if color.name then text = text .. "  " .. color.name end
	if color.count then text = text .. string.format("  (%d px)", color.count) end
	return text
end

--- A canvas showing colors as swatches; `on_hover(color|nil)` follows the mouse.
--- @param dialog Dialog
--- @param id string
--- @param get_colors fun(): table[]|nil Colors with r, g, b, a and optional name/count.
--- @param empty_text string
--- @param on_hover fun(color: table|nil)
local function swatch_canvas(dialog, id, get_colors, empty_text, on_hover)
	local rects, layout_key = {}, nil
	local hovered = nil

	dialog:canvas {
		id = id,
		width = PREVIEW_WIDTH,
		height = PREVIEW_HEIGHT,
		onpaint = function(ev)
			local ctx = ev.context
			local colors = get_colors() or {}
			if #colors == 0 then
				local size = ctx:measureText(empty_text)
				ctx.color = app.theme.color.text
				ctx:fillText(empty_text, (ctx.width - size.width) / 2, (ctx.height - size.height) / 2)
				rects, layout_key = {}, nil
				return
			end
			if not layout_key or layout_key[1] ~= colors or layout_key[2] ~= ctx.width or layout_key[3] ~= ctx.height then
				rects, layout_key = fit_swatches(colors, ctx.width, ctx.height), { colors, ctx.width, ctx.height }
			end
			for i, color in ipairs(colors) do
				local rect = rects[i]
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
		end,
		onmousemove = function(ev)
			local color = nil
			for i, rect in pairs(rects) do
				if rect:contains(Point(ev.x, ev.y)) then
					color = layout_key[1][i]
					break
				end
			end
			if color ~= hovered then
				hovered = color
				on_hover(color)
			end
		end,
	}
end

--------------------------------------------------------------------------------
-- Codebase Palettes
--------------------------------------------------------------------------------

--- Opens the Codebase Palettes dialog. The list shows at once from the cache or the bundled
--- copy; the registry is then refreshed from the network if it is stale.
--- @return Dialog dialog
function PaletteDialogs.codebase()
	local prefs = Preferences.plugin.preferences
	local state = { entries = {}, entry = nil, palette = nil, list_info = nil, palette_info = nil }
	local dialog

	local function entry_label(entry)
		if entry.codebase and entry.codebase ~= entry.name then
			return entry.name .. " (" .. entry.codebase .. ")"
		end
		return entry.name
	end

	local function update_controls()
		update_sprite_controls(dialog, state)
	end

	local function update_status(message)
		local list = state.list_info and Registry.describe(state.list_info) or ""
		dialog:modify { id = "status", text = message or ("List: " .. list) }
		if state.palette then
			state.palette_text = string.format("%d colors - %s", #state.palette.colors,
				Registry.describe(state.palette_info))
		elseif state.palette_info then
			state.palette_text = Registry.describe(state.palette_info)
		else
			state.palette_text = ""
		end
		dialog:modify { id = "palette_status", text = state.palette_text }
		update_controls()
	end

	local function show_entry(options)
		local entry = state.entry
		state.palette, state.palette_info = nil, nil
		if entry then
			dialog:modify { id = "description", text = entry.description or "" }
			dialog:modify { id = "guidelines", text = entry.guidelines or "" }
			state.palette, state.palette_info = Palettes.load_entry(entry, options)
		end
		dialog:repaint()
		update_status()
	end

	local function select_entry(label)
		state.entry = nil
		for _, entry in ipairs(state.entries) do
			if entry_label(entry) == label then
				state.entry = entry
				prefs.palettes_last_entry = entry.id
			end
		end
	end

	local function load_list(options)
		local registry, info = Registry.load("palettes", options)
		state.list_info = info
		state.entries = Palettes.entries(registry)
		local labels, selected = {}, nil
		for _, entry in ipairs(state.entries) do
			table.insert(labels, entry_label(entry))
			if entry.id == prefs.palettes_last_entry or not selected then
				selected = entry_label(entry)
			end
		end
		-- modify fires onchange; only user changes should load (and download) an entry.
		state.filling = true
		dialog:modify { id = "entry", options = labels, option = selected }
		state.filling = false
		select_entry(selected)
	end

	local stop_watching
	dialog = Dialog {
		title = "Codebase Palettes",
		onclose = function()
			if stop_watching then stop_watching() end
			remember_position(dialog, "palettes_codebase_position")
		end,
	}

	dialog:combobox {
		id = "entry",
		label = "Palette:",
		options = {},
		onchange = function()
			if state.filling then return end
			select_entry(dialog.data.entry)
			show_entry { online = true }
		end,
	}
	dialog:newrow()
	dialog:label { id = "description", text = "" }
	dialog:newrow()
	dialog:label { id = "guidelines", text = "" }
	dialog:newrow()
	swatch_canvas(dialog, "preview", function() return state.palette and state.palette.colors end,
		"No palette loaded", function(color)
			state.hovered = color
			dialog:modify { id = "palette_status", text = color and describe_color(color) or state.palette_text }
		end)
	dialog:newrow()
	dialog:label { id = "palette_status", text = "" }
	dialog:newrow()
	dialog:check {
		id = "all_states",
		text = "Apply to all open states of this DMI",
		selected = prefs.palettes_all_states ~= false,
		onclick = function() prefs.palettes_all_states = dialog.data.all_states end,
	}
	dialog:separator {}
	dialog:label { id = "status", text = "" }
	dialog:newrow()
	dialog:button {
		id = "apply",
		text = "&Apply to Sprite",
		focus = true,
		onclick = function()
			if not (state.palette and app.sprite) then return end
			local sprites = Palettes.target_sprites(app.sprite, dialog.data.all_states)
			Palettes.apply(sprites, state.palette)
			update_status(string.format("Applied %s to %d sprite%s.", state.palette.name, #sprites,
				#sprites == 1 and "" or "s"))
		end,
	}
	dialog:button {
		id = "install",
		text = "&Install to Presets",
		onclick = function()
			if not state.palette then return end
			local path, err = install_preset(state.palette, state.entry.name)
			if path then
				update_status("Installed: Palette > Presets > " .. app.fs.fileTitle(path))
			else
				update_status(err)
			end
		end,
	}
	dialog:newrow()
	dialog:button {
		text = "&Refresh",
		onclick = function()
			update_status("Downloading...")
			load_list { online = true, refresh = true }
			-- Don't wait on a second timeout when the list couldn't be downloaded.
			show_entry { online = not state.list_info.error, refresh = true }
		end,
	}
	dialog:button {
		text = "&Close",
		onclick = function() dialog:close() end,
	}

	load_list()
	show_entry()
	show_remembered(dialog, "palettes_codebase_position")
	stop_watching = watch_site(update_controls)

	defer(function()
		update_status("Checking for updates...")
		load_list { online = true }
		-- A failed list download means the network is down or hanging: don't freeze again.
		show_entry { online = not state.list_info.error }
	end)

	PaletteDialogs.codebase_state = state
	return dialog
end

--------------------------------------------------------------------------------
-- Palette from DMI
--------------------------------------------------------------------------------

--- Opens the Palette from DMI dialog: colors of .dmi/.png files by how often they're used.
--- Starts with the DMI of the active state sprite (or the active .dmi/.png file).
--- @return Dialog dialog
function PaletteDialogs.from_dmi()
	local prefs = Preferences.plugin.preferences
	local state = { paths = {}, palette = nil, counts = nil, error = nil }
	local dialog

	local function default_name()
		local first = state.paths[1]
		return first and app.fs.fileTitle(first) or "DMI palette"
	end

	local update_controls

	local function update()
		state.palette, state.counts, state.error = nil, nil, nil
		if #state.paths > 0 then
			local max = math.max(0, math.floor(dialog.data.max or 0))
			state.palette, state.counts, state.error = Palettes.collect(state.paths, max, default_name())
			if state.palette then
				for i, color in ipairs(state.palette.colors) do
					color.count = state.counts[i].count
				end
			end
		end

		local names = {}
		for i, path in ipairs(state.paths) do
			if i > 3 then
				table.insert(names, string.format("+%d more", #state.paths - 3))
				break
			end
			table.insert(names, app.fs.fileName(path))
		end
		dialog:modify { id = "files", text = #names > 0 and table.concat(names, ", ") or "None: add .dmi or .png files." }

		local summary = ""
		if state.error then
			summary = state.error
		elseif state.palette then
			summary = string.format("%d colors", #state.palette.colors)
			if #state.palette.colors < #state.counts then
				summary = summary .. string.format(" (most used of %d)", #state.counts)
			end
		end
		state.summary = summary
		dialog:modify { id = "summary", text = summary }
		dialog:modify { id = "name", text = dialog.data.name ~= "" and dialog.data.name or default_name() }
		update_controls()
		dialog:modify { id = "save", enabled = state.palette ~= nil }
		dialog:repaint()
	end

	update_controls = function()
		update_sprite_controls(dialog, state)
	end

	local function add(path)
		if not path or path == "" or not app.fs.isFile(path) then return end
		for _, existing in ipairs(state.paths) do
			if existing:lower() == path:lower() then return end
		end
		table.insert(state.paths, path)
	end

	local function named_palette()
		local name = dialog.data.name
		state.palette.name = name ~= "" and name or default_name()
		return state.palette
	end

	local stop_watching
	dialog = Dialog {
		title = "Palette from DMI",
		onclose = function()
			if stop_watching then stop_watching() end
			remember_position(dialog, "palettes_from_dmi_position")
		end,
	}

	dialog:file {
		id = "file",
		label = "Add file:",
		open = true,
		filetypes = { "dmi", "png" },
		onchange = function()
			add(dialog.data.file)
			update()
		end,
	}
	dialog:label { id = "files", label = "Files:", text = "" }
	dialog:newrow()
	dialog:number {
		id = "max",
		label = "Max colors:",
		text = tostring(prefs.palettes_max_colors or 0),
		decimals = 0,
		onchange = function()
			prefs.palettes_max_colors = math.max(0, math.floor(dialog.data.max or 0))
			update()
		end,
	}
	dialog:label { id = "summary", text = "" }
	dialog:newrow()
	swatch_canvas(dialog, "preview", function() return state.palette and state.palette.colors end,
		"No colors", function(color)
			dialog:modify { id = "summary", text = color and describe_color(color) or state.summary }
		end)
	dialog:newrow()
	dialog:entry { id = "name", label = "Name:", text = "" }
	dialog:check {
		id = "all_states",
		text = "Apply to all open states of this DMI",
		selected = prefs.palettes_all_states ~= false,
		visible = Palettes.state_sprite_of(app.sprite) ~= nil,
		onclick = function() prefs.palettes_all_states = dialog.data.all_states end,
	}
	dialog:file {
		id = "save",
		label = "Save as:",
		save = true,
		filetypes = { "gpl" },
		onchange = function()
			local path = dialog.data.save
			if not state.palette or not path or path == "" then return end
			local ok, err = Palettes.write_gpl(named_palette(), path)
			dialog:modify { id = "summary", text = ok and ("Saved " .. app.fs.fileName(path)) or err }
		end,
	}
	dialog:separator {}
	dialog:button {
		id = "apply",
		text = "&Apply to Sprite",
		focus = true,
		onclick = function()
			if not (state.palette and app.sprite) then return end
			local sprites = Palettes.target_sprites(app.sprite, dialog.data.all_states)
			Palettes.apply(sprites, named_palette())
			dialog:modify { id = "summary", text = string.format("Applied to %d sprite%s.", #sprites,
				#sprites == 1 and "" or "s") }
		end,
	}
	dialog:button {
		id = "install",
		text = "&Install to Presets",
		onclick = function()
			if not state.palette then return end
			local path, err = install_preset(named_palette())
			dialog:modify { id = "summary", text = path and ("Installed: Palette > Presets > " .. app.fs.fileTitle(path)) or err }
		end,
	}
	dialog:newrow()
	dialog:button {
		text = "C&lear Files",
		onclick = function()
			state.paths = {}
			dialog:modify { id = "name", text = "" }
			update()
		end,
	}
	dialog:button {
		text = "&Close",
		onclick = function() dialog:close() end,
	}

	-- The open DMI as saved on disk; an unsaved new DMI has no file yet.
	local state_sprite = Palettes.state_sprite_of(app.sprite)
	if state_sprite then
		add(state_sprite.editor.save_path or state_sprite.editor.open_path)
	elseif app.sprite then
		local extension = app.fs.fileExtension(app.sprite.filename):lower()
		if extension == "dmi" or extension == "png" then
			add(app.sprite.filename)
		end
	end
	update()
	show_remembered(dialog, "palettes_from_dmi_position")
	stop_watching = watch_site(update_controls)

	PaletteDialogs.from_dmi_state = state
	return dialog
end

--------------------------------------------------------------------------------
-- Check Colors
--------------------------------------------------------------------------------

local function number_list(numbers, max)
	local parts = {}
	for i, n in ipairs(numbers) do
		if i > max then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, tostring(n))
	end
	return table.concat(parts, " ")
end

--- Opens the Check Colors dialog for the active sprite: unique colors per layer and frame, and
--- the colors that aren't in the sprite's palette.
--- @return Dialog|nil dialog
function PaletteDialogs.check_colors()
	local sprite = app.sprite
	if not sprite then
		app.alert { title = "Check Colors", text = "Open a sprite first." }
		return nil
	end

	local report = Palettes.check(sprite)
	local dialog
	dialog = Dialog {
		title = "Check Colors - " .. app.fs.fileTitle(sprite.filename),
		onclose = function() remember_position(dialog, "palettes_check_position") end,
	}

	local frames = #sprite.frames
	dialog:label {
		label = "Sprite:",
		text = string.format("%d colors, %d layer%s x %d frame%s", report.colors, #report.layers,
			#report.layers == 1 and "" or "s", frames, frames == 1 and "" or "s"),
	}
	local max_layers = 8
	for i, layer in ipairs(report.layers) do
		if i > max_layers then
			dialog:newrow()
			dialog:label { text = string.format("... and %d more layers", #report.layers - max_layers) }
			break
		end
		local text = string.format("%d colors", layer.colors)
		if frames > 1 then
			text = text .. "  (frames: " .. number_list(layer.frames, 12) .. ")"
		end
		dialog:label { label = layer.name .. ":", text = text }
	end
	if frames > 1 then
		dialog:label { label = "Per frame:", text = number_list(report.frames, 16) }
	end

	dialog:separator { text = "Palette" }
	if report.palette_size == 0 then
		dialog:label { text = "The sprite's palette is empty." }
	elseif #report.off_palette == 0 then
		dialog:label { text = string.format("Every color is in the palette (%d colors).", report.palette_size) }
	else
		local off_text = string.format("%d color%s in %d pixel%s not in the palette (%d colors):",
			#report.off_palette, #report.off_palette == 1 and "" or "s", report.off_pixels,
			report.off_pixels == 1 and "" or "s", report.palette_size)
		dialog:label { id = "off_text", text = off_text }
		dialog:newrow()
		swatch_canvas(dialog, "off", function() return report.off_palette end, "", function(color)
			dialog:modify { id = "off_text", text = color and describe_color(color) or off_text }
		end)
		dialog:newrow()
		dialog:label { text = "Load a codebase palette with Palettes > Codebase Palettes." }
	end
	dialog:newrow()
	dialog:label { text = "Guides: Goon wants small palettes; Paradise 3-5 colors per sprite." }

	dialog:separator {}
	dialog:button {
		text = "&Select Off-Palette Pixels",
		enabled = #report.off_palette > 0,
		focus = true,
		onclick = function()
			if app.sprite ~= sprite then
				app.sprite = sprite
			end
			Palettes.select_off_palette(sprite, app.frame and app.frame.frameNumber or 1)
			app.refresh()
		end,
	}
	dialog:button {
		text = "&Refresh",
		onclick = function()
			dialog:close()
			PaletteDialogs.check_colors()
		end,
	}
	dialog:button {
		text = "&Close",
		onclick = function() dialog:close() end,
	}

	show_remembered(dialog, "palettes_check_position")
	PaletteDialogs.check_report = report
	return dialog
end
