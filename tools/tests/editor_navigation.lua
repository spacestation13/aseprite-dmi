--- Batch: pure grid-navigation / find logic of the DMI Editor (issues #29, #30).
local M = EditorNav

-- 10 states, 4 per row, 2 visible rows:  1 2 3 4 / 5 6 7 8 / 9 10
T.eq(M.move(nil, 10, 4, 2, "ArrowRight"), 1, "first key selects first")
T.eq(M.move(1, 10, 4, 2, "ArrowLeft"), 1, "left clamps")
T.eq(M.move(4, 10, 4, 2, "ArrowRight"), 5, "right wraps to next row")
T.eq(M.move(2, 10, 4, 2, "ArrowDown"), 6, "down one row")
T.eq(M.move(6, 10, 4, 2, "ArrowDown"), 10, "down onto short last row")
T.eq(M.move(7, 10, 4, 2, "ArrowDown"), 10, "down past short last row clamps")
T.eq(M.move(10, 10, 4, 2, "ArrowDown"), 10, "down on last row stays")
T.eq(M.move(3, 10, 4, 2, "ArrowUp"), 3, "up on first row stays")
T.eq(M.move(7, 10, 4, 2, "ArrowUp"), 3, "up one row")
T.eq(M.move(5, 10, 4, 2, "Home"), 1, "home")
T.eq(M.move(5, 10, 4, 2, "End"), 10, "end")
T.eq(M.move(1, 10, 4, 2, "PageDown"), 9, "page down")
T.eq(M.move(2, 10, 4, 2, "PageDown"), 10, "page down clamps")
T.eq(M.move(1, 10, 4, 2, "KeyA"), nil, "non-nav key")
T.eq(M.move(1, 0, 4, 2, "Home"), nil, "empty")

T.eq(M.max_scroll(10, 4, 2), 1, "11 cells / 4 = 3 rows, 2 visible")
T.eq(M.max_scroll(6, 4, 2), 0, "fits")
T.eq(M.scroll_to_show(10, 0, 4, 2, 1), 1, "scroll down to show")
T.eq(M.scroll_to_show(1, 1, 4, 2, 1), 0, "scroll up to show")
T.eq(M.scroll_to_show(6, 1, 4, 2, 1), 1, "already visible")

local names = { "idle", "Tesla", "move", "tesla_charge", "hot", "teleport" }
T.eq(M.find_next(names, "t", 0), 2, "prefix, case-insensitive")
T.eq(M.find_next(names, "t", 2), 4, "next prefix")
T.eq(M.find_next(names, "t", 6), 2, "wraps")
T.eq(M.find_next(names, "ot", 0), 5, "contains fallback")
T.eq(M.find_next(names, "zz", 0), nil, "no match")
T.eq(M.find_next(names, "%.", 0), nil, "plain match, no patterns")
T.eq(M.find_all(names, "TES"), { 2, 4 }, "find all")
T.eq(M.find_all(names, ""), {}, "empty query")

local buf, i = M.typeahead("", "t", names, nil)
T.eq({ buf, i }, { "t", 2 }, "first char")
buf, i = M.typeahead(buf, "t", names, i)
T.eq({ buf, i }, { "tt", 4 }, "repeat char cycles")
buf, i = M.typeahead(buf, "t", names, i)
T.eq({ buf, i }, { "ttt", 6 }, "repeat char cycles again")
buf, i = M.typeahead("", "t", names, nil)
buf, i = M.typeahead(buf, "e", names, i)
T.eq({ buf, i }, { "te", 2 }, "growing word keeps current match")
buf, i = M.typeahead(buf, "l", names, i)
T.eq({ buf, i }, { "tel", 6 }, "growing word moves on")
-- After a pause the editor's timer empties the buffer: a new word starts.
buf, i = M.typeahead("", "m", names, i)
T.eq({ buf, i }, { "m", 3 }, "new word after reset")

T.eq(M.edit_query("ab", "KeyC", "c"), "abc", "find: type")
T.eq(M.edit_query("abc", "Backspace", "\b"), "ab", "find: backspace")
T.eq(M.edit_query("", "Backspace", "\b"), "", "find: backspace on empty")
T.eq(M.edit_query("abc", "Delete", ""), "", "find: delete clears")
T.eq(M.edit_query("abc", "ArrowLeft", ""), nil, "find: non-text key")

buf, i = M.typeahead_backspace("bhx", { "anom", "bhole2", "bhole3" }, 2)
T.eq({ buf, i }, { "bh", 2 }, "backspace keeps a still-matching state")
buf, i = M.typeahead_backspace("b", { "anom", "bhole2" }, 2)
T.eq({ buf, i }, { "", nil }, "backspace to empty keeps the selection")
T.eq({ M.typeahead_backspace("", {}, nil) }, { "" }, "backspace on empty buffer")

local function k(code, mods)
	local ev = { code = code }
	for _, m in ipairs(mods or {}) do ev[m .. "Key"] = true end
	return M.key_passes_through(ev)
end
T.eq(k("Backspace"), false, "Backspace stays on the grid")
T.eq(k("Comma"), false, "plain keys stay on the grid")
T.eq(k("Space"), false, "Space stays on the grid")
T.eq(k("Equal", { "shift" }), false, "Shift combos stay on the grid")
T.eq(k("KeyS", { "ctrl" }), true, "Ctrl+S reaches Aseprite")
T.eq(k("KeyQ", { "ctrl" }), true, "Ctrl+Q reaches Aseprite")
T.eq(k("KeyF", { "alt" }), true, "Alt+F (menu) reaches Aseprite")
for _, code in ipairs({ "KeyZ", "KeyY", "KeyX", "KeyD", "Delete", "Backspace", "KeyC", "KeyV", "KeyA", "KeyF" }) do
	T.eq(k(code, { "ctrl" }), false, "Ctrl+" .. code .. " stays on the grid")
	T.eq(k(code, { "meta" }), false, "Cmd+" .. code .. " stays on the grid")
end
T.eq(k("KeyZ", { "ctrl", "shift" }), false, "Ctrl+Shift+Z stays on the grid")

local area = { x = 0, y = 0, width = 1000, height = 600 }
T.eq({ M.place_beside({ x = 100, y = 50, width = 300, height = 400 }, { width = 200, height = 100 }, area) }, { 400, 50 },
	"right of the editor")
T.eq({ M.place_beside({ x = 700, y = 50, width = 300, height = 400 }, { width = 200, height = 100 }, area) }, { 500, 50 },
	"left of the editor at the right edge")
T.eq({ M.place_beside({ x = 0, y = 550, width = 900, height = 400 }, { width = 200, height = 100 }, area) }, { 700, 500 },
	"overlapping when neither side fits, clamped")
T.eq({ M.place_beside({ x = 100, y = 50, width = 300, height = 400 }, { width = 2000, height = 100 }, area) }, { 0, 50 },
	"wider than the area: left edge")
