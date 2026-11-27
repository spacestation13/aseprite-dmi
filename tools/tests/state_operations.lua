--- Batch: duplicate, split, combine and state saves through the editor's own methods.
--- Dialog() is nil in batch, so the combine dialog is skipped: performCombineStates is what
--- its OK button calls.
--- py tools/aseprite_runner.py tools/tests/state_operations.lua

--- Calls a libdmi function, which returns (value, error) instead of raising.
local function call(name, ...)
	local value, err = libdmi[name](...)
	T.ok(err == nil, "libdmi." .. name .. " failed: " .. tostring(err))
	return value
end

local dmi = call("open_file", T.path("lib", "tests", "assets", "anomaly.dmi"), TEMP_DIR)

--- The editor without its dialog: the real methods, with repaints stubbed.
local editor = setmetatable({
	title = DIALOG_NAME,
	dmi = dmi,
	open_sprites = {},
	selected_states = {},
	image_cache = ImageCache.new(),
	modified = false,
}, { __index = Editor })
function editor:repaint_states() end

local function find(name)
	for _, state in ipairs(dmi.states) do
		if state.name == name then return state end
	end
end

local function count(name)
	local n = 0
	for _, state in ipairs(dmi.states) do
		if state.name == name then n = n + 1 end
	end
	return n
end

--- Every frame image of a state (index = frame * dirs + dir), via the extension's loader.
local function frames(state)
	local images = {}
	for index = 0, state.dirs * state.frame_count - 1 do
		local path = app.fs.joinPath(dmi.temp, state.frame_key .. "." .. index .. ".bytes")
		images[#images + 1] = T.ok(load_image_bytes(path), "missing frame " .. path)
	end
	return images
end

local function same_frames(actual, expected, what)
	T.eq(#actual, #expected, what .. " frame count")
	for i = 1, #expected do
		T.pixels_equal(actual[i], expected[i], what .. " frame " .. i)
	end
end

local function layout(state)
	return { dirs = state.dirs, frame_count = state.frame_count, delays = state.delays }
end

local carp = find("carp_rift")
local anom = find("anom")
local immrod = find("immrod")
local carp_frames = frames(carp)
local anom_frames = frames(anom)
local immrod_frames = frames(immrod)
T.eq(layout(immrod), { dirs = 4, frame_count = 1, delays = {} }, "immrod layout")

-- Duplicate: each copy goes right after its source.
editor:duplicate_states({ immrod, carp })
T.eq(#dmi.states, 11, "states after duplicating")
local carp_copy = dmi.states[2]
T.eq(carp_copy.name, "carp_rift", "copy follows its source")
T.neq(carp_copy.frame_key, carp.frame_key, "copy has its own frames")
T.eq(layout(carp_copy), layout(carp), "copy layout")
same_frames(frames(carp_copy), carp_frames, "carp copy")
T.ok(editor.image_cache:get(carp_copy.frame_key), "copy preview cached")
T.eq(count("immrod"), 2, "immrod duplicated")
T.ok(editor.modified, "duplicate marks the file modified")

-- Split: one state per direction, the source removed.
editor:split_state(immrod)
T.eq(count("immrod"), 1, "split removes its source")
local parts = {}
for i, suffix in ipairs({ "S", "N", "E", "W" }) do
	local part = T.ok(find("immrod - " .. suffix), "split state " .. suffix)
	T.eq(layout(part), { dirs = 1, frame_count = 1, delays = {} }, "split layout " .. suffix)
	same_frames(frames(part), { immrod_frames[i] }, "split " .. suffix)
	parts[i] = part
end

-- Combine directions first: the four parts make the original state again.
editor.selected_states = { parts[3], parts[1], parts[4], parts[2] }
editor:performCombineStates("immrod again", COMBINE_TYPES.dirs4_frames, FRAME_SEL_TYPES.all_seq)
local again = T.ok(find("immrod again"), "directions-first state")
T.eq(layout(again), { dirs = 4, frame_count = 1, delays = { 1 } }, "directions-first layout")
same_frames(frames(again), immrod_frames, "directions-first")
T.eq(#editor.selected_states, 0, "combine clears the selection")

-- Combine to one direction: every frame of each state, in DMI order.
editor.selected_states = { anom, carp }
editor:performCombineStates("one dir", COMBINE_TYPES.onedir, FRAME_SEL_TYPES.all_seq)
local one_dir = T.ok(find("one dir"), "one-direction state")
T.eq(layout(one_dir), { dirs = 1, frame_count = 11, delays = { 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1 } },
	"one-direction layout")
local expected = {}
for _, image in ipairs(carp_frames) do expected[#expected + 1] = image end
for _, image in ipairs(anom_frames) do expected[#expected + 1] = image end
same_frames(frames(one_dir), expected, "one-direction")

-- Combine frames first, 4 directions, first frames only: a 1-direction state repeats south.
editor.selected_states = { carp, again }
editor:performCombineStates("frames first", COMBINE_TYPES.frames_4dir, FRAME_SEL_TYPES.first_only)
local frames_first = T.ok(find("frames first"), "frames-first state")
T.eq(layout(frames_first), { dirs = 4, frame_count = 2, delays = { 2, 1 } }, "frames-first layout")
same_frames(frames(frames_first), {
	carp_frames[1], carp_frames[1], carp_frames[1], carp_frames[1],
	immrod_frames[1], immrod_frames[2], immrod_frames[3], immrod_frames[4],
}, "frames-first")

-- Saving an open state writes its frames back through libdmi.save_frame_bytes.
editor:open_state(carp_copy)
local state_sprite = T.ok(editor.open_sprites[#editor.open_sprites], "state sprite opened")
local sprite = state_sprite.sprite
local cel = T.ok(sprite.layers[#sprite.layers]:cel(2), "second frame cel")
local edited = Image(cel.image)
edited:drawPixel(0, 0, app.pixelColor.rgba(255, 0, 255, 255))
edited:drawPixel(1, 1, app.pixelColor.rgba(200, 100, 50, 1))
cel.image = edited
T.ok(state_sprite:save(), "state save")
local saved = frames(carp_copy)
T.eq(saved[2]:getPixel(0, 0), app.pixelColor.rgba(255, 0, 255, 255), "edited pixel saved")
T.eq(saved[2]:getPixel(1, 1), app.pixelColor.rgba(200, 100, 50, 1), "alpha 1 pixel in frame cache")
T.pixels_equal(saved[1], carp_frames[1], "unedited frame kept")
sprite:close()

-- Everything above saves and reopens as a valid DMI.
local saved_path = app.fs.joinPath(T.tmp, "operations.dmi")
call("save_file", dmi, saved_path)
local reopened = call("open_file", saved_path, TEMP_DIR)
T.eq(#reopened.states, #dmi.states, "reopened state count")
for i, state in ipairs(dmi.states) do
	T.eq({ reopened.states[i].name, layout(reopened.states[i]) }, { state.name, layout(state) },
		"reopened state " .. i)
end
T.detail("states", #dmi.states)

-- Alpha 1 pixels keep their color unless the preference asks for black.
local alpha_1 = app.pixelColor.rgba(200, 100, 50, 1)
-- The carp copy shares its name with the original, so find it by position.
local carp_copy_index = table.index_of(dmi.states, carp_copy)
T.neq(carp_copy_index, 0, "carp copy position")
local function saved_pixel(path)
	local copy = call("open_file", path, TEMP_DIR)
	local state = copy.states[carp_copy_index]
	T.eq(state.name, carp_copy.name, "carp copy after save")
	local file = app.fs.joinPath(copy.temp, state.frame_key .. ".1.bytes")
	return T.ok(load_image_bytes(file), "reopened frame"):getPixel(1, 1)
end
T.eq(saved_pixel(saved_path), alpha_1, "alpha 1 pixel color kept by default")

Preferences.plugin.preferences.black_near_transparent = true
local black_path = app.fs.joinPath(T.tmp, "black_alpha_1.dmi")
T.ok(editor:write_to(black_path), "save with black near-transparent pixels")
Preferences.plugin.preferences.black_near_transparent = false
T.eq(saved_pixel(black_path), app.pixelColor.rgba(0, 0, 0, 1), "alpha 1 pixel saved as black")
