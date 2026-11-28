--- GUI: the Palettes dialogs on a real DMI state sprite, for screenshots.
--- py tools/aseprite_runner.py tools/tests/gui_palettes.lua --gui --screenshot codebase.png
---   --param dialog=codebase|from_dmi|check   (default codebase)
--- The network is stubbed: "downloads" copy the bundled registry files.

T.async()

local which = T.param("dialog", "codebase")
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

T.wait_until(function() return libdmi and open_editors and Registry.bundled_dir end, function()
	T.ok(app.fs.isFile(app.fs.joinPath(Registry.bundled_dir, "palettes.json")), "bundled registry installed")
	app.command.OpenFile { filename = path }

	T.wait_until(function()
		local editor = open_editors[1]
		return editor and not editor.loading and editor.dmi and editor
	end, function(editor)
		editor:open_state(editor.dmi.states[1])

		T.wait_until(function() return app.sprite and #editor.open_sprites > 0 and app.sprite end, function(sprite)
			if which == "codebase" then
				local dialog = PaletteDialogs.codebase()
				T.ok(dialog, "dialog")
				-- The deferred online refresh downloads the list and the palette.
				T.wait_until(function() return #downloads >= 2 end, function()
					local state = PaletteDialogs.codebase_state
					T.eq(state.entry and state.entry.id, "goonstation", "selected entry")
					T.eq(state.list_info.source, "network", "list refreshed")
					T.eq(#state.palette.colors, 78, "palette loaded")
					T.eq(state.palette_info.source, "network", "palette downloaded")
					-- Apply to every open state of the DMI, then check colors against it.
					dialog:modify { id = "all_states", selected = true }
					Palettes.apply(Palettes.target_sprites(sprite, true), state.palette)
					T.eq(#sprite.palettes[1], 78, "goon palette applied")
					T.detail("downloads", downloads)
					T.after(1, T.done)
				end, { what = "palette download" })
			elseif which == "from_dmi" then
				local dialog = PaletteDialogs.from_dmi()
				T.ok(dialog, "dialog")
				local state = PaletteDialogs.from_dmi_state
				T.eq(#state.paths, 1, "starts with the open DMI")
				T.eq(state.paths[1]:lower(), path:lower())
				T.ok(state.palette and #state.palette.colors > 0, "colors collected")
				T.detail("colors", #state.palette.colors)
				T.after(1, T.done)
			else
				local registry = Registry.load("palettes")
				local goon = Palettes.load_entry(Palettes.entries(registry)[1])
				Palettes.apply({ sprite }, goon)
				local dialog = PaletteDialogs.check_colors()
				T.ok(dialog, "dialog")
				local report = PaletteDialogs.check_report
				T.ok(report.colors > 0, "colors counted")
				T.detail("colors", report.colors)
				T.detail("off_palette", #report.off_palette)
				T.after(1, T.done)
			end
		end, { what = "state sprite" })
	end, { what = "DMI Editor to open " .. path })
end, { what = "plugin init" })
