--- Test harness entrypoint, launched by tools/aseprite_runner.py with --script.
--- Defines the global `T` API, loads the extension in batch mode (in GUI mode the
--- installed extension's init(plugin) has already run), runs the scenario and
--- writes the JSON result the runner waits for.

--- @diagnostic disable: lowercase-global

local P = app.params
local MODE = P.harness_mode

local result = {
	status = "running",
	ok = true,
	message = "",
	mode = MODE,
	scenario = P.harness_scenario,
	assertions = 0,
	details = {},
}

local FAIL = {} -- metatable marking assertion failures

local function is_sequence(t)
	local n = 0
	for k in pairs(t) do
		if math.type(k) ~= "integer" or k < 1 then return false end
		n = n + 1
	end
	return n == #t
end

--- JSON-encodable copy: json.encode rejects mixed/sparse keys, invalid UTF-8 and NaN.
local function plain(value, depth)
	depth = depth or 0
	local t = type(value)
	if t == "nil" or t == "boolean" then
		return value
	elseif t == "string" then
		if utf8.len(value) and not value:find("\0", 1, true) then return value end
		return (value:gsub("[%z\128-\255]", function(c) return string.format("\\x%02X", c:byte()) end))
	elseif t == "number" then
		return (value ~= value or value == math.huge or value == -math.huge) and tostring(value) or value
	elseif t == "table" and depth < 8 then
		local out = {}
		local array = is_sequence(value)
		for k, v in pairs(value) do
			out[array and k or tostring(k)] = plain(v, depth + 1)
		end
		return out
	end
	return tostring(value)
end

local function write_result()
	local ok, text = pcall(json.encode, plain(result))
	if not ok then
		text = json.encode({ status = result.status, ok = false, message = "result JSON encoding failed: " .. tostring(text) })
	end
	local file = assert(io.open(P.harness_result, "wb"))
	file:write(text)
	file:close()
end

local function describe(v)
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) ~= "table" then return tostring(v) end
	local ok, text = pcall(json.encode, plain(v))
	return ok and text or tostring(v)
end

local function deep_equal(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

T = { repo = P.harness_repo, tmp = P.harness_tmp }

function T.param(name, default)
	local v = P[name]
	if v == nil then return default end
	return v
end

function T.path(...)
	return app.fs.joinPath(T.repo, ...)
end

--- `level` as for error(): 1 = the caller of T.fail.
function T.fail(msg, level)
	level = (level or 1) + 1
	local info = debug.getinfo(level, "Sl")
	local where = info and info.currentline > 0 and (info.short_src .. ":" .. info.currentline .. ": ") or ""
	error(setmetatable({ msg = where .. tostring(msg or "failed") }, FAIL), level)
end

function T.ok(cond, msg)
	result.assertions = result.assertions + 1
	if not cond then T.fail(msg or "assertion failed", 2) end
	return cond
end

function T.eq(actual, expected, msg)
	result.assertions = result.assertions + 1
	if not deep_equal(actual, expected) then
		T.fail(string.format("%s: expected %s, got %s", msg or "values differ", describe(expected), describe(actual)), 2)
	end
end

function T.neq(actual, unexpected, msg)
	result.assertions = result.assertions + 1
	if deep_equal(actual, unexpected) then
		T.fail(string.format("%s: did not expect %s", msg or "values equal", describe(actual)), 2)
	end
end

function T.near(actual, expected, eps, msg)
	result.assertions = result.assertions + 1
	eps = eps or 1e-6
	if type(actual) ~= "number" or math.abs(actual - expected) > eps then
		T.fail(string.format("%s: expected %s +/- %s, got %s", msg or "not near", expected, eps, describe(actual)), 2)
	end
end

function T.pixels_equal(a, b, msg)
	result.assertions = result.assertions + 1
	msg = msg or "images differ"
	if not a or not b then T.fail(msg .. ": missing image", 2) end
	if a.width ~= b.width or a.height ~= b.height then
		T.fail(string.format("%s: size %dx%d vs %dx%d", msg, a.width, a.height, b.width, b.height), 2)
	end
	if a.colorMode ~= b.colorMode then
		T.fail(string.format("%s: color mode %s vs %s", msg, a.colorMode, b.colorMode), 2)
	end
	if a.bytes == b.bytes then return end
	for y = 0, a.height - 1 do
		for x = 0, a.width - 1 do
			local pa, pb = a:getPixel(x, y), b:getPixel(x, y)
			if pa ~= pb then
				T.fail(string.format("%s: first difference at (%d,%d): %08x vs %08x", msg, x, y, pa, pb), 2)
			end
		end
	end
end

function T.detail(key, value)
	result.details[key] = value
end

local function handler(err)
	local msg = (type(err) == "table" and getmetatable(err) == FAIL) and err.msg or tostring(err)
	return { msg = msg, traceback = debug.traceback(msg, 2) }
end

--- Closes everything without "save changes?" prompts (a DMI editor's exit hook would ask).
local function discard_and_exit()
	if type(open_editors) == "table" then
		for _, editor in ipairs({ table.unpack(open_editors) }) do
			pcall(editor.close, editor, false, true)
		end
	end
	for _ = 1, #app.sprites do
		local sprite = app.sprites[1]
		if not sprite or not pcall(sprite.close, sprite) then break end
	end
	app.exit()
end

local quit_timer

--- In GUI mode the runner screenshots (if asked) and then writes the quit marker.
function T.done()
	if result.status == "done" then return end
	result.status = "done"
	write_result()
	if MODE == "gui" and not quit_timer then
		quit_timer = Timer {
			interval = 0.2,
			ontick = function()
				if app.fs.isFile(P.harness_quit) then
					quit_timer:stop()
					discard_and_exit()
				end
			end,
		}
		quit_timer:start()
	end
end

local is_async = false

function T.async()
	if MODE ~= "gui" then
		T.fail("async scenarios need the event loop: run with --gui", 2)
	end
	is_async = true
end

local function protect(fn, ...)
	local ok, e = xpcall(fn, handler, ...)
	if not ok and result.ok then
		result.ok = false
		result.message = e.msg
		result.traceback = e.traceback
	end
	if not ok then T.done() end
end

function T.after(seconds, fn)
	local timer
	timer = Timer {
		interval = seconds,
		ontick = function()
			timer:stop()
			if result.status ~= "done" then protect(fn) end
		end,
	}
	timer:start()
	return timer
end

--- Polls pred() until truthy, then calls fn(value); fails after opts.timeout (10 s).
function T.wait_until(pred, fn, opts)
	opts = opts or {}
	local interval = opts.interval or 0.1
	local ticks_left = math.ceil((opts.timeout or 10) / interval) -- ticks, as os.clock() is CPU time
	local timer
	timer = Timer {
		interval = interval,
		ontick = function()
			if result.status == "done" then return timer:stop() end
			ticks_left = ticks_left - 1
			protect(function()
				local value = pred()
				if value then
					timer:stop()
					fn(value)
				elseif ticks_left <= 0 then
					timer:stop()
					T.fail("timed out waiting for " .. (opts.what or "condition"))
				end
			end)
		end,
	}
	timer:start()
	return timer
end

--- Each step is function(next, ...) and calls next(...) to continue.
function T.steps(steps)
	local i = 0
	local function next_step(...)
		i = i + 1
		if steps[i] then protect(steps[i], next_step, ...) end
	end
	next_step()
end

local request_id = 0

--- Hands a request to the runner through req-N.json and waits for its ack-N.json.
local function request(payload, fn, what)
	if MODE ~= "gui" then T.fail(what .. " needs --gui", 3) end
	request_id = request_id + 1
	local base = app.fs.joinPath(P.harness_requests, "req-" .. request_id)
	local file = assert(io.open(base .. ".tmp", "wb"))
	file:write(json.encode(payload))
	file:close()
	assert(os.rename(base .. ".tmp", base .. ".json")) -- atomic for the polling runner
	local ack_path = app.fs.joinPath(P.harness_requests, "ack-" .. request_id .. ".json")
	T.wait_until(function() return app.fs.isFile(ack_path) end, function()
		local ack_file = assert(io.open(ack_path, "rb"))
		local ack = json.decode(ack_file:read("a"))
		ack_file:close()
		if not ack.ok then T.fail(what .. " failed: " .. tostring(ack.error)) end
		if fn then fn(ack) end
	end, { what = what .. " (runner ack)", timeout = 60 })
end

--- Actions: { key = "Ctrl+A" }, { text = "abc" }, { wait = 0.2 }, { move = {x, y} },
--- { click = {x, y}, button = "left"|"right"|"middle", double = true, mods = "Ctrl+Shift" }.
--- Coordinates are UI units in the main window, or in `dialog = <Dialog>` if given.
function T.input(actions, fn)
	local plain_actions = {}
	for i, action in ipairs(actions) do
		local copy = {}
		for k, v in pairs(action) do
			if k ~= "dialog" then copy[k] = v end
		end
		local pos = action.click or action.move
		if pos and action.dialog then
			local b = action.dialog.bounds
			pos = { x = b.x + pos.x, y = b.y + pos.y }
			if action.click then copy.click = pos else copy.move = pos end
		end
		plain_actions[i] = copy
	end
	request({ type = "input", actions = plain_actions, ui_width = app.window.width }, fn, "T.input")
end

function T.screenshot(name, fn)
	request({ type = "screenshot", name = name }, function(ack)
		result.screenshots = result.screenshots or {}
		table.insert(result.screenshots, ack.path)
		if fn then fn(ack.path) end
	end, "T.screenshot")
end

--- Batch mode: what init(plugin) would set up (main.lua only defines init/exit).
local function load_extension()
	local file = assert(io.open(T.path("package.json"), "rb"))
	local package_json = json.decode(file:read("a"))
	file:close()
	for _, script in ipairs(package_json.contributes.scripts) do
		dofile(T.path((script.path:gsub("^%./", ""))))
	end
	local loader, err = package.loadlib(P.harness_dll, "luaopen_dmi_module")
	if not loader then error("failed to load " .. P.harness_dll .. ": " .. tostring(err)) end
	libdmi = loader()
	app.fs.makeDirectory(TEMP_DIR)
	T.plugin = { name = "aseprite-dmi", path = T.repo, preferences = {} }
	Preferences.initialize(T.plugin)
	RawDmi.initialize(T.repo)
end

protect(function()
	if MODE == "batch" then load_extension() end
	dofile(P.harness_scenario)
end)

if not is_async then
	T.done()
else
	write_result() -- status "running": the runner keeps waiting for T.done()
end
