--- GUI: the Codebase Palettes dialog with both bundled palettes: selecting, hovering, Install to
--- Presets into the run's user folder, and a dialog size that never changes. Screenshots:
--- <run>/screenshots/palettes_goonstation.png, palettes_hover.png, palettes_metals.png.
--- py tools/aseprite_runner.py tools/tests/gui_palettes.lua --gui --screenshot final.png
--- The network is down: every download fails and the bundled copies are used.

T.async()

---@diagnostic disable-next-line: duplicate-set-field
Registry.download = function() return nil, "offline (test stub)" end

local dialog, state, bounds, origin, hover_x

local function same_bounds(what)
	T.eq(dialog.bounds, bounds, "dialog size unchanged " .. what)
end

--- Canvas coordinates of the sidebar for a click at dialog position (x, y), found by moving the
--- mouse there (canvas positions aren't exposed to Lua).
local function calibrate(next)
	T.input({ { move = { x = 40, y = 60 }, dialog = dialog }, { wait = 0.1 } }, function()
		T.ok(state.mouse, "the sidebar saw the mouse")
		origin = { x = 40 - state.mouse.x, y = 60 - state.mouse.y }
		next()
	end)
end

local function select_row(index, next)
	T.input({
		{ click = { x = origin.x + 20, y = origin.y + (index - 1) * 20 + 10 }, dialog = dialog },
		{ wait = 0.2 },
	}, next)
end

--- Installs through the real button (first button of the dialog's last row).
local function press_install(next)
	T.input({
		{ click = { x = 50, y = dialog.bounds.height - 16 }, dialog = dialog },
		{ wait = 0.3 },
	}, next)
end

local function check_installed(entry, colors)
	local path = Palettes.preset_path(entry.name)
	T.ok(app.fs.isFile(path), "preset installed: " .. path)
	T.ok(path:lower():find(app.fs.userConfigPath:lower(), 1, true), "into the isolated user folder")
	local palette = assert(Palettes.read(path), "installed preset parses")
	T.eq(#palette.colors, colors, entry.name .. " color count")
	T.ok(Palette { fromResource = entry.name }, "Aseprite lists the preset")
end

T.steps {
	function(next)
		T.wait_until(function() return libdmi and Registry.bundled_dir end, next, { what = "plugin init" })
	end,
	function(next)
		dialog = PaletteDialogs.codebase()
		state = PaletteDialogs.codebase_state
		T.ok(#state.entries >= 2, "both bundled palettes are listed")
		T.eq(state.entries[1].id, "goonstation")
		T.eq(state.entries[2].id, "goonstation_metals")
		T.eq(state.index, 1, "first palette selected")
		T.eq(#state.palettes.goonstation.colors, 78)
		T.after(0.5, function()
			bounds = dialog.bounds
			T.screenshot("palettes_goonstation", next)
		end)
	end,
	calibrate,

	-- Hover: scan across the swatches until one answers.
	function(next)
		local x = origin.x + 100
		local function try()
			if state.hovered or x > origin.x + 500 then return next() end
			T.input({ { move = { x = x, y = origin.y + 26 }, dialog = dialog }, { wait = 0.05 } }, function()
				hover_x = x
				x = x + 3
				try()
			end)
		end
		try()
	end,
	function(next)
		T.eq(state.hovered and state.hovered.name, "Steel-1", "hovering a swatch reads its color")
		same_bounds("after hover")
		-- A click at the spot of the last move is dropped by the harness (laf has no widget under
		-- the mouse after its queued WM_MOUSELEAVE), so click two units away.
		libdmi.copy_text("before")
		app.fgColor = Color { r = 1, g = 2, b = 3, a = 255 }
		T.input({ { click = { x = hover_x + 2, y = origin.y + 26 }, dialog = dialog }, { wait = 0.3 } }, function()
			T.eq(state.status, "Copied #393A57", "clicking a swatch copies its hex to the clipboard")
			-- The clipboard itself: read back through PowerShell (Windows runs only).
			local clip = io.popen('powershell -NoProfile -Command "Get-Clipboard"'):read("a")
			T.eq(clip:gsub("%s+$", ""), "#393A57", "system clipboard holds the hex")
			local fg = app.fgColor
			T.ok(not (fg.red == 57 and fg.green == 58 and fg.blue == 87), "no sprite open: foreground color left alone")
			same_bounds("after click")
			Sprite(8, 8)
			T.input({ { click = { x = hover_x + 4, y = origin.y + 26 }, dialog = dialog }, { wait = 0.3 } }, function()
				local set = app.fgColor
				T.eq({ set.red, set.green, set.blue }, { 57, 58, 87 }, "sprite open: click also sets the foreground color")
				T.screenshot("palettes_hover", next)
			end)
		end)
	end,

	-- Install the first palette.
	function(next) press_install(next) end,
	function(next)
		check_installed(state.entries[1], 78)
		same_bounds("after install")
		next()
	end,

	-- Select the second palette with the mouse, then back with the keyboard.
	function(next) select_row(2, next) end,
	function(next)
		T.eq(state.index, 2, "second palette selected")
		T.eq(#state.palettes.goonstation_metals.colors, 35)
		same_bounds("after selecting")
		T.after(0.3, function() T.screenshot("palettes_metals", next) end)
	end,
	function(next) press_install(next) end,
	function(next)
		check_installed(state.entries[2], 35)
		same_bounds("after second install")
		-- Clicking the list focuses it; the arrows then move the selection.
		select_row(2, next)
	end,
	function(next)
		T.input({ { key = "Up" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(state.index, 1, "arrow key selects the previous palette")
		same_bounds("after arrow key")
		dialog:close()
		T.done()
	end,
}
