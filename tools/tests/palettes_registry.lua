--- Batch: Registry cache/TTL/fallback logic with a fake downloader and clock, then the real
--- bundled registry and the Goonstation palette. No network.
--- py tools/aseprite_runner.py tools/tests/palettes_registry.lua

local function write(path, text)
	app.fs.makeAllDirectories(app.fs.filePath(path))
	local file = assert(io.open(path, "wb"))
	file:write(text)
	file:close()
end

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("a")
	file:close()
	return text
end

local function registry_json(updated, id)
	return json.encode {
		version = 1,
		updated = updated,
		palettes = { { id = id, name = id, url = Registry.BASE_URL .. "palettes/" .. id .. ".gpl" } },
	}
end

-- Hash: FNV-1a 64 reference values.
T.eq(Registry.hash(""), "cbf29ce484222325", "fnv1a64('')")
T.eq(Registry.hash("a"), "af63dc4c8601ec8c", "fnv1a64('a')")

-- JSON: plain tables (Aseprite's json.decode gives userdata proxies and float numbers).
T.eq(Registry.decode('{"a":[1,2,{"b":3}],"c":1.5,"d":[],"e":{}}'), { a = { 1, 2, { b = 3 } }, c = 1.5, d = {}, e = {} },
	"decode")
T.eq(math.type(Registry.decode('[7]')[1]), "integer", "integral numbers become integers")
T.eq(Registry.decode("<html>"), nil, "invalid JSON")
T.eq(Registry.decode('"text"'), nil, "not an object or array")

local real_download = Registry.download
local real_now = Registry.now

local root = app.fs.joinPath(T.tmp, "registry")
local bundled = app.fs.joinPath(root, "bundled")
local cache = app.fs.joinPath(root, "cache")
Registry.initialize(root, cache)
Registry.bundled_dir = bundled
write(app.fs.joinPath(bundled, "palettes.json"), registry_json("2026-01-01", "bundled"))
write(app.fs.joinPath(bundled, "palettes", "bundled.gpl"), "GIMP Palette\n255 0 0\tRed-1\n")

-- Fake network: `server[url]` is the body, or nil for a failure.
local server, calls = {}, {}
local clock = 1000000
Registry.now = function() return clock end
---@diagnostic disable-next-line: duplicate-set-field
Registry.download = function(url, dest, timeout)
	table.insert(calls, url)
	T.eq(timeout, Registry.TIMEOUT, "download timeout")
	if not server[url] then return nil, "connection refused" end
	write(dest, server[url])
	return #server[url]
end
local index_url = Registry.BASE_URL .. "palettes.json"

-- 1. Without `online` nothing is downloaded: bundled copy.
local data, info = Registry.load("palettes")
T.eq(#calls, 0, "offline load doesn't download")
T.eq(info.source, "bundled", "offline -> bundled")
T.eq(data.palettes[1].id, "bundled")

-- 2. Online with a working network: downloaded and cached.
server[index_url] = registry_json("2026-02-01", "remote")
data, info = Registry.load("palettes", { online = true })
T.eq(#calls, 1, "one download")
T.eq(calls[1], index_url, "index url")
T.eq(info.source, "network")
T.eq(data.palettes[1].id, "remote")
T.ok(app.fs.isFile(app.fs.joinPath(cache, "palettes.json")), "cached")
T.ok(not app.fs.isFile(app.fs.joinPath(cache, "palettes.json.download")), "temp file removed")

-- 3. Fresh cache: no download even online.
clock = clock + Registry.TTL - 1
data, info = Registry.load("palettes", { online = true })
T.eq(#calls, 1, "fresh cache not re-downloaded")
T.eq(info.source, "cache")
T.eq(info.stale, false, "fresh")
T.eq(data.palettes[1].id, "remote")
T.eq(Registry.describe(info), "Cached 23 h ago")

-- 4. Stale cache and the network fails: stale cache with the error.
clock = clock + 2
server[index_url] = nil
data, info = Registry.load("palettes", { online = true })
T.eq(#calls, 2, "stale cache re-downloaded")
T.eq(info.source, "cache")
T.eq(info.stale, true, "stale")
T.eq(info.error, "connection refused")
T.eq(data.palettes[1].id, "remote", "falls back to the cache")
T.ok(Registry.describe(info):find("update failed: connection refused", 1, true), Registry.describe(info))

-- 5. Right after a failure, `online` loads back off; refresh doesn't; after RETRY_AFTER it retries.
Registry.load("palettes", { online = true })
T.eq(#calls, 2, "backing off after a failure")
Registry.load("palettes", { online = true, refresh = true })
T.eq(#calls, 3, "refresh ignores the back-off")
clock = clock + Registry.RETRY_AFTER
Registry.load("palettes", { online = true })
T.eq(#calls, 4, "retried after RETRY_AFTER")

-- 6. A download that isn't JSON doesn't replace the cache.
server[index_url] = "<html>rate limited</html>"
data, info = Registry.load("palettes", { online = true, refresh = true })
T.eq(info.source, "cache")
T.ok(info.error and info.error:find("invalid", 1, true), "invalid download reported")
T.eq(data.palettes[1].id, "remote", "cache kept")

-- 7. Refresh with a working network replaces a fresh cache.
server[index_url] = registry_json("2026-03-01", "remote2")
data, info = Registry.load("palettes", { online = true, refresh = true })
T.eq(info.source, "network")
T.eq(data.palettes[1].id, "remote2")

-- 8. A bundled copy newer than the cache (extension updated) wins over the cache.
write(app.fs.joinPath(bundled, "palettes.json"), registry_json("2026-04-01", "bundled-new"))
data, info = Registry.load("palettes")
T.eq(info.source, "bundled", "newer bundled copy")
T.eq(data.palettes[1].id, "bundled-new")

-- 9. No cache, no network: bundled with the error; nothing bundled: nil.
local missing_data, missing_info = Registry.load("nonexistent", { online = true })
T.eq(missing_data, nil, "unknown registry")
T.eq(missing_info.error, "connection refused")
T.eq(missing_info.source, nil)

-- Assets: this repo's URLs fall back to the bundled copy; others need the network or cache.
local asset_url = Registry.BASE_URL .. "palettes/bundled.gpl"
local path, asset_info = Registry.asset(asset_url)
T.eq(asset_info.source, "bundled", "asset offline -> bundled")
T.eq(path, app.fs.joinPath(bundled, "palettes", "bundled.gpl"))

server[asset_url] = "GIMP Palette\n0 255 0\tGreen-1\n"
path, asset_info = Registry.asset(asset_url, { online = true })
T.eq(asset_info.source, "network", "asset downloaded")
T.eq(path, app.fs.joinPath(cache, "assets", Registry.hash(asset_url) .. ".gpl"), "cached by URL hash")
T.eq(read(path), server[asset_url])

server[asset_url] = nil
path, asset_info = Registry.asset(asset_url, { online = true, refresh = true })
T.eq(asset_info.source, "cache", "asset cache after a failure")
T.eq(read(path), "GIMP Palette\n0 255 0\tGreen-1\n")

-- Only files hosted in this repository: anything else is refused before the cache or network.
local refused = {
	"https://raw.githubusercontent.com/example/codebase/master/.github/palette.png",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi-evil/main/x.gpl", -- lookalike repo
	"http://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/x.gpl", -- not https
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/../../example/codebase/master/x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/%2e%2e/%2e%2e/example/x.gpl",
	"https://example.com/https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl",
	-- URL parsers drop tabs/CR/LF: `.\t.` would become `..` and leave the repository.
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.\t./.\t./evil/repo/main/x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.\n./.\r./evil/repo/main/x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x .gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/.%2E/x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/./x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main//x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main\\x.gpl",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl?token=1",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/x.gpl#frag",
	"https://raw.githubusercontent.com/spacestation13/aseprite-dmi/",
}
local calls_before = #calls
for _, url in ipairs(refused) do
	T.eq(Registry.is_allowed(url), false, "refused: " .. url)
	-- A file already sitting at its cache path must not be used either.
	write(app.fs.joinPath(cache, "assets", Registry.hash(url) .. ".gpl"), "GIMP Palette\n1 2 3\tX\n")
	for _, options in ipairs({ {}, { online = true }, { online = true, refresh = true } }) do
		path, asset_info = Registry.asset(url, options)
		T.eq(path, nil, "no path for " .. url)
		T.ok(asset_info.error and asset_info.error:find("hosted in this repository", 1, true),
			"clear error: " .. tostring(asset_info.error))
	end
end
T.eq(#calls, calls_before, "refused URLs are never downloaded")
T.ok(Registry.is_allowed("https://raw.githubusercontent.com/spacestation13/aseprite-dmi/some-branch/registry/x_v2.gpl"),
	"any branch of this repo")
T.ok(Registry.is_allowed("https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/..hidden.gpl"),
	"dots inside a name are fine")
T.ok(Registry.is_allowed(Registry.BASE_URL .. "palettes.json"), "registry index allowed")
T.eq(Registry.is_allowed(nil), false, "nil url")

-- Entries pointing outside the repository aren't listed.
local listed = Palettes.entries {
	palettes = {
		{ id = "ours", name = "Ours", url = Registry.BASE_URL .. "palettes/ours.gpl" },
		{ id = "theirs", name = "Theirs", url = refused[1] },
	},
}
T.eq(#listed, 1, "foreign entry skipped")
T.eq(listed[1].id, "ours")

T.eq(Registry.bundled_path(Registry.BASE_URL .. "../secret.txt"), nil, "no path traversal")
T.eq(Registry.bundled_path("https://example.com/palettes.json"), nil, "foreign URL not bundled")

-- The real libdmi.download enforces the same rule on the parsed URL (no network needed: every
-- one of these is refused before connecting).
for _, url in ipairs({ "file:///C:/Windows/win.ini", "https://example.com/x.gpl", refused[8], refused[9] }) do
	local bytes, err = real_download(url, app.fs.joinPath(T.tmp, "x"), 1)
	T.eq(bytes, nil, "libdmi.download refused " .. url)
	T.ok(err and err:find("Refused", 1, true), "libdmi.download error: " .. tostring(err))
	T.ok(not app.fs.isFile(app.fs.joinPath(T.tmp, "x")), "nothing written")
end

-- The shipped registry: palettes.json + goonstation.gpl, offline.
---@diagnostic disable-next-line: duplicate-set-field
Registry.download = function() T.fail("network used") end
Registry.now = real_now
Registry.initialize(T.repo, app.fs.joinPath(T.tmp, "real-cache"))
local shipped, shipped_info = Registry.load("palettes")
T.eq(shipped_info.source, "bundled")
T.eq(shipped.version, 1)
local entries = Palettes.entries(shipped)
T.ok(#entries >= 1, "shipped entries")
local shipped_by_id = {}
for _, entry in ipairs(entries) do
	T.ok(entry.url:find("^https://"), entry.id .. " url is https")
	shipped_by_id[entry.id] = entry
end
local goon = shipped_by_id.goonstation
T.ok(goon, "goonstation entry")
local palette, palette_info = Palettes.load_entry(goon)
T.ok(palette, "goonstation palette loads: " .. tostring(palette_info.error))
T.eq(palette_info.source, "bundled")
T.eq(palette.name, "Goonstation")
T.eq(#palette.colors, 78, "goonstation color count")
T.eq(palette.colors[1], { r = 0x39, g = 0x3a, b = 0x57, a = 255, name = "Steel-1" }, "first swatch")
T.eq(palette.colors[#palette.colors].name, "Gunmetal-4", "last swatch")

local metals, metals_info = Palettes.load_entry(shipped_by_id.goonstation_metals)
T.ok(metals, "goonstation metals palette loads: " .. tostring(metals_info and metals_info.error))
T.eq(metals.name, "Goonstation Metals")
T.eq(#metals.colors, 35, "seven 5-step metal ramps")
T.eq(metals.colors[1].name, "Brass-1", "first metal swatch")
T.eq(metals.colors[#metals.colors].name, "Steel-5", "last metal swatch")

Registry.download = real_download
T.detail("goonstation_colors", #palette.colors)
