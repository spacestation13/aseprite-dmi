--- Batch: .gpl/.hex read and write (and Aseprite reading our .gpl), presets install,
--- libdmi.collect_colors, image palettes and the Check Colors math / selection.
--- py tools/aseprite_runner.py tools/tests/palettes_colors.lua

local pc = app.pixelColor

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
T.ok(parsed, err)
T.eq(parsed.name, "Test Palette")
T.eq(parsed.colors, {
	{ r = 0, g = 0, b = 0, a = 255, name = "Black-1" },
	{ r = 255, g = 128, b = 7, a = 255, name = "Warm orange" },
	{ r = 10, g = 20, b = 30, a = 255 },
}, "gpl colors")
T.eq(Palettes.parse_gpl("JASC-PAL\n"), nil, "not a gpl")

local rgba = Palettes.parse_gpl("GIMP Palette\nChannels: RGBA\n1 2 3 4 Glass\n")
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
T.eq(Palettes.from_palette(native).colors[2], { r = 235, g = 240, b = 242, a = 255 }, "native color")
T.eq(Palettes.read(gpl_path), palette, "Palettes.read gpl")

-- .hex
local hex = Palettes.parse_hex("ff0000\n#00FF00\r\n800000ff\n\nnope\n")
T.eq(hex.colors, {
	{ r = 255, g = 0, b = 0, a = 255 },
	{ r = 0, g = 255, b = 0, a = 255 },
	{ r = 0, g = 0, b = 255, a = 0x80 },
}, "hex colors")
T.eq(Palettes.parse_hex("nothing"), nil, "empty hex")

-- Aseprite Palette conversion.
local converted = Palettes.to_palette(palette)
T.eq(#converted, 3)
T.eq(Palettes.from_palette(converted, "Round Trip").colors[1], { r = 57, g = 58, b = 87, a = 255 })

-- File titles and presets install (the run's user folder in tests).
T.eq(Palettes.file_title("Goon: \"v2\"/new"), "Goon_ _v2__new")
T.eq(Palettes.file_title("default"), "palette", "never overwrite default.gpl")
local installed, install_err = Palettes.install(palette, "Test Codebase")
T.ok(installed, install_err)
T.eq(installed, app.fs.joinPath(app.fs.userConfigPath, "palettes", "Test Codebase.gpl"))
T.eq(Palettes.read(installed), palette, "installed preset")
T.ok(Palette { fromResource = "Test Codebase" }, "Aseprite finds the preset by name")

-- Image palette: unique colors in reading order, transparent skipped.
local strip = Image(4, 2, ColorMode.RGB)
strip:clear(pc.rgba(0, 0, 0, 0))
strip:drawPixel(0, 0, pc.rgba(10, 0, 0, 255))
strip:drawPixel(1, 0, pc.rgba(20, 0, 0, 255))
strip:drawPixel(2, 0, pc.rgba(10, 0, 0, 255))
strip:drawPixel(0, 1, pc.rgba(30, 0, 0, 255))
local strip_path = app.fs.joinPath(T.tmp, "strip.png")
strip:saveAs(strip_path)
local from_image = Palettes.read(strip_path)
T.eq(from_image.colors, {
	{ r = 10, g = 0, b = 0, a = 255 },
	{ r = 20, g = 0, b = 0, a = 255 },
	{ r = 30, g = 0, b = 0, a = 255 },
}, "image palette")

-- collect_colors on a real .dmi: counts add up, sorted, alpha 0 excluded; max keeps the top.
local dmi_path = T.path("lib", "tests", "assets", "anomaly.dmi")
local counts, counts_err = libdmi.collect_colors({ dmi_path })
T.ok(counts, counts_err)
local png = libdmi.read_dmi_png(dmi_path)
local visible = 0
for i = 4, #png.bytes, 4 do
	if png.bytes:byte(i) > 0 then visible = visible + 1 end
end
local total = 0
for i, color in ipairs(counts) do
	total = total + color.count
	T.ok(color.a > 0, "no transparent colors")
	if i > 1 then T.ok(counts[i - 1].count >= color.count, "sorted by count") end
end
T.eq(total, visible, "every visible pixel counted")
local twice = libdmi.collect_colors({ dmi_path, dmi_path })
T.eq(twice[1].count, counts[1].count * 2, "files add up")
local top, top_counts = Palettes.collect({ dmi_path }, 5, "anomaly")
T.eq(#top.colors, 5, "max colors")
T.eq(#top_counts, #counts)
T.eq(top.colors[1], { r = counts[1].r, g = counts[1].g, b = counts[1].b, a = counts[1].a }, "most used first")
T.eq(#Palettes.collect({ dmi_path }, 0).colors, #counts, "0 = all")
local bad, _, bad_err = Palettes.collect({ app.fs.joinPath(T.tmp, "missing.dmi") })
T.eq(bad, nil)
T.ok(bad_err, "missing file error")
T.detail("anomaly_colors", #counts)

-- Check Colors: 2 layers x 2 frames with known pixels.
local RED, GREEN, BLUE = pc.rgba(255, 0, 0, 255), pc.rgba(0, 255, 0, 255), pc.rgba(0, 0, 255, 255)
local RED_GLASS = pc.rgba(255, 0, 0, 100)
local ODD, ODD2 = pc.rgba(1, 2, 3, 255), pc.rgba(4, 5, 6, 255)

local sprite = Sprite(4, 4, ColorMode.RGB)
sprite:newFrame()
local south = sprite.layers[1]
south.name = "South"
local north = sprite:newLayer()
north.name = "North"

local function paint(layer, frame, pixels)
	local image = Image(4, 4, ColorMode.RGB)
	image:clear(pc.rgba(0, 0, 0, 0))
	for _, p in ipairs(pixels) do
		image:drawPixel(p[1], p[2], p[3])
	end
	sprite:newCel(layer, frame, image, Point(0, 0))
end

paint(south, 1, { { 0, 0, RED }, { 1, 0, RED }, { 2, 0, GREEN }, { 3, 0, ODD } })
paint(south, 2, { { 0, 0, RED }, { 1, 1, RED_GLASS } })
paint(north, 1, { { 0, 3, BLUE }, { 1, 3, ODD }, { 2, 3, ODD }, { 3, 3, ODD2 } })
-- north frame 2 empty

local check_palette = { colors = { { r = 255, g = 0, b = 0, a = 255 }, { r = 0, g = 255, b = 0, a = 255 },
	{ r = 0, g = 0, b = 255, a = 255 }, { r = 1, g = 2, b = 3, a = 0 } } }
local report = Palettes.check(sprite, check_palette)
T.eq(report.colors, 6, "unique colors (red glass is its own color)")
T.eq(report.pixels, 10, "visible pixels")
T.eq(report.palette_size, 3, "transparent palette entries don't count")
T.eq(report.layers[1], { name = "South", colors = 4, frames = { 3, 2 } }, "South layer")
T.eq(report.layers[2], { name = "North", colors = 3, frames = { 3, 0 } }, "North layer")
T.eq(report.frames, { 5, 2 }, "per frame")
T.eq(report.off_pixels, 4, "off-palette pixels (translucent red matches red)")
T.eq(report.off_palette, {
	{ r = 1, g = 2, b = 3, a = 255, count = 3 },
	{ r = 4, g = 5, b = 6, a = 255, count = 1 },
}, "off-palette colors by count")

-- The sprite's own palette is the default.
sprite:setPalette(Palettes.to_palette(check_palette))
T.eq(Palettes.check(sprite).off_pixels, 4, "sprite palette by default")

-- Selection of off-palette pixels in frame 1: (3,0), (1,3)-(2,3) merged, (3,3).
local selection, selected = Palettes.off_palette_selection(sprite, 1)
T.eq(selected, 4, "selected pixel count")
T.eq(selection.bounds, Rectangle(1, 0, 3, 4), "selection bounds")
for _, p in ipairs({ { 3, 0 }, { 1, 3 }, { 2, 3 }, { 3, 3 } }) do
	T.ok(selection:contains(p[1], p[2]), "selected " .. p[1] .. "," .. p[2])
end
for _, p in ipairs({ { 0, 0 }, { 2, 0 }, { 0, 3 } }) do
	T.ok(not selection:contains(p[1], p[2]), "not selected " .. p[1] .. "," .. p[2])
end
local _, none = Palettes.off_palette_selection(sprite, 2)
T.eq(none, 0, "frame 2 is on palette")

T.eq(Palettes.select_off_palette(sprite, 1), 4)
T.eq(sprite.selection.bounds, Rectangle(1, 0, 3, 4), "sprite selection set")

-- Apply replaces the palette, undoably.
Palettes.apply({ sprite }, palette)
T.eq(#sprite.palettes[1], 3, "palette applied")
T.eq(Palettes.from_palette(sprite.palettes[1]).colors[1], { r = 57, g = 58, b = 87, a = 255 })
app.undo()
T.eq(Palettes.from_palette(sprite.palettes[1]).colors[2], { r = 0, g = 255, b = 0, a = 255 }, "undo restores")

-- Off-sprite cel offsets: a cel positioned at (2,1) selects shifted pixels.
local offset_sprite = Sprite(8, 8, ColorMode.RGB)
local small = Image(2, 1, ColorMode.RGB)
small:drawPixel(0, 0, ODD)
small:drawPixel(1, 0, RED)
offset_sprite.cels[1].image = small
offset_sprite.cels[1].position = Point(2, 1)
offset_sprite:setPalette(Palettes.to_palette(check_palette))
local offset_selection = Palettes.off_palette_selection(offset_sprite, 1)
T.eq(offset_selection.bounds, Rectangle(2, 1, 1, 1), "cel position applied")

-- Grayscale sprites.
local gray = Sprite(2, 1, ColorMode.GRAYSCALE)
local gray_image = Image(2, 1, ColorMode.GRAYSCALE)
gray_image:drawPixel(0, 0, pc.graya(255, 255))
gray_image:drawPixel(1, 0, pc.graya(17, 255))
gray.cels[1].image = gray_image
local gray_report = Palettes.check(gray, { colors = { { r = 255, g = 255, b = 255, a = 255 } } })
T.eq(gray_report.colors, 2, "grayscale colors")
T.eq(gray_report.off_palette, { { r = 17, g = 17, b = 17, a = 255, count = 1 } }, "grayscale off-palette")

sprite:close()
offset_sprite:close()
gray:close()
