--- Keyboard navigation and find for the DMI Editor state grid (issues #29, #30).
--- EditorNav holds the pure index math (testable in batch); the Editor methods below
--- apply it to the editor's selection and scroll.

--- @class EditorNav
EditorNav = {}

--- Seconds of inactivity after which the type-ahead buffer starts over.
EditorNav.TYPEAHEAD_TIMEOUT = 1

--- Grid movement for a navigation key.
--- @param index number|nil Current 1-based index (nil: nothing selected yet).
--- @param count number Number of states.
--- @param columns number States per row.
--- @param rows number Fully visible rows (page size for PageUp/PageDown).
--- @param code string KeyEvent code (ArrowLeft, ArrowRight, ArrowUp, ArrowDown, Home, End, PageUp, PageDown).
--- @param first number|nil Index picked by the first arrow/page key with nothing selected (default 1).
--- @return number|nil index The new index, or nil if `code` is not a navigation key or there are no states.
function EditorNav.move(index, count, columns, rows, code, first)
	if count < 1 then return nil end
	columns = math.max(columns, 1)
	rows = math.max(rows, 1)
	local delta
	if code == "ArrowLeft" then
		delta = -1
	elseif code == "ArrowRight" then
		delta = 1
	elseif code == "ArrowUp" then
		delta = -columns
	elseif code == "ArrowDown" then
		delta = columns
	elseif code == "PageUp" then
		delta = -columns * rows
	elseif code == "PageDown" then
		delta = columns * rows
	elseif code == "Home" then
		return 1
	elseif code == "End" then
		return count
	else
		return nil
	end
	-- First key press with nothing selected picks `first`, by default the first state.
	if not index then return first or 1 end
	local target = index + delta
	if code == "ArrowUp" or code == "ArrowDown" then
		-- Stay in place when the row above/below doesn't exist; a shorter last row clamps.
		if target < 1 then return index end
		if target > count then
			local last_row_start = count - (count - 1) % columns
			return index >= last_row_start and index or count
		end
		return target
	end
	return math.min(math.max(target, 1), count)
end

--- Next (or, backwards, previous) slot for Tab, wrapping around the ends.
--- @param index number|nil Current slot, nil if nothing is selected.
--- @param count number
--- @param backwards boolean|nil
--- @param first number|nil Slot picked with nothing selected going forwards (default 1); backwards picks the last.
--- @return number|nil index nil if there are no states.
function EditorNav.cycle(index, count, backwards, first)
	if count < 1 then return nil end
	if not index then return backwards and count or first or 1 end
	if backwards then return index > 1 and index - 1 or count end
	return index < count and index + 1 or 1
end

--- Highest scroll value (in rows) for a grid of `count` states plus the "+" cell.
--- @return number
function EditorNav.max_scroll(count, columns, rows)
	columns = math.max(columns, 1)
	local total_rows = math.ceil((count + 1) / columns)
	return math.max(total_rows - math.max(rows, 1), 0)
end

--- Scroll (in rows) that keeps `index` visible, changing `scroll` as little as possible.
--- @return number
function EditorNav.scroll_to_show(index, scroll, columns, rows, max_scroll)
	columns = math.max(columns, 1)
	rows = math.max(rows, 1)
	local row = math.floor((index - 1) / columns)
	if row < scroll then
		scroll = row
	elseif row >= scroll + rows then
		scroll = row - rows + 1
	end
	return math.min(math.max(scroll, 0), max_scroll or math.huge)
end

--- Next state name matching `query`, searching forward from after `from` and wrapping.
--- Names starting with the query win over names only containing it. Case-insensitive.
--- @param names string[]
--- @param query string
--- @param from number|nil Index to search after (nil/0: from the start).
--- @return number|nil
function EditorNav.find_next(names, query, from)
	local count = #names
	if count == 0 or query == "" then return nil end
	query = query:lower()
	from = from or 0
	for pass = 1, 2 do
		for offset = 1, count do
			local i = (from + offset - 1) % count + 1
			local start = names[i]:lower():find(query, 1, true)
			if start and (pass == 2 or start == 1) then
				return i
			end
		end
	end
	return nil
end

--- The grid's slots: the states whose name contains `query` (case-insensitive) or that are in
--- `keep`, in DMI order. An empty query shows every state (`states` itself, not a copy).
--- @param states State[]
--- @param query string
--- @param keep table<State, true>|nil States shown whatever their name.
--- @return State[]
function EditorNav.filter(states, query, keep)
	if query == "" then return states end
	query = query:lower()
	local visible = {}
	for _, state in ipairs(states) do
		if (keep and keep[state]) or state.name:lower():find(query, 1, true) then
			visible[#visible + 1] = state
		end
	end
	return visible
end

--- Type-ahead step: appends `char` to the buffer and finds the match.
--- The caller empties the buffer once the user pauses for EditorNav.TYPEAHEAD_TIMEOUT.
--- Repeating one character ("t", "t", "t") cycles through the states starting with it.
--- @param buffer string Current buffer ("" after a pause).
--- @param char string Typed character.
--- @param names string[] State names.
--- @param current number|nil Currently selected index.
--- @return string buffer New buffer.
--- @return number|nil index Matching index.
function EditorNav.typeahead(buffer, char, names, current)
	buffer = buffer .. char
	current = current or 0
	local lower = buffer:lower()
	if lower == string.rep(lower:sub(1, 1), #lower) then
		-- Same key repeated: jump to the next state starting with it.
		return buffer, EditorNav.find_next(names, lower:sub(1, 1), current)
	end
	-- Growing a word: the current state stays if it still matches.
	return buffer, EditorNav.find_next(names, lower, current > 0 and current - 1 or 0)
end

--- Type-ahead Backspace: drops the last typed character and finds the shortened text again
--- (the current state stays if it still matches).
--- @return string buffer
--- @return number|nil index Matching index (nil: keep the selection).
function EditorNav.typeahead_backspace(buffer, names, current)
	buffer = buffer:sub(1, -2)
	if buffer == "" then return buffer, nil end
	current = current or 0
	return buffer, EditorNav.find_next(names, buffer:lower(), current > 0 and current - 1 or 0)
end

--- Ctrl/Cmd combos the grid keeps from Aseprite even when it doesn't use them itself: they would
--- act on the active sprite, which the user isn't looking at while working in the grid
--- (undo/redo, cut, deselect, clear). Ctrl+A/C/V/F are the grid's own (select all, copy/paste states, find).
EditorNav.GRID_CTRL_KEYS = {
	KeyZ = true, KeyY = true, KeyX = true, KeyD = true, Delete = true, Backspace = true,
	KeyA = true, KeyC = true, KeyV = true, KeyF = true, KeyS = true,
	-- Arrows, Home/End and Page keys with Ctrl would scroll or move the active sprite's view.
	ArrowLeft = true, ArrowRight = true, ArrowUp = true, ArrowDown = true,
	Home = true, End = true, PageUp = true, PageDown = true,
}

--- Whether a key pressed on the focused grid goes on to Aseprite's shortcuts.
--- Keys without Ctrl/Alt/Cmd never do (Backspace = Clear, `,` = previous frame, Space = hand...);
--- Ctrl/Alt/Cmd combos do (Ctrl+S, Ctrl+Q, Alt+menus...) except EditorNav.GRID_CTRL_KEYS.
--- @param ev table KeyEvent-like: code, ctrlKey, altKey, metaKey.
--- @return boolean
function EditorNav.key_passes_through(ev)
	if not (ev.ctrlKey or ev.altKey or ev.metaKey) then return false end
	if (ev.ctrlKey or ev.metaKey) and EditorNav.GRID_CTRL_KEYS[ev.code] then return false end
	return true
end

--- The states in the grid's slots (slot i is drawn at box_bounds(i)): every state, or only the Find
--- filter's matches. Layout, scrolling and keyboard navigation index this, never `dmi.states`.
--- @return State[]
function Editor:visible_states()
	return EditorNav.filter(self.dmi.states, self.filter_query, self.filter_keep)
end

--- Names of the visible states, by slot.
--- @return string[]
function Editor:state_names()
	local names = {}
	for i, state in ipairs(self:visible_states()) do
		names[i] = state.name
	end
	return names
end

--- Slot of the keyboard cursor: the last selected state.
--- @return number|nil
function Editor:cursor_index()
	local state = self.selected_states[#self.selected_states]
	local index = state and table.index_of(self:visible_states(), state) or 0
	return index > 0 and index or nil
end

--- Moves the cursor to slot `index`, selecting it alone (or extending from the anchor), and scrolls it into view.
--- @param index number
--- @param extend boolean|nil Select the range from the anchor to `index`.
function Editor:select_index(index, extend)
	local states = self:visible_states()
	local state = states[index]
	if not state then return end
	local anchor = extend and self.nav_anchor and table.index_of(states, self.nav_anchor) or 0
	self.selected_states = {}
	if anchor > 0 then
		local step = index >= anchor and 1 or -1
		for i = anchor, index, step do
			table.insert(self.selected_states, states[i])
		end
	else
		self.nav_anchor = state
		self.selected_states = { state }
	end
	self:scroll_into_view(index)
end

--- @param index number Slot.
function Editor:scroll_into_view(index)
	local max_scroll = EditorNav.max_scroll(#self:visible_states(), self.max_in_a_row, self.max_in_a_column)
	local scroll = EditorNav.scroll_to_show(index, self.scroll, self.max_in_a_row, self.max_in_a_column, max_scroll)
	if scroll ~= self.scroll then
		self.scroll = scroll
		self:repaint_states()
	else
		self:repaint()
	end
end

--- Filters the grid to the states whose name contains `query` (case-insensitive; "" shows them all).
--- The selection keeps only the states still shown, so actions on it never touch hidden states,
--- and the cursor stays in view. Updates the title ("12 of 143 states") and the filter bar.
--- @param query string
function Editor:set_filter(query)
	if query == self.filter_query then return end
	self.filter_query = query
	self.filter_keep = {}
	if not self.dmi or self.closed then return end
	local visible = self:visible_states()
	local shown = {}
	for _, state in ipairs(visible) do shown[state] = true end
	local selected = {}
	for _, state in ipairs(self.selected_states) do
		if shown[state] then table.insert(selected, state) end
	end
	self.selected_states = selected
	if self.nav_anchor and not shown[self.nav_anchor] then self.nav_anchor = nil end
	local cursor = self:cursor_index()
	self.scroll = cursor and EditorNav.scroll_to_show(cursor, self.scroll, self.max_in_a_row, self.max_in_a_column,
		EditorNav.max_scroll(#visible, self.max_in_a_row, self.max_in_a_column)) or 0
	self:repaint_states()
end

--- Keeps a state just created or renamed in the filtered grid, whatever its name, until the query changes.
--- @param state State
function Editor:keep_visible(state)
	if self.filter_query ~= "" then self.filter_keep[state] = true end
end

--- Text editing of the filter bar: the new query for a key, or nil if the key doesn't edit text.
--- @param query string
--- @param code string KeyEvent code.
--- @param char string|nil KeyEvent key (typed character).
--- @return string|nil
function EditorNav.edit_query(query, code, char)
	if code == "Backspace" then
		return query:sub(1, -2)
	elseif code == "Delete" then
		return ""
	elseif char and #char == 1 and char:byte() >= 32 and char:byte() < 127 then
		return query .. char
	end
	return nil
end

--- Whether the filter bar, a strip under the window title, is shown: while typing a filter or
--- while one is on. The grid is laid out below it (see Editor:filter_bar_height).
--- @return boolean
function Editor:filter_bar_visible()
	return self.filter_editing or self.filter_query ~= ""
end

--- Starts typing a filter (Ctrl+F, `/` or the context menu; clicking the bar while it shows resumes
--- typing): the bar drops down from the title and the grid shows only the states whose name contains
--- what is typed (see Editor:set_filter). Typing is on the grid itself, so Esc, Enter, Tab and Backspace
--- never reach Aseprite. Enter stops typing and keeps the filter with the cursor on the first match;
--- Tab stops typing and moves on to the next match; Esc or the bar's x clears it. Ctrl+F or `/` again
--- continues with the current text.
function Editor:start_filter()
	if self.filter_editing or not self.dmi then return end
	local was_visible = self:filter_bar_visible()
	self.filter_editing = true
	self:reset_typeahead()
	if was_visible then self:repaint() else self:repaint_states() end
end

--- Stops typing, keeping the filter on if there is text.
function Editor:stop_filter_editing()
	if not self.filter_editing then return end
	local was_visible = self:filter_bar_visible()
	self.filter_editing = false
	if was_visible ~= self:filter_bar_visible() then self:repaint_states() else self:repaint() end
end

--- Clears the filter and hides the bar.
function Editor:clear_filter()
	local was_visible = self:filter_bar_visible()
	self.filter_editing = false
	if self.filter_query ~= "" then
		self:set_filter("")
	elseif was_visible then
		self:repaint_states()
	end
end

--- Keys while typing in the filter bar. Returns true if the key was used; arrows, Page keys, Home/End
--- and the rest go on to the grid, so you can type a filter and move through the matches.
--- @param ev KeyEvent Without Ctrl/Alt/Cmd.
--- @return boolean
function Editor:handle_filter_key(ev)
	local code = ev.code
	if code == "Escape" then
		self:clear_filter()
	elseif code == "Enter" or code == "NumpadEnter" then
		-- No match: keep typing so the query can be fixed instead of leaving an empty grid.
		if self.filter_query ~= "" and #self:visible_states() == 0 then return true end
		-- Arrows and Enter on the grid go on from the first match.
		if self.filter_query ~= "" and #self.selected_states == 0 then self:select_index(1) end
		self:stop_filter_editing()
		self:refocus_grid()
	elseif code == "Backspace" and self.filter_query == "" then
		self:stop_filter_editing()
	else
		local query = EditorNav.edit_query(self.filter_query, code, ev.key)
		if not query then return false end
		self:set_filter(query)
	end
	return true
end

--- Handles grid navigation keys. Returns true if the key was used.
--- @param ev KeyEvent
--- @return boolean handled
function Editor:handle_navigation_key(ev)
	local modified = ev.ctrlKey or ev.altKey or ev.metaKey
	local code = ev.code

	-- Open context menu: Esc closes it, nothing else gets past it.
	if self.context_widget then
		if code == "Escape" then
			self.context_widget = nil
			self:repaint()
		end
		return true
	end
	if not self.dmi or self.loading then
		return not EditorNav.key_passes_through(ev)
	end

	-- Typing a filter: its keys come before everything else so `/` and Space are characters.
	if self.filter_editing and not modified and self:handle_filter_key(ev) then return true end
	if ((ev.ctrlKey or ev.metaKey) and code == "KeyF") or (ev.key == "/" and not modified) then
		self:start_filter()
		return true
	end
	if (ev.ctrlKey or ev.metaKey) and not ev.altKey then
		if code == "KeyA" then
			self.selected_states = {}
			for _, state in ipairs(self:visible_states()) do
				table.insert(self.selected_states, state)
			end
			self:repaint()
		elseif code == "KeyC" then
			self:clipboard_copy_selected_states() -- may alert ("Save all open sprites first")
			self:refocus_grid()
		elseif code == "KeyV" then
			self:clipboard_paste_state()
			self:refocus_grid()
		elseif code == "KeyS" then
			-- Ctrl+S / Ctrl+Shift+S save the DMI; left alone they would save the active sprite.
			if ev.shiftKey then self:save_as() else self:save() end
			self:refocus_grid()
		end
	end
	-- Ctrl/Alt/Cmd combos go on to Aseprite unless they are the grid's own (Ctrl+Tab switches sprite tabs).
	if modified then
		return not EditorNav.key_passes_through(ev)
	end

	-- Tab cycles through the shown states, Shift+Tab back, wrapping around; it also leaves the filter box.
	if code == "Tab" then
		self:stop_filter_editing()
		local count = #self:visible_states()
		local first_in_view = math.min(self.scroll * math.max(self.max_in_a_row, 1) + 1, math.max(count, 1))
		local index = EditorNav.cycle(self:cursor_index(), count, ev.shiftKey, first_in_view)
		if index then self:select_index(index) end
		return true
	end

	-- With nothing selected (after Esc, Delete or a click), the first arrow starts from what is in view
	-- instead of jumping back to the first state.
	local count = #self:visible_states()
	local first_in_view = math.min(self.scroll * math.max(self.max_in_a_row, 1) + 1, math.max(count, 1))
	local index = EditorNav.move(self:cursor_index(), count, self.max_in_a_row, self.max_in_a_column, code,
		first_in_view)
	if index then
		self:select_index(index, ev.shiftKey)
		return true
	end

	-- Space opens like Enter, so it is not a type-ahead character.
	if code == "Enter" or code == "NumpadEnter" or code == "Space" then
		local state = self:visible_states()[self:cursor_index() or 0]
		if state then self:open_state(state) end
	elseif code == "Delete" then
		local count = #self.selected_states
		if count == 0 then return true end
		local text = count == 1
			and ("Remove state \"" .. self.selected_states[1].name .. "\"?")
			or ("Remove " .. count .. " selected states?")
		if app.alert { title = self.title, text = text, buttons = { "&Remove", "&Cancel" } } == 1 then
			self:remove_selected_states()
		end
		self:refocus_grid()
	elseif code == "Escape" then
		-- Esc deselects; with nothing selected, it drops the filter.
		if #self.selected_states == 0 then
			self:clear_filter()
		end
		self.selected_states = {}
		self.nav_anchor = nil
		self:reset_typeahead()
		self:repaint()
	elseif code == "Backspace" then
		local buffer, found = EditorNav.typeahead_backspace(self.typeahead_buffer or "", self:state_names(),
			self:cursor_index())
		self.typeahead_buffer = buffer
		self:restart_typeahead_timer()
		if found then self:select_index(found) end
	else
		local char = ev.key
		if char and #char == 1 and char:match("[%w_%-%.]") then
			local buffer, found = EditorNav.typeahead(self.typeahead_buffer or "", char, self:state_names(), self:cursor_index())
			self.typeahead_buffer = buffer
			self:restart_typeahead_timer()
			if found then self:select_index(found) end
		end
	end
	-- Every key without Ctrl/Alt/Cmd is consumed (see EditorNav.key_passes_through).
	return true
end

function Editor:reset_typeahead()
	self.typeahead_buffer = ""
	if self.typeahead_timer then self.typeahead_timer:stop() end
end

--- Gives keyboard focus back to the grid. Call after a grid key action that may show an alert or
--- dialog: closing one hands focus to the sprite editor, so the next key would hit the active sprite.
--- Aseprite re-lays out a dialog when a widget is modified, which resets a window the user resized
--- to its default size, so the bounds are put back.
function Editor:refocus_grid()
	if self.dialog and not self.closed then
		local bounds = self.dialog.bounds
		self.dialog:modify { id = "canvas", focus = true }
		if self.dialog.bounds ~= bounds then self.dialog.bounds = bounds end
	end
end

--- (Re)starts the one-shot timer that empties the type-ahead buffer after a pause.
function Editor:restart_typeahead_timer()
	if not self.typeahead_timer then
		self.typeahead_timer = Timer {
			interval = EditorNav.TYPEAHEAD_TIMEOUT,
			ontick = function() self:reset_typeahead() end
		}
	end
	self.typeahead_timer:stop()
	self.typeahead_timer:start()
end
