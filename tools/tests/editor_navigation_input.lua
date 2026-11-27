--- GUI, real (posted) input: keyboard navigation, type-ahead, find bindings, Delete with its
--- confirmation, Ctrl+click selection, and that grid keys never reach the active sprite.
--- py tools/aseprite_runner.py tools/tests/editor_navigation_input.lua --gui --screenshot out.png

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")
local editor, dialog, origin, sprite
local RED = app.pixelColor.rgba(255, 0, 0, 255)

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

local function cursor_name()
	local i = editor:cursor_index()
	return i and editor.dmi.states[i].name
end

--- Middle click on empty canvas space: gives the canvas keyboard focus without changing the selection.
local function focus_canvas()
	return { click = { x = origin.x + 4, y = origin.y + editor.canvas_height - 4 }, dialog = dialog, button = "middle" }
end

local tool_id, fg

local function sprite_untouched(what)
	T.eq(#sprite.frames, 2, what .. ": frames")
	T.eq(app.frame and app.frame.frameNumber, 1, what .. ": active frame")
	T.eq(app.tool.id, tool_id, what .. ": tool")
	T.eq(app.fgColor.rgbaPixel, fg, what .. ": foreground colour")
	T.eq(sprite.selection.bounds, Rectangle(0, 0, 8, 8), what .. ": selection")
	local image = sprite.cels[1].image
	T.eq({ image.width, image.height }, { 8, 8 }, what .. ": cel size")
	T.eq(sprite.cels[1].position, Point(0, 0), what .. ": cel position")
	for it in image:pixels() do
		if it() ~= RED then T.fail(what .. ": sprite pixels changed") end
	end
end

T.steps {
	function(next)
		app.command.OpenFile { filename = path }
		T.wait_until(function()
			local e = open_editors[1]
			return e and not e.loading and e.dmi and e.dialog and #e.widgets > 0 and e
		end, next, { what = "DMI Editor" })
	end,

	-- An ordinary sprite with content and a full selection: Delete/arrows reaching it would change it.
	function(next, e)
		editor, dialog = e, e.dialog
		sprite = Sprite(8, 8)
		sprite.cels[1].image:clear(RED)
		sprite:newEmptyFrame()
		app.frame = sprite.frames[1]
		-- Undoable, so a Ctrl+Z reaching the sprite would show.
		app.transaction("select all", function() sprite.selection:selectAll() end)
		tool_id, fg = app.tool.id, app.fgColor.rgbaPixel
		T.eq(app.sprite, sprite, "test sprite active")

		local seen
		editor.onmousemove = function(self, ev)
			seen = { x = ev.x, y = ev.y }
			return Editor.onmousemove(self, ev)
		end
		local a = { x = dialog.bounds.width // 2, y = dialog.bounds.height // 3 }
		T.input({ { move = a, dialog = dialog }, { wait = 0.1 } }, function()
			T.ok(seen, "canvas got no mouse move")
			editor.onmousemove = nil
			origin = { x = a.x - seen.x, y = a.y - seen.y }
			next()
		end)
	end,

	-- Arrows (4 columns: carp_rift carp_rift_carpspawn carp_rift_charged anom / bhole2 immrod bhole3 portal / portal1)
	function(next)
		T.detail("grid", editor.max_in_a_row .. "x" .. editor.max_in_a_column)
		T.eq(editor.max_in_a_row, 4, "grid columns")
		T.input({ focus_canvas(), { wait = 0.1 }, { key = "Right" }, { key = "Right" }, { key = "Down" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), "immrod", "Right, Right, Down")
		T.input({ { key = "Shift+Left" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "immrod", "bhole2" }, "Shift+Left extends")
		T.input({ { key = "End" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "portal1" }, "End")
		T.input({ { key = "Home" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift" }, "Home")
		sprite_untouched("after arrows")
		-- Type-ahead
		T.input({ { text = "b" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), "bhole2", "type b")
		T.input({ { text = "b" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), "bhole3", "type b again cycles")
		T.input({ { wait = 2 }, { text = "i" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), "immrod", "buffer reset by the timer")
		T.input({ { wait = 2 }, { text = "po" }, { wait = 0.1 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), "portal", "type po")
		T.screenshot("typeahead", next)
	end,

	-- Ctrl+F: the focused canvas consumes it before Aseprite's AdvancedMode shortcut.
	function(next)
		T.input({ { wait = 1.2 }, { key = "Ctrl+F" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(editor.find_dialog, "Ctrl+F opened Find States")
		sprite_untouched("after Ctrl+F")
		T.input({ { text = "carp" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift", "carp_rift_carpspawn", "carp_rift_charged" }, "find selects matches")
		T.screenshot("find_ctrl_f", next)
	end,
	function(next)
		-- Closing Find hands keyboard focus back to the grid: no click needed.
		T.input({ { key = "Escape" }, { wait = 0.3 }, { text = "/" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.screenshot("slash", next)
	end,
	function(next)
		T.ok(editor.find_dialog, "/ opened Find States")
		-- Esc closes Find and (focus back on the grid) clears the grid selection; the canvas consumes
		-- it, so Aseprite's Cancel doesn't drop the active sprite's selection.
		sprite_untouched("after Esc in Find + /")
		editor.find_dialog:close()
		-- Ctrl+click only toggles the selection; it doesn't open the state.
		T.input({ { click = icon_center("anom"), dialog = dialog, mods = "Ctrl" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(table.index_of(editor.selected_states, editor.dmi.states[4]) > 0, "Ctrl+click selected anom")
		T.eq(#editor.open_sprites, 0, "Ctrl+click opened no state sprite")
		T.eq(app.sprite, sprite, "active sprite unchanged by Ctrl+click")
		sprite_untouched("after Ctrl+click")
		-- Shift+arrows extend from the Ctrl+clicked state.
		T.input({ { key = "Shift+Right" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "anom", "bhole2" }, "Shift+Right extends from the Ctrl+clicked state")
		T.input({ { key = "Escape" }, { key = "Shift+Right" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift" }, "Esc resets the Shift anchor")
		-- Keys without Ctrl/Alt never reach Aseprite (Backspace = Clear, `,` = previous frame,
		-- [ ] + = brush/colour, Space = hand tool), nor do Ctrl combos that act on the sprite.
		T.input({ { key = "Escape" }, { key = "Space" }, { key = "Backspace" }, { text = ",[]+=" },
			{ key = "Ctrl+Z" }, { key = "Ctrl+X" }, { key = "Ctrl+D" }, { key = "Ctrl+Backspace" }, { key = "Ctrl+Delete" },
			{ wait = 0.3 } }, next)
	end,
	function(next)
		sprite_untouched("after stray keys")
		T.eq(#editor.dmi.states, 9, "stray keys removed no state")
		-- Type-ahead Backspace edits the buffer.
		T.input({ { wait = 1.2 }, { text = "bhx" }, { key = "Backspace" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(editor.typeahead_buffer, "bh", "Backspace edits the type-ahead buffer")
		T.eq(cursor_name(), "bhole2", "type-ahead after Backspace")
		-- Context menu: Esc closes it, other keys don't leak.
		T.input({ { wait = 1.2 }, { click = icon_center("bhole3"), dialog = dialog, button = "right" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.ok(editor.context_widget, "context menu open")
		T.input({ { key = "Backspace" }, { text = "," }, { key = "Delete" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.ok(editor.context_widget, "context menu still open")
		sprite_untouched("keys under the context menu")
		T.eq(#editor.dmi.states, 9, "keys under the context menu removed nothing")
		T.input({ { key = "Escape" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.ok(not editor.context_widget, "Esc closes the context menu")
		sprite_untouched("after Esc on the context menu")
		-- Find: Clear keeps the focus in the query box.
		T.input({ { text = "/" }, { wait = 0.4 }, { text = "bh" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(#editor.selected_states, 2, "find bh")
		local fb = editor.find_dialog.bounds
		T.detail("find_bounds", tostring(fb))
		T.ok(fb.x >= 0 and fb.y >= 0 and fb.x + fb.width <= app.window.width and fb.y + fb.height <= app.window.height,
			"Find window inside the main window")
		T.input({ { click = { x = 100, y = 57 }, dialog = editor.find_dialog }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(#editor.selected_states, 0, "Clear")
		T.input({ { text = "por" }, { key = "Backspace" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(selected_names(), { "portal", "portal1" }, "typing after Clear goes to the query box")
		sprite_untouched("after Find Clear")
		T.input({ { key = "Escape" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.ok(not editor.find_dialog, "Esc closed Find")
		-- Delete, cancelled with Esc
		T.input({ { key = "Home" }, { key = "Delete" }, { wait = 0.5 } }, next)
	end,
	function(next) T.screenshot("delete_confirm", next) end,
	function(next)
		T.input({ { key = "Escape" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.eq(#editor.dmi.states, 9, "Esc cancels Delete")
		sprite_untouched("after Esc in alert")
		T.screenshot("after_esc", function() end)
		T.input({ { key = "Delete" }, { wait = 0.5 }, { key = "Enter" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.eq(#editor.dmi.states, 8, "Enter confirms Delete")
		T.eq(editor.dmi.states[1].name, "carp_rift_carpspawn", "first state removed")
		-- Delete / arrows / Enter with nothing selected stay on the canvas too.
		T.input({ { key = "Delete" }, { key = "Up" }, { key = "Left" }, { wait = 0.3 } }, next)
	end,
	function(next)
		sprite_untouched("after Delete and arrows")
		T.eq(app.sprite, sprite, "test sprite still active")
		T.screenshot("final", next)
	end,
	function()
		editor:close(false, true)
		sprite:close()
		T.done()
	end,
}
