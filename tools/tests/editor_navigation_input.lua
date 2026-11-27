--- GUI, real (posted) input: keyboard navigation, type-ahead, the find filter (on the sample and
--- on a generated 60-state DMI), Delete with its confirmation, Ctrl+click selection, and that grid
--- keys never reach the active sprite.
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
	return i and editor:visible_states()[i].name
end

--- Middle click on empty canvas space: gives the canvas keyboard focus without changing the selection.
local function focus_canvas()
	return { click = { x = origin.x + 4, y = origin.y + editor.canvas_height - 4 }, dialog = dialog, button = "middle" }
end

--- Finds where the editor canvas sits in its dialog (canvas positions aren't exposed to Lua).
local function calibrate(next)
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
end

--- Names of the states drawn in the grid.
local function icon_names()
	local names = {}
	for _, widget in ipairs(editor.widgets) do
		if widget.type == "IconWidget" then table.insert(names, widget.iconstate.name) end
	end
	return names
end

--- A 32x32 DMI with 60 states, 10 kinds x 6 variants, each kind in its own colour.
local function write_many_dmi()
	local dmi, err = libdmi.new_file("many", 32, 32, TEMP_DIR)
	T.ok(err == nil, err)
	local kinds = { "wall", "Floor", "door", "window", "table", "chair", "light", "pipe", "vent", "crate" }
	local variants = { "", "_broken", "_open", "_dark", "_alt", "_2" }
	for k, kind in ipairs(kinds) do
		for v, variant in ipairs(variants) do
			local state, serr = libdmi.new_state(32, 32, dmi.temp, kind .. variant)
			T.ok(serr == nil, serr)
			local image = Image(32, 32, ColorMode.RGB)
			image:clear(Color { hue = (k - 1) * 36, saturation = 0.8, value = 0.4 + v * 0.1, alpha = 255 })
			save_image_bytes(image, app.fs.joinPath(dmi.temp, state.frame_key .. ".0.bytes"))
			table.insert(dmi.states, state)
		end
	end
	local file = app.fs.joinPath(T.tmp, "many.dmi")
	local _, werr = libdmi.save_file(dmi, file)
	T.ok(werr == nil, werr)
	libdmi.remove_dir(dmi.temp, false)
	return file
end

local OOR = { "Floor", "Floor_broken", "Floor_open", "Floor_dark", "Floor_alt", "Floor_2",
	"door", "door_broken", "door_open", "door_dark", "door_alt", "door_2" }

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

		calibrate(next)
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
		T.eq(editor:state_names(), { "carp_rift", "carp_rift_carpspawn", "carp_rift_charged" }, "find filters the grid")
		T.eq(icon_names(), { "carp_rift", "carp_rift_carpspawn", "carp_rift_charged" }, "only matches drawn")
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
		T.eq(#editor:visible_states(), 9, "closing Find restores the grid")
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
		T.eq(editor:state_names(), { "bhole2", "bhole3" }, "find bh")
		local fb = editor.find_dialog.bounds
		T.detail("find_bounds", tostring(fb))
		T.ok(fb.x >= 0 and fb.y >= 0 and fb.x + fb.width <= app.window.width and fb.y + fb.height <= app.window.height,
			"Find window inside the main window")
		T.input({ { click = { x = 100, y = 57 }, dialog = editor.find_dialog }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(#editor:visible_states(), 9, "Clear restores the grid")
		T.input({ { text = "por" }, { key = "Backspace" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(editor:state_names(), { "portal", "portal1" }, "typing after Clear goes to the query box")
		sprite_untouched("after Find Clear")
		T.input({ { key = "Escape" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.ok(not editor.find_dialog, "Esc closed Find")
		T.eq(#editor:visible_states(), 9, "Esc in Find restores the grid")
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

	-- Ctrl+C on a modified open state shows "Save all open sprites first"; after the alert the
	-- keys must stay on the grid.
	function(next)
		editor:open_state(editor.dmi.states[1])
		T.wait_until(function() return editor.open_sprites[1] end, next, { what = "state sprite" })
	end,
	function(next, state_sprite)
		app.transaction("modify state", function()
			state_sprite.sprite.cels[1].image:drawPixel(0, 0, Color(0, 255, 0))
		end)
		T.ok(state_sprite.sprite.isModified, "state sprite modified")
		app.sprite = sprite
		app.frame = sprite.frames[1]
		editor:refocus_grid()
		T.input({ { wait = 0.2 }, { key = "Home" }, { key = "Ctrl+C" }, { wait = 0.6 } }, next)
	end,
	function(next) T.screenshot("copy_alert", next) end,
	function(next)
		T.input({ { key = "Enter" }, { wait = 0.4 }, { key = "Right" }, { key = "Backspace" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), editor.dmi.states[2].name, "Right after the Ctrl+C alert moves on the grid")
		T.eq(app.sprite, sprite, "test sprite active after the Ctrl+C alert")
		sprite_untouched("after the Ctrl+C alert")
		-- Ctrl+C / Ctrl+V copy and paste states (states[2] isn't open, so no alert).
		T.input({ { key = "Ctrl+C" }, { wait = 0.3 }, { key = "Ctrl+V" }, { wait = 0.5 }, { key = "Backspace" }, { key = "Left" },
			{ wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(#editor.dmi.states, 9, "Ctrl+V pasted the copied state")
		T.eq(editor.dmi.states[9].name, editor.dmi.states[2].name, "pasted copy of the selected state")
		T.eq(cursor_name(), editor.dmi.states[1].name, "keys after Ctrl+V stay on the grid")
		T.eq(app.sprite, sprite, "test sprite active after Ctrl+V")
		sprite_untouched("after Ctrl+C/Ctrl+V")
		T.screenshot("pasted", next)
	end,
	-- F2 opens the (modal) State Properties; after Esc closes it the keys stay on the grid.
	function(next)
		T.input({ { key = "F2" }, { wait = 0.5 } }, next)
	end,
	function(next) T.screenshot("f2_properties", next) end,
	function(next)
		T.input({ { key = "Escape" }, { wait = 0.4 }, { key = "Right" }, { key = "Backspace" }, { wait = 0.3 } }, next)
	end,
	function(next)
		T.eq(cursor_name(), editor.dmi.states[2].name, "Right after the F2 dialog moves on the grid")
		T.eq(app.sprite, sprite, "test sprite active after F2")
		sprite_untouched("after the F2 dialog")
		next()
	end,

	-- Find filter on a 60-state DMI: the grid shows and navigates only the matches.
	function(next)
		editor:close(false, true)
		app.sprite = sprite
		app.command.OpenFile { filename = write_many_dmi() }
		T.wait_until(function()
			local e = open_editors[1]
			return e and e ~= editor and not e.loading and e.dmi and e.dialog and #e.widgets > 0 and e
		end, next, { what = "60-state DMI Editor" })
	end,
	function(next, e)
		editor, dialog = e, e.dialog
		T.eq(#editor.dmi.states, 60, "60 states")
		app.sprite = sprite
		app.frame = sprite.frames[1]
		calibrate(next)
	end,
	function(next)
		T.detail("many_grid", editor.max_in_a_row .. "x" .. editor.max_in_a_column)
		T.ok(#icon_names() < 60, "the 60 states don't fit unfiltered")
		T.input({ focus_canvas(), { wait = 0.1 }, { text = "/" }, { wait = 0.4 }, { text = "oor" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(editor.find_dialog, "/ opened Find States")
		T.eq(editor:state_names(), OOR, "the filter shows only the 12 matches")
		local drawn = math.min(#OOR, editor.max_in_a_row * (editor.max_in_a_column + 1))
		T.eq(icon_names(), { table.unpack(OOR, 1, drawn) }, "only matches drawn")
		T.ok(editor.title:find("12 of 60 states", 1, true), "title shows the count: " .. editor.title)
		sprite_untouched("typing in Find")
		T.screenshot("many_filtered", next)
	end,
	function(next)
		T.input({ { key = "Enter" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(not editor.find_dialog, "Enter closed Find")
		T.eq(editor.filter_query, "oor", "Enter keeps the filter")
		T.eq(cursor_name(), "Floor", "Enter put the cursor on the first match")
		T.input({ { key = "End" }, { key = "Up" }, { key = "Right" }, { wait = 0.2 } }, next)
	end,
	function(next)
		local cols, rows = editor.max_in_a_row, editor.max_in_a_column
		local i = EditorNav.move(EditorNav.move(#OOR, #OOR, cols, rows, "ArrowUp"), #OOR, cols, rows, "ArrowRight")
		T.eq(cursor_name(), OOR[i], "End, Up, Right move over the matches")
		T.input({ { key = "Home" }, { key = "PageDown" }, { key = "Shift+Home" }, { wait = 0.2 } }, next)
	end,
	function(next)
		local i = EditorNav.move(1, #OOR, editor.max_in_a_row, editor.max_in_a_column, "PageDown")
		local expected = {}
		for j = i, 1, -1 do table.insert(expected, OOR[j]) end
		T.eq(selected_names(), expected, "PageDown, Shift+Home select matches only")
		-- Type-ahead: hidden states (wall, window) aren't found.
		T.input({ { key = "Escape" }, { wait = 1.2 }, { text = "d" }, { wait = 1.2 }, { text = "w" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(editor.filter_query, "oor", "Esc with a selection only deselects")
		T.eq(cursor_name(), "door", "type-ahead finds a match, not hidden states")
		T.input({ { wait = 1.2 }, { text = "door_o" }, { wait = 0.2 }, { key = "Enter" } }, function()
			T.wait_until(function()
				for _, state_sprite in ipairs(editor.open_sprites) do
					if state_sprite.sprite and app.sprite == state_sprite.sprite then return state_sprite end
				end
			end, next, { what = "door_open opened" })
		end)
	end,
	function(next, state_sprite)
		T.ok(rawequal(state_sprite.state, editor.dmi.states[15]), "Enter opened door_open (state 15 of 60)")
		T.eq(state_sprite.state.name, "door_open", "opened state name")
		app.sprite = sprite
		app.frame = sprite.frames[1]
		editor:refocus_grid()
		T.input({ { wait = 0.2 }, { key = "Ctrl+A" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(selected_names(), OOR, "Ctrl+A selects the matches only")
		sprite_untouched("navigating the filtered grid")
		-- Clearing the reopened Find box restores the grid.
		T.input({ { key = "Escape" }, { key = "Ctrl+F" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(editor.find_dialog, "Ctrl+F reopened Find")
		T.eq(editor.filter_query, "oor", "reopened Find keeps the query")
		T.input({ { key = "Backspace" }, { key = "Backspace" }, { key = "Backspace" }, { wait = 0.4 } }, next)
	end,
	function(next)
		T.ok(editor.find_dialog, "Find still open")
		T.eq(#editor:visible_states(), 60, "clearing the query restores all 60 states")
		T.ok(not editor.title:find(" of ", 1, true), "no count in the title: " .. editor.title)
		T.screenshot("many_restored", next)
	end,
	-- Grid Esc: the first deselects, the second drops a filter kept by Enter.
	function(next)
		T.input({ { key = "Escape" }, { wait = 0.3 }, { text = "/" }, { wait = 0.4 }, { text = "door" }, { key = "Enter" },
			{ wait = 0.4 } }, next)
	end,
	function(next)
		T.eq(editor:state_names(), { "door", "door_broken", "door_open", "door_dark", "door_alt", "door_2" }, "filter door")
		T.eq(cursor_name(), "door", "cursor on the first door")
		T.input({ { key = "Escape" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq({ #editor.selected_states, editor.filter_query }, { 0, "door" }, "first Esc deselects")
		T.input({ { key = "Escape" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.eq(#editor:visible_states(), 60, "second Esc restores the grid")
		sprite_untouched("after the 60-state filter")
		T.eq(app.sprite, sprite, "test sprite still active")
		next()
	end,
	function()
		editor:close(false, true)
		sprite:close()
		T.done()
	end,
}
