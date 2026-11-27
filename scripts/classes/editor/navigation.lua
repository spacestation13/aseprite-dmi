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
--- @return number|nil index The new index, or nil if `code` is not a navigation key or there are no states.
function EditorNav.move(index, count, columns, rows, code)
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
	-- First key press with nothing selected picks the first state.
	if not index then return 1 end
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
	KeyA = true, KeyC = true, KeyV = true, KeyF = true,
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

--- Position for a `size` window next to `anchor` inside `area`: right of it, else left of it,
--- else overlapping it, always clamped into `area`.
--- @param anchor table {x, y, width, height}
--- @param size table {width, height}
--- @param area table {x, y, width, height}
--- @return number x
--- @return number y
function EditorNav.place_beside(anchor, size, area)
	local x
	if anchor.x + anchor.width + size.width <= area.x + area.width then
		x = anchor.x + anchor.width
	elseif anchor.x - size.width >= area.x then
		x = anchor.x - size.width
	else
		x = anchor.x + anchor.width - size.width
	end
	x = math.max(area.x, math.min(x, area.x + area.width - size.width))
	local y = math.max(area.y, math.min(anchor.y, area.y + area.height - size.height))
	return x, y
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
--- and the cursor stays in view. Updates the title ("12 of 143 states") and the Find box.
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
	if self.find_dialog then
		self.find_dialog:modify { id = "result", text = self:filter_status() }
		self.find_dialog:repaint()
	end
end

--- Keeps a state just created or renamed in the filtered grid, whatever its name, until the query changes.
--- @param state State
function Editor:keep_visible(state)
	if self.filter_query ~= "" then self.filter_keep[state] = true end
end

--- "12 of 143 states" while the grid is filtered, else "".
--- @return string
function Editor:filter_status()
	if not self.dmi or self.filter_query == "" then return "" end
	return #self:visible_states() .. " of " .. #self.dmi.states .. " states"
end

--- Find box text editing: the new query for a key, or nil if the key doesn't edit text.
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

--- Opens the non-modal Find States dialog (Ctrl+F or /), or focuses it if open: as you type, the grid
--- shows only the states whose name contains the text (see Editor:set_filter). Enter closes it and
--- keeps the filter, with the grid's cursor on the first match; Esc, Close or closing the window
--- clear the filter. Reopening it shows the current filter's text.
--- The text box is a canvas so Esc/Enter/Delete are handled here and never reach Aseprite's
--- shortcuts (an entry in a non-modal dialog lets Esc run Cancel, deselecting the active sprite).
function Editor:open_find_dialog()
	if self.find_dialog then
		self.find_dialog:modify { id = "query", focus = true }
		return
	end
	local dialog
	local keep_filter = false
	dialog = Dialog {
		title = "Find States",
		onclose = function()
			if self.find_dialog ~= dialog then return end
			self.find_dialog = nil
			if not keep_filter then self:set_filter("") end
		end
	}
	local function close(keep)
		keep_filter = keep
		dialog:close()
		self:refocus_grid()
	end
	dialog:canvas {
		id = "query",
		label = "Name contains",
		width = 120,
		height = 18,
		focus = true,
		onpaint = function(ev)
			local ctx = ev.context
			ctx:drawThemeRect("sunken_focused", Rectangle(0, 0, ctx.width, ctx.height))
			local text = self.filter_query .. "|"
			local size = ctx:measureText(text)
			ctx.color = app.theme.color.text
			ctx:fillText(text, 4, (ctx.height - size.height) / 2)
		end,
		onkeydown = function(ev)
			if ev.code == "Escape" then
				close(false)
			elseif ev.code == "Enter" or ev.code == "NumpadEnter" then
				-- Arrows and Enter on the grid go on from the first match.
				if self.filter_query ~= "" and #self.selected_states == 0 then self:select_index(1) end
				close(true)
			elseif not (ev.ctrlKey or ev.altKey or ev.metaKey) then
				local query = EditorNav.edit_query(self.filter_query, ev.code, ev.key)
				if query then self:set_filter(query) end
			end
			ev:stopPropagation()
		end
	}
	dialog:label { id = "result", text = self:filter_status() }
	dialog:button { text = "Clear", onclick = function()
		self:set_filter("")
		dialog:modify { id = "query", focus = true } -- keep typing in the box, not on the button
	end }
	dialog:button { text = "Close", onclick = function() close(false) end }
	self.find_dialog = dialog
	dialog:show { wait = false }
	-- Beside the editor (right, else left, else overlapping) so it doesn't cover the grid.
	local bounds = dialog.bounds
	local x, y = EditorNav.place_beside(self.dialog.bounds, bounds, app.window and
		Rectangle(0, 0, app.window.width, app.window.height) or self.dialog.bounds)
	dialog.bounds = Rectangle(x, y, bounds.width, bounds.height)
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

	if ((ev.ctrlKey or ev.metaKey) and code == "KeyF") or (ev.key == "/" and not modified) then
		self:open_find_dialog()
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
		end
	end
	if modified then
		return not EditorNav.key_passes_through(ev)
	end

	local index = EditorNav.move(self:cursor_index(), #self:visible_states(), self.max_in_a_row, self.max_in_a_column,
		code)
	if index then
		self:select_index(index, ev.shiftKey)
		return true
	end

	if code == "Enter" or code == "NumpadEnter" then
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
		-- Esc deselects; with nothing selected, it drops the Find filter.
		if #self.selected_states == 0 then
			self:set_filter("")
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
		if char and #char == 1 and char:match("[%w_%-%. ]") and not (char == " " and (self.typeahead_buffer or "") == "") then
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
function Editor:refocus_grid()
	if self.dialog and not self.closed then
		self.dialog:modify { id = "canvas", focus = true }
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
