--- GUI input test: mouse clicks and key presses reach the DMI Editor canvas.
--- py tools/aseprite_runner.py tools/tests/gui_input.lua --gui --screenshot out.png
--- Ctrl+clicks two state previews (selection), presses F2 (State Properties),
--- types a new name and presses Enter, asserting each effect.

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")
local editor, dialog, origin

--- Dialog-relative UI point at the center of the icon of the state named `name`
--- (looked up on every call: opening a state can relayout the editor).
local function icon_center(name)
	for _, widget in ipairs(editor.widgets) do
		if widget.type == "IconWidget" and widget.iconstate and widget.iconstate.name == name then
			local b = widget.bounds
			return { x = origin.x + b.x + b.width // 2, y = origin.y + b.y + b.height // 2 }
		end
	end
	T.fail("no icon for state " .. name)
end

local function selected_names()
	local names = {}
	for i, state in ipairs(editor.selected_states) do names[i] = state.name end
	return names
end

T.steps {
	function(next)
		app.command.OpenFile { filename = path }
		T.wait_until(function()
			local e = open_editors[1]
			return e and not e.loading and e.dmi and e.dialog and e
		end, next, { what = "DMI Editor" })
	end,

	-- Calibrate where the canvas sits inside the dialog from mouse moves to two points.
	function(next, e)
		editor, dialog = e, e.dialog
		local seen
		editor.onmousemove = function(self, ev)
			seen = { x = ev.x, y = ev.y }
			return Editor.onmousemove(self, ev)
		end
		local w, h = dialog.bounds.width, dialog.bounds.height
		local a, b = { x = w // 2, y = h // 3 }, { x = w // 3, y = h // 2 }
		T.input({ { move = a, dialog = dialog }, { wait = 0.1 } }, function()
			T.ok(seen, "canvas got no mouse move (input coordinates off?)")
			local origin_a = { x = a.x - seen.x, y = a.y - seen.y }
			T.input({ { move = b, dialog = dialog }, { wait = 0.1 } }, function()
				editor.onmousemove = nil -- back to the class method
				origin = { x = b.x - seen.x, y = b.y - seen.y }
				T.eq(origin, origin_a, "canvas origin consistent across mouse moves")
				T.detail("canvas_origin_in_dialog", origin)
				next()
			end)
		end)
	end,

	-- Note: a Ctrl+click both toggles the selection (mousedown) and opens the state's
	-- sprite (mouseup runs the icon's onleftclick regardless of Ctrl).
	function(next)
		T.input({ { click = icon_center("carp_rift_carpspawn"), dialog = dialog, mods = "Ctrl" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift_carpspawn" }, "Ctrl+click selects a state")
		T.detail("sprite_after_ctrl_click", app.sprite and app.fs.fileName(app.sprite.filename))
		T.input({ { click = icon_center("carp_rift_charged"), dialog = dialog, mods = "Ctrl" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift_carpspawn", "carp_rift_charged" }, "Ctrl+click adds to the selection")
		T.screenshot("selected", next)
	end,

	-- F2 on the canvas opens State Properties (modal) for the last selected state. The
	-- opened sprite editor has keyboard focus now (F2 there is Layer Properties), so first
	-- middle-click empty canvas space: any click focuses the canvas, and a middle click
	-- only resets the zoom (selection untouched).
	function(next)
		local empty = { x = origin.x + 4, y = origin.y + editor.canvas_height - 4 }
		T.input({ { click = empty, dialog = dialog, button = "middle" }, { wait = 0.1 }, { key = "F2" }, { wait = 0.4 } },
			next)
	end,
	function(next) T.screenshot("properties", next) end,
	function(next)
		T.input({ { key = "Ctrl+A" }, { text = "renamed_by_input" }, { key = "Enter" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(editor.dmi.states[3].name, "renamed_by_input", "state renamed through the keyboard")
		T.eq(selected_names(), { "carp_rift_carpspawn", "renamed_by_input" }, "selection kept")
		T.screenshot("renamed", next)
	end,

	function()
		editor:close(false, true) -- force: no unsaved-changes prompt on exit
		T.done()
	end,
}
