--- GUI: keyboard navigation, type-ahead and Ctrl+F find in the DMI Editor (issues #29, #30).
--- Keys are fed to Editor:onkeydown as synthetic KeyEvents.
--- py tools/aseprite_runner.py tools/tests/editor_navigation_gui.lua --gui --screenshot out.png

T.async()

local path = T.path("lib", "tests", "assets", "anomaly.dmi")

local function key(editor, code, char, mods)
	local ev = { code = code, key = char or "", stopped = false }
	for k, v in pairs(mods or {}) do ev[k] = v end
	ev.stopPropagation = function() ev.stopped = true end
	editor:onkeydown(ev)
	return ev.stopped
end

local function selected_names(editor)
	local names = {}
	for _, s in ipairs(editor.selected_states) do table.insert(names, s.name) end
	return names
end

T.wait_until(function() return libdmi and open_editors end, function()
	app.command.OpenFile { filename = path }
	T.wait_until(function()
		local editor = open_editors[1]
		return editor and not editor.loading and editor.dmi and #editor.widgets > 0 and editor
	end, function(editor)
		local names = editor:state_names()
		T.detail("states", table.concat(names, ","))
		T.detail("grid", editor.max_in_a_row .. "x" .. editor.max_in_a_column)
		local cols = editor.max_in_a_row

		T.ok(key(editor, "ArrowRight"), "arrow handled")
		T.eq(editor:cursor_index(), 1, "first arrow selects first state")
		key(editor, "ArrowRight")
		T.eq(editor:cursor_index(), math.min(2, #names), "right")
		key(editor, "ArrowDown")
		T.eq(editor:cursor_index(), EditorNav.move(2, #names, cols, editor.max_in_a_column, "ArrowDown"), "down")
		key(editor, "End")
		T.eq(editor:cursor_index(), #names, "end")
		local first_row = math.floor((#names - 1) / cols)
		T.ok(editor.scroll <= first_row and first_row < editor.scroll + math.max(editor.max_in_a_column, 1),
			"last state scrolled into view")
		key(editor, "Home")
		T.eq(editor:cursor_index(), 1, "home")
		T.eq(editor.scroll, 0, "scrolled back to top")
		key(editor, "ArrowRight", nil, { shiftKey = true })
		key(editor, "ArrowRight", nil, { shiftKey = true })
		T.eq(#editor.selected_states, 3, "shift extends selection")
		T.ok(key(editor, "Escape"), "escape handled")
		T.eq(#editor.selected_states, 0, "escape clears")

		-- Type-ahead: first letter of the 3rd state.
		local target = names[3]
		key(editor, "Key" .. target:sub(1, 1):upper(), target:sub(1, 1))
		T.eq(editor:cursor_index(), EditorNav.find_next(names, target:sub(1, 1), 0), "type-ahead jumps")
		-- (F2 rename is unchanged; not pressed here because the properties dialog is modal.)
		T.after(0.3, function()
			-- Ctrl+F find
			key(editor, "KeyF", "f", { ctrlKey = true })
			T.ok(editor.find_dialog, "find dialog opened")
			local count = editor:find_states("a")
			T.eq(count, #EditorNav.find_all(names, "a"), "find selects matches")
			T.eq(#editor.selected_states, count, "matches selected")
			T.detail("selected", table.concat(selected_names(editor), ","))
			T.after(1, T.done)
		end)
	end, { what = "DMI Editor to open" })
end, { what = "plugin init" })
