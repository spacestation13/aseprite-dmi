--- Remote registries: JSON files in this repo's `registry/` directory (palettes.json, ...),
--- plus the files their entries point at (assets).
---
--- The network is only used when a caller passes `online = true`, which callers do only on an
--- explicit user action (opening a dialog, pressing Refresh), never at startup. Downloads use a
--- short timeout; results are cached under the user config folder with a TTL, and a failed
--- fetch falls back to the cache, then to the copy bundled with the extension.
---
--- Only files hosted in this repository are ever fetched (`Registry.ALLOWED_PREFIX`): files in
--- other repositories can go stale or be swapped for something else after review.
--- @class Registry
Registry = {}

Registry.BASE_URL = "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/"
--- Every registry and asset URL must start with this.
Registry.ALLOWED_PREFIX = "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/"

--- Seconds a download may take.
Registry.TIMEOUT = 5
--- Seconds a cached file counts as fresh.
Registry.TTL = 24 * 60 * 60
--- Seconds after a failed download before `online` loads try the network again (refresh always does).
Registry.RETRY_AFTER = 10 * 60

--- `<extension>/registry`, the bundled copies.
--- @type string|nil
Registry.bundled_dir = nil
--- Where downloads are cached.
--- @type string|nil
Registry.cache_dir = nil

--- Current time in seconds (replaceable in tests).
Registry.now = os.time

--- Downloads `url` to `dest` (replaceable in tests). Returns a value or nil and an error.
--- @param url string
--- @param dest string
--- @param timeout number
--- @return any|nil, string|nil
function Registry.download(url, dest, timeout)
	if not libdmi then return nil, "DMI library not loaded" end
	return libdmi.download(url, dest, timeout)
end

--- @class Registry.Info
--- @field source "network"|"cache"|"bundled"|nil Where the result came from (nil: nothing found).
--- @field fetched number|nil When the result was downloaded (os.time), for network/cache.
--- @field stale boolean|nil The cached result is older than the TTL.
--- @field error string|nil Why a download failed (the result, if any, is a fallback).

--- @class Registry.Options
--- @field online boolean|nil May use the network (explicit user action only).
--- @field refresh boolean|nil Download even if the cache is fresh or a download just failed.

--- Sets the directories. Does no I/O.
--- @param plugin_path string Extension directory (holds the bundled `registry/`).
--- @param cache_dir string|nil Defaults to `<user config>/aseprite-dmi/registry`.
function Registry.initialize(plugin_path, cache_dir)
	Registry.bundled_dir = app.fs.joinPath(plugin_path, "registry")
	Registry.cache_dir = cache_dir or app.fs.joinPath(app.fs.userConfigPath, "aseprite-dmi", "registry")
end

--- 64-bit FNV-1a of a string as 16 hex digits (Lua 5.4 integers wrap).
--- @param text string
--- @return string
function Registry.hash(text)
	local hash = 0xcbf29ce484222325
	for i = 1, #text do
		hash = (hash ~ text:byte(i)) * 0x100000001b3
	end
	return string.format("%016x", hash)
end

local function read_file(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("a")
	file:close()
	return text
end

local function write_file(path, text)
	local file = io.open(path, "wb")
	if not file then return false end
	file:write(text)
	file:close()
	return true
end

--- Aseprite's json.decode returns userdata proxies and floats; plain tables and integers are
--- easier to work with (ipairs, type checks, json.encode).
local function plain(value)
	if type(value) == "userdata" then
		-- Objects iterate with pairs (arrays yield nothing there); arrays index 1..#value.
		local result = {}
		for k, v in pairs(value) do
			result[k] = plain(v)
		end
		if next(result) == nil then
			for i = 1, #value do
				result[i] = plain(value[i])
			end
		end
		return result
	elseif math.type(value) == "float" and value == math.floor(value) then
		-- Not math.tointeger: Aseprite's Lua floors floats there (1.5 -> 1).
		return math.floor(value)
	end
	return value
end

--- Decodes JSON text into plain Lua tables; nil unless it is an object or array.
--- @param text string
--- @return table|nil
function Registry.decode(text)
	-- Invalid JSON either raises or decodes to a non-iterable value.
	local ok, data = pcall(function() return plain(json.decode(text)) end)
	return ok and type(data) == "table" and data or nil
end

local function read_json(path)
	local text = read_file(path)
	return text and Registry.decode(text) or nil
end

--- Replaces `dest` with `src` (os.rename doesn't overwrite on Windows).
local function replace_file(src, dest)
	os.remove(dest)
	return os.rename(src, dest)
end

local function meta_path()
	return app.fs.joinPath(Registry.cache_dir, "meta.json")
end

--- Download times per cache key: `{ [key] = { fetched = time, failed = time } }`.
local function read_meta()
	return read_json(meta_path()) or {}
end

local function update_meta(key, fields)
	local meta = read_meta()
	local entry = meta[key] or {}
	for k, v in pairs(fields) do entry[k] = v end
	meta[key] = entry
	app.fs.makeAllDirectories(Registry.cache_dir)
	write_file(meta_path(), json.encode(meta))
end

--- Whether a URL may be fetched: inside this repository (`ALLOWED_PREFIX`), and the rest is a
--- plain path: only letters, digits and `-_~/.`, no empty, `.` or `..` segments. Anything else
--- (whitespace, which URL parsers drop, `%` escapes, `\`, `?`, `#`) could lead out of it.
--- libdmi.download enforces the same rule on the parsed URL.
--- @param url string
--- @return boolean
function Registry.is_allowed(url)
	if type(url) ~= "string" or not url:starts_with(Registry.ALLOWED_PREFIX) then
		return false
	end
	local path = url:sub(#Registry.ALLOWED_PREFIX + 1)
	if not path:match("^[%w%-_~/%.]+$") then
		return false
	end
	for segment in (path .. "/"):gmatch("([^/]*)/") do
		if segment == "" or segment == "." or segment == ".." then
			return false
		end
	end
	return true
end

--- The error for a URL outside this repository.
local function not_allowed(url)
	return "Refused " .. tostring(url) .. ": registry files must be hosted in this repository ("
		.. Registry.ALLOWED_PREFIX .. ")"
end

--- Downloads into the cache unless the cached file is fresh. Returns the info of what is cached.
--- @param key string Cache key (meta.json).
--- @param url string
--- @param path string Cache file.
--- @param options Registry.Options
--- @param validate (fun(tmp: string): boolean)|nil Rejects a downloaded file.
--- @return Registry.Info
local function sync(key, url, path, options, validate)
	local now = Registry.now()
	local entry = read_meta()[key] or {}
	local cached = app.fs.isFile(path)
	local fresh = cached and entry.fetched and now - entry.fetched < Registry.TTL
	local backing_off = entry.failed and (not entry.fetched or entry.failed > entry.fetched)
		and now - entry.failed < Registry.RETRY_AFTER

	local err
	if not Registry.is_allowed(url) then
		return { error = not_allowed(url) }
	end
	if options.online and (options.refresh or (not fresh and not backing_off)) then
		local tmp = path .. ".download"
		app.fs.makeAllDirectories(app.fs.filePath(path))
		local _, download_err = Registry.download(url, tmp, Registry.TIMEOUT)
		if download_err then
			err = download_err
		elseif validate and not validate(tmp) then
			err = "Downloaded file is invalid: " .. url
		elseif not replace_file(tmp, path) then
			err = "Could not write " .. path
		else
			update_meta(key, { fetched = now })
			return { source = "network", fetched = now }
		end
		os.remove(tmp)
		update_meta(key, { failed = now })
	end

	if cached then
		return { source = "cache", fetched = entry.fetched, stale = not fresh, error = err }
	end
	return { error = err }
end

--- Loads `registry/<name>.json`: the network (with `online`, when the cache is stale or on
--- refresh), else the cache or the bundled copy, whichever has the newer `updated` field.
--- @param name string Registry name, e.g. "palettes".
--- @param options Registry.Options|nil
--- @return table|nil data
--- @return Registry.Info info
function Registry.load(name, options)
	options = options or {}
	local file = name .. ".json"
	local cache_file = app.fs.joinPath(Registry.cache_dir, file)

	local info = sync("registry/" .. file, Registry.BASE_URL .. file, cache_file, options, function(tmp)
		return read_json(tmp) ~= nil
	end)

	local cached = info.source and read_json(cache_file)
	if info.source == "network" and cached then
		return cached, info
	end

	local bundled = read_json(app.fs.joinPath(Registry.bundled_dir, file))
	if cached and not (bundled and tostring(bundled.updated or "") > tostring(cached.updated or "")) then
		return cached, info
	end
	if bundled then
		return bundled, { source = "bundled", error = info.error }
	end
	return nil, { error = info.error or ("Registry not found: " .. file) }
end

--- Local path of a file an entry points at (`url`), downloaded with `online` when not cached
--- or stale. Cached by URL hash. Falls back to the cache, then to the bundled copy. URLs
--- outside this repository are refused (nil and an error, nothing read or downloaded).
--- @param url string
--- @param options Registry.Options|nil
--- @return string|nil path
--- @return Registry.Info info
function Registry.asset(url, options)
	options = options or {}
	if not Registry.is_allowed(url) then
		return nil, { error = not_allowed(url) }
	end
	local extension = url:gsub("[?#].*$", ""):match("%.(%w+)$") or "bin"
	local path = app.fs.joinPath(Registry.cache_dir, "assets", Registry.hash(url) .. "." .. extension:lower())

	local info = sync("asset/" .. url, url, path, options)
	if info.source then
		return path, info
	end

	local bundled = Registry.bundled_path(url)
	if bundled and app.fs.isFile(bundled) then
		return bundled, { source = "bundled", error = info.error }
	end
	return nil, { error = info.error or ("Not downloaded yet: " .. url) }
end

--- The bundled copy of a URL inside this repo's registry, or nil.
--- @param url string
--- @return string|nil
function Registry.bundled_path(url)
	if not url:starts_with(Registry.BASE_URL) then
		return nil
	end
	local relative = url:sub(#Registry.BASE_URL + 1)
	if relative:find("..", 1, true) then
		return nil
	end
	return app.fs.joinPath(Registry.bundled_dir, table.unpack(relative:split("/")))
end

--- One line describing where a result came from, for dialogs.
--- @param info Registry.Info
--- @return string
function Registry.describe(info)
	local text
	if info.source == "network" then
		text = "Downloaded just now"
	elseif info.source == "cache" then
		local age = info.fetched and math.max(0, Registry.now() - info.fetched)
		if not age then
			text = "Cached copy"
		elseif age < 3600 then
			text = string.format("Cached %d min ago", age // 60)
		elseif age < 48 * 3600 then
			text = string.format("Cached %d h ago", age // 3600)
		else
			text = string.format("Cached %d days ago", age // 86400)
		end
	elseif info.source == "bundled" then
		text = "Bundled copy"
	else
		text = "Not available"
	end
	if info.error then
		local reason = info.error:gsub("%s+", " ")
		if #reason > 80 then reason = reason:sub(1, 77) .. "..." end
		text = text .. " - update failed: " .. reason
	end
	return text
end
