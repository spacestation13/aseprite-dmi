--- GUI: the Palettes dialogs on a real DMI state sprite, with screenshots of each
--- (<run>/screenshots/codebase.png, check.png, check_selected.png, from_dmi.png).
--- py tools/aseprite_runner.py tools/tests/gui_palettes.lua --gui --screenshot final.png
--- The network is stubbed: "downloads" copy the bundled registry files.

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")

-- Serve this repo's registry URLs from the bundled copy; anything else fails, and everything
-- fails while `offline`.
local downloads = {}
local offline = false
Registry.download = function(url, dest)
	table.insert(downloads, url)
	if offline then return nil, "timed out (test stub)" end
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

	-- Offline: the list download fails, so the palette isn't fetched (no second timeout) and
	-- comes from the bundled copy.
	function(next, s)
		sprite = s
		offline = true
		dialog = PaletteDialogs.codebase()
		T.eq(#downloads, 0, "nothing downloaded before the dialog shows")
		T.wait_until(function() return PaletteDialogs.codebase_state.list_info.error end, next,
			{ what = "failed refresh" })
	end,
	function(next)
		local state = PaletteDialogs.codebase_state
		T.after(0.3, function()
			T.eq(#downloads, 1, "only the list download was tried")
			T.eq(state.list_info.source, "bundled", "bundled list")
			T.eq(state.palette_info.source, "bundled", "bundled palette")
			T.eq(#state.palette.colors, 78)
			dialog:close()
			-- Back online, past the retry back-off.
			offline = false
			local real_now = Registry.now
			Registry.now = function() return real_now() + Registry.RETRY_AFTER end
			next()
		end)
	end,

	-- Codebase Palettes: opens from the bundled copy, then the deferred refresh "downloads".
	function(next)
		downloads = {}
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
	-- Controls follow the active sprite (sitechange): no "all open states" on a non-DMI sprite.
	function(next)
		local state = PaletteDialogs.codebase_state
		T.eq(state.shows_all_states, true, "state sprite active")
		local outsider = Sprite(8, 8)
		T.wait_until(function() return state.shows_all_states == false end, function()
			T.eq(state.can_apply, true, "Apply still enabled for the other sprite")
			outsider:close()
			app.sprite = sprite
			T.wait_until(function() return state.shows_all_states == true end, next,
				{ what = "controls back for the state sprite" })
		end, { what = "controls updated for a non-DMI sprite" })
	end,
	-- A closed state tab isn't touched when applying to all open states.
	function(next)
		local state = PaletteDialogs.codebase_state
		T.eq(#Palettes.target_sprites(sprite, true), 2, "all open states of the DMI")
		local other = editor.open_sprites[1].sprite == sprite and editor.open_sprites[2].sprite
			or editor.open_sprites[1].sprite
		other:close()
		app.sprite = sprite
		local targets = Palettes.target_sprites(sprite, true)
		T.eq(#targets, 1, "closed state skipped")
		Palettes.apply(targets, state.palette)
		T.eq(#sprite.palettes[1], 78, "goon palette applied")
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
	-- Removing a state while a palette dialog listens to sitechange keeps the other open states
	-- tracked (closing its sprite fires sitechange in the middle of remove_state).
	function(next)
		for i = 3, 5 do
			editor:open_state(editor.dmi.states[i])
		end
		T.wait_until(function() return #editor.open_sprites >= 4 end, next, { what = "more state sprites" })
	end,
	function(next)
		editor:gc_open_sprites() -- drop the state tab closed earlier
		local first = editor.open_sprites[1]
		local others = {}
		for i = 2, #editor.open_sprites do
			table.insert(others, editor.open_sprites[i])
		end
		app.sprite = first.sprite
		T.after(0.3, function()
			editor:remove_state(first.state)
			T.eq(#editor.open_sprites, #others, "only the removed state is untracked")
			for _, other in ipairs(others) do
				T.ok(table.index_of(editor.open_sprites, other), "still tracked: " .. other.state.name)
				T.ok(Editor.is_sprite_open(other.sprite), "still open: " .. other.state.name)
			end
			dialog:close()
			next()
		end)
	end,
	function()
		T.done()
	end,
}
