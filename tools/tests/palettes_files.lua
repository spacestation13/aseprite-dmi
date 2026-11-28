--- Batch: .gpl palette read and write (and Aseprite reading our .gpl), presets install.
--- py tools/aseprite_runner.py tools/tests/palettes_files.lua

-- GIMP palette parsing: comments, properties, names with spaces, RGBA channels, junk lines.
local parsed, err = Palettes.parse_gpl(table.concat({
	"GIMP Palette",
	"Name: Test Palette",
	"Columns: 4",
	"# a comment",
	"",
	"  0   0   0\tBlack-1",
	"255 128   7\tWarm orange",
	" 10  20  30\tUntitled",
	"not a color",
	"1 2",
}, "\r\n"))
assert(parsed, err)
T.eq(parsed.name, "Test Palette")
T.eq(parsed.colors, {
	{ r = 0, g = 0, b = 0, a = 255, name = "Black-1" },
	{ r = 255, g = 128, b = 7, a = 255, name = "Warm orange" },
	{ r = 10, g = 20, b = 30, a = 255 },
}, "gpl colors")
T.eq(Palettes.parse_gpl("JASC-PAL\n"), nil, "not a gpl")

local rgba = assert(Palettes.parse_gpl("GIMP Palette\nChannels: RGBA\n1 2 3 4 Glass\n"))
T.eq(rgba.colors[1], { r = 1, g = 2, b = 3, a = 4, name = "Glass" }, "RGBA gpl")

-- Writing: round trip, Channels only when needed.
local palette = {
	name = "Round Trip",
	colors = {
		{ r = 57, g = 58, b = 87, a = 255, name = "Steel-1" },
		{ r = 235, g = 240, b = 242, a = 255, name = "Steel-4" },
		{ r = 0, g = 141, b = 242, a = 255 },
	},
}
local text = Palettes.to_gpl(palette)
T.ok(not text:find("Channels"), "opaque palette has no Channels line")
T.eq(Palettes.parse_gpl(text), palette, "gpl round trip")
local translucent = { colors = { { r = 1, g = 2, b = 3, a = 128 } } }
T.ok(Palettes.to_gpl(translucent):find("Channels: RGBA", 1, true), "alpha palette gets Channels")
T.eq(Palettes.parse_gpl(Palettes.to_gpl(translucent)), translucent, "RGBA round trip")

-- Aseprite itself reads what we write.
local gpl_path = app.fs.joinPath(T.tmp, "round trip.gpl")
T.ok(Palettes.write_gpl(palette, gpl_path))
local native = Palette { fromFile = gpl_path }
T.ok(native, "Aseprite loads our .gpl")
T.eq(#native, 3, "native size")
local second = native:getColor(1)
T.eq({ second.red, second.green, second.blue }, { 235, 240, 242 }, "native color")
T.eq(Palettes.read(gpl_path), palette, "Palettes.read gpl")

-- File titles and presets install (the run's user folder in tests).
T.eq(Palettes.file_title("Goon: \"v2\"/new"), "Goon_ _v2__new")
T.eq(Palettes.file_title("default"), "palette", "never overwrite default.gpl")
local installed, install_err = Palettes.install(palette, "Test Codebase")
assert(installed, install_err)
T.eq(installed, app.fs.joinPath(app.fs.userConfigPath, "palettes", "Test Codebase.gpl"))
T.eq(Palettes.read(installed), palette, "installed preset")
T.ok(Palette { fromResource = "Test Codebase" }, "Aseprite finds the preset by name")

local function slurp(path)
	local file = assert(io.open(path, "rb"))
	local text = file:read("a")
	file:close()
	return text
end

-- Installing again replaces our own earlier copy without asking...
local recolored = { name = "Round Trip", colors = { { r = 1, g = 1, b = 1, a = 255, name = "One-1" } } }
local again, again_err, again_exists = Palettes.install(recolored, "Test Codebase")
T.eq(again, installed, "reinstall replaces our preset: " .. tostring(again_err))
T.eq(again_exists, nil)
T.eq(Palettes.read(installed).colors, recolored.colors, "replaced")
-- ...but a preset the user made is only replaced when asked to.
local user_preset = Palettes.preset_path("My Preset")
T.ok(Palettes.write_gpl(palette, user_preset), "user preset written")
local user_before = slurp(user_preset)
local refused, refused_err, exists = Palettes.install(recolored, "My Preset")
T.eq(refused, nil, "user preset not overwritten")
T.eq(exists, true, "caller told to ask")
T.ok(refused_err and refused_err:find("My Preset", 1, true), tostring(refused_err))
T.eq(slurp(user_preset), user_before, "user preset untouched")
T.eq(Palettes.install(recolored, "My Preset", true), user_preset, "replace when confirmed")
