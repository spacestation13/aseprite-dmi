--- GUI smoke test: opening a .dmi through Aseprite's OpenFile command goes through
--- the real plugin (newFileFormat + aftercommand hook) and shows the DMI Editor.
--- py tools/aseprite_runner.py tools/tests/gui_smoke.lua --gui --screenshot out.png

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")

-- Extension init runs before --script scenarios; this guards against that changing.
T.wait_until(function() return libdmi and open_editors end, function()
	app.command.OpenFile { filename = path }

	T.wait_until(function()
		local editor = open_editors[1]
		return editor and not editor.loading and editor.dmi and editor
	end, function(editor)
		T.eq(#open_editors, 1, "one editor open")
		T.eq(editor:path():lower(), path:lower(), "editor path")
		T.eq(editor.dmi.name, "anomaly", "dmi name")
		T.eq(#editor.dmi.states, 9, "state count")
		T.ok(editor.dialog, "editor dialog shown")
		T.ok(not app.sprite, "placeholder sprite closed")
		T.detail("dialog_bounds", tostring(editor.dialog.bounds))
		-- Let the dialog paint its state previews before the runner screenshots.
		T.after(1, T.done)
	end, { what = "DMI Editor to open " .. path })
end, { what = "plugin init" })
