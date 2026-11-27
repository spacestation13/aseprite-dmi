--- Batch smoke test: libdmi + the extension's Lua helpers, end to end.
--- py tools/aseprite_runner.py tools/tests/smoke_editor.lua

--- Calls a libdmi function, which returns (value, error) instead of raising.
local function call(name, ...)
	local value, err = libdmi[name](...)
	T.ok(err == nil, "libdmi." .. name .. " failed: " .. tostring(err))
	return value
end

--- Every frame image of every state (dirs * frame_count each), via the extension's loader.
local function frames(dmi)
	local images = {}
	for _, state in ipairs(dmi.states) do
		for index = 0, state.dirs * state.frame_count - 1 do
			local path = app.fs.joinPath(dmi.temp, state.frame_key .. "." .. index .. ".bytes")
			local image = load_image_bytes(path)
			T.ok(image, "missing frame " .. path)
			images[#images + 1] = image
		end
	end
	return images
end

local function state_meta(state)
	return {
		name = state.name,
		dirs = state.dirs,
		frame_count = state.frame_count,
		delays = state.delays,
		loop = state.loop,
		rewind = state.rewind,
		movement = state.movement,
		hotspots = state.hotspots,
	}
end

T.ok(libdmi, "libdmi loaded")
T.ok(Editor and RawDmi and Preferences, "extension classes loaded")
T.ok(app.fs.isDirectory(TEMP_DIR), "TEMP_DIR created: " .. TEMP_DIR)

-- New file
local new_dmi = call("new_file", "fresh", 32, 48, TEMP_DIR)
T.eq(new_dmi.name, "fresh", "new file name")
T.eq({ new_dmi.width, new_dmi.height }, { 32, 48 }, "new file size")
T.eq(#new_dmi.states, 0, "new file has no states")
local blank = call("new_state", 32, 48, new_dmi.temp, "blank")
T.eq(blank.name, "blank", "new state name")
T.eq({ blank.dirs, blank.frame_count }, { 1, 1 }, "new state dirs/frames")
new_dmi.states[1] = blank
local new_path = app.fs.joinPath(T.tmp, "fresh.dmi")
call("save_file", new_dmi, new_path)
local fresh = call("open_file", new_path, TEMP_DIR)
T.eq(#fresh.states, 1, "saved new file reopens with its state")
T.eq(state_meta(fresh.states[1]).name, "blank", "reopened state name")

-- Open the sample
local source = T.path("lib", "tests", "assets", "anomaly.dmi")
local dmi = call("open_file", source, TEMP_DIR)
T.eq(dmi.name, "anomaly", "dmi name")
T.eq({ dmi.width, dmi.height }, { 32, 32 }, "dmi size")
T.eq(#dmi.states, 9, "state count")
local names = {}
for i, state in ipairs(dmi.states) do names[i] = state.name end
T.detail("states", names)
T.eq(state_meta(dmi.states[1]), {
	name = "carp_rift",
	dirs = 1,
	frame_count = 3,
	delays = { 2, 2, 2 },
	loop = 0,
	rewind = false,
	movement = false,
	hotspots = {},
}, "first state metadata")
local original = frames(dmi)
T.ok(#original >= 9, "frames loaded")
for _, image in ipairs(original) do
	T.eq({ image.width, image.height }, { 32, 32 }, "frame size")
end

-- Round trip: save, reopen, compare metadata and every pixel
local saved_path = app.fs.joinPath(T.tmp, "roundtrip.dmi")
call("save_file", dmi, saved_path)
T.ok(app.fs.isFile(saved_path), "saved file exists")
local reopened = call("open_file", saved_path, TEMP_DIR)
T.eq({ reopened.width, reopened.height }, { dmi.width, dmi.height }, "round-trip size")
T.eq(#reopened.states, #dmi.states, "round-trip state count")
for i, state in ipairs(dmi.states) do
	T.eq(state_meta(reopened.states[i]), state_meta(state), "round-trip state " .. i)
end
local round_tripped = frames(reopened)
T.eq(#round_tripped, #original, "round-trip frame count")
for i = 1, #original do
	T.pixels_equal(round_tripped[i], original[i], "round-trip frame " .. i)
end
T.detail("frames", #original)
