--- GUI: the Palettes dialogs on a real DMI state sprite, with screenshots of each
--- (<run>/screenshots/codebase.png, check.png, check_selected.png, from_dmi.png).
--- py tools/aseprite_runner.py tools/tests/gui_palettes.lua --gui --screenshot final.png
--- The network is stubbed: "downloads" copy the bundled registry files.

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")

-- Serve this repo's registry URLs from the bundled copy; anything else fails.
local downloads = {}
Registry.download = function(url, dest)
	table.insert(downloads, url)
	local source = Registry.bundled_path(url)
	local input = source and io.open(source, "rb")
	if not input then return nil, "404 (test stub)" end
	local text = input:read("a")
	input:close()
	local output = assert(io.open(dest, "wb"))
	output:write(text)
	output:close()
	return #text
end

local editor, sprite, dialog

T.steps {
	function(next)
		T.wait_until(function() return libdmi and open_editors and Registry.bundled_dir end, next,
			{ what = "plugin init" })
	end,
	function(next)
		T.ok(app.fs.isFile(app.fs.joinPath(Registry.bundled_dir, "palettes.json")), "bundled registry installed")
		app.command.OpenFile { filename = path }
		T.wait_until(function()
			local e = open_editors[1]
			return e and not e.loading and e.dmi and e
		end, next, { what = "DMI Editor to open " .. path })
	end,
	function(next, e)
		editor = e
		editor:open_state(editor.dmi.states[1])
		editor:open_state(editor.dmi.states[2])
		T.wait_until(function() return #editor.open_sprites >= 2 and app.sprite end, next, { what = "state sprites" })
	end,

	-- Codebase Palettes: opens from the bundled copy, then the deferred refresh "downloads".
	function(next, s)
		sprite = s
		dialog = PaletteDialogs.codebase()
		T.ok(dialog, "codebase dialog")
		T.eq(#downloads, 0, "nothing downloaded before the dialog shows")
		T.wait_until(function() return #downloads >= 2 end, next, { what = "registry refresh" })
	end,
	function(next)
		local state = PaletteDialogs.codebase_state
		T.eq(state.entry and state.entry.id, "goonstation", "selected entry")
		T.eq(state.list_info.source, "network", "list refreshed")
		T.eq(state.palette_info.source, "network", "palette downloaded")
		T.eq(#state.palette.colors, 78, "palette loaded")
		T.eq(#downloads, 2, "one download each")
		T.after(0.5, function() T.screenshot("codebase", next) end)
	end,
	-- Hovering a swatch names it (posted mouse moves; the canvas offset isn't exposed, so scan
	-- down from below the description labels until a swatch answers).
	function(next)
		local state = PaletteDialogs.codebase_state
		local y = 40
		local function try()
			if state.hovered or y > 120 then return next() end
			T.input({ { move = { x = 48, y = y }, dialog = dialog }, { wait = 0.1 } }, function()
				y = y + 4
				try()
			end)
		end
		try()
	end,
	function(next)
		local state = PaletteDialogs.codebase_state
		T.ok(state.hovered, "hovering a swatch reports its color")
		T.eq(state.hovered and state.hovered.name, "Steel-1", "first swatch hovered")
		T.screenshot("codebase_hover", next)
	end,
	function(next)
		local state = PaletteDialogs.codebase_state
		local targets = Palettes.target_sprites(sprite, true)
		T.eq(#targets, 2, "all open states of the DMI")
		Palettes.apply(targets, state.palette)
		for _, target in ipairs(targets) do
			T.eq(#target.palettes[1], 78, "goon palette applied")
		end
		dialog:close()
		next()
	end,

	-- Check Colors against the goon palette, then select the off-palette pixels.
	function(next)
		dialog = PaletteDialogs.check_colors()
		local report = PaletteDialogs.check_report
		T.ok(report.colors > 0, "colors counted")
		T.ok(#report.off_palette > 0, "anomaly isn't drawn with goon's palette")
		T.detail("check", { colors = report.colors, off = #report.off_palette, off_pixels = report.off_pixels })
		T.after(0.5, function() T.screenshot("check", next) end)
	end,
	function(next)
		local pixels = Palettes.select_off_palette(sprite, app.frame.frameNumber)
		T.ok(pixels > 0, "pixels selected")
		T.ok(not sprite.selection.isEmpty, "selection set")
		app.refresh()
		T.after(0.5, function() T.screenshot("check_selected", next) end)
	end,

	-- Palette from DMI: starts with the open DMI.
	function(next)
		dialog:close()
		dialog = PaletteDialogs.from_dmi()
		local state = PaletteDialogs.from_dmi_state
		T.eq(#state.paths, 1, "starts with the open DMI")
		T.eq(state.paths[1]:lower(), path:lower())
		T.ok(state.palette and #state.palette.colors > 0, "colors collected")
		T.detail("from_dmi_colors", #state.palette.colors)
		T.after(0.5, function() T.screenshot("from_dmi", next) end)
	end,
	function()
		T.done()
	end,
}
