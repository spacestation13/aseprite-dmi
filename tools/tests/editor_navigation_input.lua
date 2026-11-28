--- GUI, real (posted) input: keyboard navigation, type-ahead, the find filter (on the sample and
--- on a generated 60-state DMI), Delete with its confirmation, Ctrl+click selection, and that grid
--- keys never reach the active sprite.
--- py tools/aseprite_runner.py tools/tests/editor_navigation_input.lua --gui --screenshot out.png

T.async()

-- Type-ahead forgets what was typed after a pause; the real one is 1 s. Shorter here.
local TYPEAHEAD_TIMEOUT = 0.4

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

--- Calls next once pred() holds, polling every 50 ms. Gives up after 3 s and continues anyway, so
--- the assertion that follows reports the real mismatch instead of a bare timeout. pred must be
--- false until the posted input has been handled, or it proves nothing.
local function settle(pred, next)
	local ticks = 0
	T.wait_until(function()
		ticks = ticks + 1
		return pred() or ticks >= 60
	end, function() next() end, { interval = 0.05, timeout = 10 })
end

--- Posts input, then settles on pred.
local function drive(actions, pred, next)
	T.input(actions, function() settle(pred, next) end)
end

--- Waits until the type-ahead buffer has been forgotten. Only meaningful after input that filled it.
local function quiet(next)
	settle(function() return (editor.typeahead_buffer or "") == "" end, next)
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
	assert(dmi, err)
	local kinds = { "wall", "Floor", "door", "window", "table", "chair", "light", "pipe", "vent", "crate" }
	local variants = { "", "_broken", "_open", "_dark", "_alt", "_2" }
	for k, kind in ipairs(kinds) do
		for v, variant in ipairs(variants) do
			local state, serr = libdmi.new_state(32, 32, dmi.temp, kind .. variant)
			assert(state, serr)
			local image = Image(32, 32, ColorMode.RGB)
			image:clear(Color { hue = (k - 1) * 36, saturation = 0.8, value = 0.4 + v * 0.1, alpha = 255 })
			local _, werr = libdmi.save_frame_bytes(app.fs.joinPath(dmi.temp, state.frame_key .. ".0.bytes"), 32, 32, image.bytes)
			T.ok(werr == nil, werr)
			table.insert(dmi.states, state)
		end
	end
	local file = app.fs.joinPath(T.tmp, "many.dmi")
	local _, werr = libdmi.save_file(dmi, file, false)
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
		EditorNav.TYPEAHEAD_TIMEOUT = TYPEAHEAD_TIMEOUT
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
		-- The window opens wide enough for 4 columns, and the grid is centred in it.
		local pad = math.floor((editor:label_cell_width() - editor:box_bounds(1).width) / 2)
		local left = editor:box_bounds(1).x - pad
		local last = editor:box_bounds(4)
		local right = editor.canvas_width - (last.x + last.width + pad)
		T.detail("grid_margins", left .. " / " .. right)
		T.ok(left >= 5 and math.abs(left - right) <= 1, "grid centred with side padding: " .. left .. " / " .. right)
		drive({ focus_canvas(), { wait = 0.4 }, { key = "Right" }, { key = "Right" }, { key = "Down" } },
			function() return cursor_name() == "immrod" end, next)
	end,
	function(next)
		T.eq(cursor_name(), "immrod", "Right, Right, Down")
		drive({ { key = "Shift+Left" } }, function() return #editor.selected_states == 2 end, next)
	end,
	function(next)
		T.eq(selected_names(), { "immrod", "bhole2" }, "Shift+Left extends")
		drive({ { key = "End" } }, function() return selected_names()[1] == "portal1" end, next)
	end,
	function(next)
		T.eq(selected_names(), { "portal1" }, "End")
		drive({ { key = "Home" } }, function() return selected_names()[1] == "carp_rift" end, next)
	end,
	function(next)
		T.eq(selected_names(), { "carp_rift" }, "Home")
		sprite_untouched("after arrows")
		-- Type-ahead
		drive({ { text = "b" } }, function() return cursor_name() == "bhole2" end, next)
	end,
	function(next)
		T.eq(cursor_name(), "bhole2", "type b")
		drive({ { text = "b" } }, function() return cursor_name() == "bhole3" end, next)
	end,
	function(next)
		T.eq(cursor_name(), "bhole3", "type b again cycles")
		quiet(function() drive({ { text = "i" } }, function() return cursor_name() == "immrod" end, next) end)
	end,
	function(next)
		T.eq(cursor_name(), "immrod", "buffer reset by the timer")
		quiet(function() drive({ { text = "po" } }, function() return cursor_name() == "portal" end, next) end)
	end,
	function(next)
		T.eq(cursor_name(), "portal", "type po")
		T.screenshot("typeahead", next)
	end,

	-- Ctrl+F: the focused canvas consumes it before Aseprite's AdvancedMode shortcut.
	function(next)
		quiet(function() drive({ { key = "Ctrl+F" } }, function() return editor.filter_editing end, next) end)
	end,
	function(next)
		T.ok(editor.filter_editing, "Ctrl+F started the filter")
		sprite_untouched("after Ctrl+F")
		drive({ { text = "carp" } }, function() return #editor:visible_states() == 3 end, next)
	end,
	function(next)
		T.eq(editor:state_names(), { "carp_rift", "carp_rift_carpspawn", "carp_rift_charged" }, "find filters the grid")
		T.eq(icon_names(), { "carp_rift", "carp_rift_carpspawn", "carp_rift_charged" }, "only matches drawn")
		T.screenshot("find_ctrl_f", next)
	end,
	function(next)
		-- Esc clears the filter, and the grid keeps the keyboard focus: no click needed.
		drive({ { key = "Escape" }, { wait = 0.15 }, { text = "/" } },
			function() return editor.filter_editing and editor.filter_query == "" end, next)
	end,
	function(next)
		T.screenshot("slash", next)
	end,
	function(next)
		T.ok(editor.filter_editing, "/ started the filter")
		-- The canvas consumes Esc, so Aseprite's Cancel doesn't drop the active sprite's selection.
		sprite_untouched("after Esc + /")
		editor:clear_filter()
		T.eq(#editor:visible_states(), 9, "clearing restores the grid")
		-- Ctrl+click only toggles the selection; it doesn't open the state.
		drive({ { click = icon_center("anom"), dialog = dialog, mods = "Ctrl" } },
			function() return selected_names()[1] == "anom" end, next)
	end,
	function(next)
		T.ok(table.index_of(editor.selected_states, editor.dmi.states[4]) > 0, "Ctrl+click selected anom")
		T.eq(#editor.open_sprites, 0, "Ctrl+click opened no state sprite")
		T.eq(app.sprite, sprite, "active sprite unchanged by Ctrl+click")
		sprite_untouched("after Ctrl+click")
		-- Shift+arrows extend from the Ctrl+clicked state.
		drive({ { key = "Shift+Right" } }, function() return #editor.selected_states == 2 end, next)
	end,
	function(next)
		T.eq(selected_names(), { "anom", "bhole2" }, "Shift+Right extends from the Ctrl+clicked state")
		drive({ { key = "Escape" }, { key = "Shift+Right" } },
			function() return #editor.selected_states == 1 and selected_names()[1] == "carp_rift" end, next)
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
		quiet(function()
			drive({ { text = "bhx" }, { key = "Backspace" } }, function() return editor.typeahead_buffer == "bh" end, next)
		end)
	end,
	function(next)
		T.eq(editor.typeahead_buffer, "bh", "Backspace edits the type-ahead buffer")
		T.eq(cursor_name(), "bhole2", "type-ahead after Backspace")
		-- Context menu: Esc closes it, other keys don't leak.
		quiet(function()
			drive({ { click = icon_center("bhole3"), dialog = dialog, button = "right" } },
				function() return editor.context_widget end, next)
		end)
	end,
	function(next)
		T.ok(editor.context_widget, "context menu open")
		T.input({ { key = "Backspace" }, { text = "," }, { key = "Delete" }, { wait = 0.2 } }, next)
	end,
	function(next)
		T.ok(editor.context_widget, "context menu still open")
		sprite_untouched("keys under the context menu")
		T.eq(#editor.dmi.states, 9, "keys under the context menu removed nothing")
		drive({ { key = "Escape" } }, function() return not editor.context_widget end, next)
	end,
	function(next)
		T.ok(not editor.context_widget, "Esc closes the context menu")
		sprite_untouched("after Esc on the context menu")
		-- The filter bar's x clears the filter.
		drive({ { text = "/" }, { wait = 0.15 }, { text = "bh" } }, function() return editor.filter_query == "bh" end, next)
	end,
	function(next)
		T.eq(editor:state_names(), { "bhole2", "bhole3" }, "filter bh")
		local _, close = editor:filter_bar_bounds()
		drive({ { click = { x = origin.x + close.x + close.width // 2, y = origin.y + close.y + close.height // 2 },
			dialog = dialog } }, function() return not editor:filter_bar_visible() end, next)
	end,
	function(next)
		T.eq(#editor:visible_states(), 9, "the x restores the grid")
		T.ok(not editor:filter_bar_visible(), "the bar is hidden")
		quiet(function() drive({ { text = "por" }, { key = "Backspace" } }, function() return cursor_name() == "portal" end, next) end)
	end,
	function(next)
		T.eq(cursor_name(), "portal", "typing after the x goes to type-ahead")
		sprite_untouched("after the filter bar x")
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
		T.input({ { key = "Delete" }, { wait = 0.5 }, { key = "Enter" } }, function()
			settle(function() return #editor.dmi.states == 8 end, next)
		end)
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
		T.input({ { key = "Enter" }, { wait = 0.4 }, { key = "Right" }, { key = "Backspace" } }, function()
			settle(function() return cursor_name() == editor.dmi.states[2].name end, next)
		end)
	end,
	function(next)
		T.eq(cursor_name(), editor.dmi.states[2].name, "Right after the Ctrl+C alert moves on the grid")
		T.eq(app.sprite, sprite, "test sprite active after the Ctrl+C alert")
		sprite_untouched("after the Ctrl+C alert")
		-- Ctrl+C / Ctrl+V copy and paste states (states[2] isn't open, so no alert).
		T.input({ { key = "Ctrl+C" }, { wait = 0.3 }, { key = "Ctrl+V" }, { wait = 0.5 }, { key = "Backspace" }, { key = "Left" } }, function()
			settle(function() return #editor.dmi.states == 9 and cursor_name() == editor.dmi.states[1].name end, next)
		end)
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
		T.input({ { key = "Escape" }, { wait = 0.3 }, { key = "Right" }, { key = "Backspace" } }, function()
			settle(function() return cursor_name() == editor.dmi.states[2].name end, next)
		end)
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
		drive({ focus_canvas(), { wait = 0.1 }, { text = "/" }, { wait = 0.15 }, { text = "oor" } },
			function() return editor.filter_query == "oor" end, next)
	end,
	function(next)
		T.ok(editor.filter_editing, "/ started the filter")
		T.eq(editor:state_names(), OOR, "the filter shows only the 12 matches")
		local drawn = math.min(#OOR, editor.max_in_a_row * (editor.max_in_a_column + 1))
		T.eq(icon_names(), { table.unpack(OOR, 1, drawn) }, "only matches drawn")
		T.ok(editor:filter_bar_height() > 0, "the filter bar is shown")
		sprite_untouched("typing the filter")
		T.screenshot("many_filtered", next)
	end,
	function(next)
		drive({ { key = "Enter" } }, function() return not editor.filter_editing end, next)
	end,
	function(next)
		T.ok(not editor.filter_editing, "Enter stopped typing")
		T.eq(editor.filter_query, "oor", "Enter keeps the filter")
		T.eq(cursor_name(), "Floor", "Enter put the cursor on the first match")
		drive({ { key = "End" }, { key = "Up" }, { key = "Right" } }, function() return cursor_name() ~= "Floor" end, next)
	end,
	function(next)
		local cols, rows = editor.max_in_a_row, editor.max_in_a_column
		local i = EditorNav.move(EditorNav.move(#OOR, #OOR, cols, rows, "ArrowUp"), #OOR, cols, rows, "ArrowRight")
		T.eq(cursor_name(), OOR[i], "End, Up, Right move over the matches")
		drive({ { key = "Home" }, { key = "PageDown" }, { key = "Shift+Home" } }, function() return #editor.selected_states > 1 end, next)
	end,
	function(next)
		local i = EditorNav.move(1, #OOR, editor.max_in_a_row, editor.max_in_a_column, "PageDown")
		local expected = {}
		for j = i, 1, -1 do table.insert(expected, OOR[j]) end
		T.eq(selected_names(), expected, "PageDown, Shift+Home select matches only")
		-- Type-ahead: hidden states (wall, window) aren't found.
		drive({ { key = "Escape" }, { text = "d" } }, function() return cursor_name() == "door" end, function()
			quiet(function() T.input({ { text = "w" }, { wait = 0.15 } }, next) end)
		end)
	end,
	function(next)
		T.eq(editor.filter_query, "oor", "Esc with a selection only deselects")
		T.eq(cursor_name(), "door", "type-ahead finds a match, not hidden states")
		quiet(function()
			drive({ { text = "door_o" } }, function() return cursor_name() == "door_open" end, function()
				T.input({ { key = "Enter" } }, function()
					T.wait_until(function()
						for _, state_sprite in ipairs(editor.open_sprites) do
							if state_sprite.sprite and app.sprite == state_sprite.sprite then return state_sprite end
						end
					end, next, { what = "door_open opened" })
				end)
			end)
		end)
	end,
	function(next, state_sprite)
		T.ok(rawequal(state_sprite.state, editor.dmi.states[15]), "Enter opened door_open (state 15 of 60)")
		T.eq(state_sprite.state.name, "door_open", "opened state name")
		app.sprite = sprite
		app.frame = sprite.frames[1]
		editor:refocus_grid()
		drive({ { wait = 0.1 }, { key = "Ctrl+A" } }, function() return #editor.selected_states == #OOR end, next)
	end,
	function(next)
		T.eq(selected_names(), OOR, "Ctrl+A selects the matches only")
		sprite_untouched("navigating the filtered grid")
		-- Continuing a kept filter, then clearing it by backspacing.
		drive({ { key = "Escape" }, { key = "Ctrl+F" } }, function() return editor.filter_editing end, next)
	end,
	function(next)
		T.ok(editor.filter_editing, "Ctrl+F continues the filter")
		T.eq(editor.filter_query, "oor", "the kept query is still there")
		drive({ { key = "Backspace" }, { key = "Backspace" }, { key = "Backspace" } },
			function() return #editor:visible_states() == 60 end, next)
	end,
	function(next)
		T.ok(editor.filter_editing, "still typing")
		T.eq(#editor:visible_states(), 60, "clearing the query restores all 60 states")
		T.ok(editor:filter_bar_visible(), "the bar stays while typing an empty query")
		T.screenshot("many_restored", next)
	end,
	-- Grid Esc: the first deselects, the second drops a filter kept by Enter.
	function(next)
		drive({ { key = "Escape" }, { wait = 0.15 }, { text = "/" }, { wait = 0.15 }, { text = "door" }, { key = "Enter" } },
			function() return editor.filter_query == "door" and not editor.filter_editing end, next)
	end,
	function(next)
		T.eq(editor:state_names(), { "door", "door_broken", "door_open", "door_dark", "door_alt", "door_2" }, "filter door")
		T.eq(cursor_name(), "door", "cursor on the first door")
		drive({ { key = "Escape" } }, function() return #editor.selected_states == 0 end, next)
	end,
	function(next)
		T.eq({ #editor.selected_states, editor.filter_query }, { 0, "door" }, "first Esc deselects")
		drive({ { key = "Escape" } }, function() return #editor:visible_states() == 60 end, next)
	end,
	function(next)
		T.eq(#editor:visible_states(), 60, "second Esc restores the grid")
		sprite_untouched("after the 60-state filter")
		T.eq(app.sprite, sprite, "test sprite still active")
		next()
	end,
	-- Tab leaves the filter box and cycles through the shown states; the grid keeps the keyboard.
	function(next)
		drive({ { wait = 0.1 }, { key = "Ctrl+F" }, { wait = 0.15 }, { text = "door" }, { wait = 0.15 }, { key = "Tab" } },
			function() return editor.filter_query == "door" and not editor.filter_editing end, next)
	end,
	function(next)
		T.ok(not editor.filter_editing, "Tab left the filter box")
		T.eq(editor.filter_query, "door", "Tab keeps the filter")
		T.eq(cursor_name(), "door", "Tab picked the first match")
		drive({ { key = "Tab" }, { wait = 0.15 }, { key = "Tab" }, { wait = 0.15 }, { key = "Shift+Tab" } },
			function() return cursor_name() == "door_broken" end, next)
	end,
	function(next)
		T.eq(cursor_name(), "door_broken", "Tab, Tab, Shift+Tab: next, next, back")
		drive({ { key = "Right" } }, function() return cursor_name() == "door_open" end, next)
	end,
	function(next)
		T.eq(cursor_name(), "door_open", "arrows still move after Tab")
		T.eq(editor.filter_query, "door", "arrows keep the filter")
		T.eq(app.sprite, sprite, "Tab never took the keyboard off the grid")
		sprite_untouched("after Tab")
		drive({ { key = "Escape" }, { wait = 0.1 }, { key = "Escape" } }, function() return #editor:visible_states() == 60 end, next)
	end,
	function(next)
		T.eq(#editor:visible_states(), 60, "Esc, Esc clears the filter")
		next()
	end,
	-- Clearing the filter (and any refocus of the grid) keeps a window the user resized.
	function(next)
		local b = dialog.bounds
		dialog.bounds = Rectangle(b.x, b.y, b.width + 80, b.height + 60)
		T.after(0.5, function() next(dialog.bounds) end)
	end,
	function(next, resized)
		T.input({ focus_canvas(), { wait = 0.1 }, { key = "Ctrl+F" }, { wait = 0.15 }, { text = "do" }, { wait = 0.1 },
			{ key = "Escape" }, { wait = 0.4 } }, function() next(resized) end)
	end,
	function(next, resized)
		T.eq(dialog.bounds, resized, "the filter keeps the editor window size")
		next()
	end,
	-- Space opens the state under the cursor, like Enter.
	function(next)
		editor:select_index(1)
		local before = #editor.open_sprites
		drive({ focus_canvas(), { wait = 0.1 }, { key = "Space" } },
			function() return #editor.open_sprites == before + 1 end, function() next(before) end)
	end,
	function(next, before)
		T.eq(#editor.open_sprites, before + 1, "Space opened a state sprite")
		T.eq(editor.open_sprites[#editor.open_sprites].state, editor.dmi.states[1], "it is the state under the cursor")
		next()
	end,
	function()
		editor:close(false, true)
		sprite:close()
		T.done()
	end,
}
