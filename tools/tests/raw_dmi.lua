--- Batch: raw DMI mode (Open DMI as Spritesheet) through RawDmi's own functions.
--- RawDmi.open only adds the file dialog to RawDmi.open_file.
--- py tools/aseprite_runner.py tools/tests/raw_dmi.lua

--- Calls a libdmi function, which returns (value, error) instead of raising.
local function call(name, ...)
	local value, err = libdmi[name](...)
	T.ok(err == nil, "libdmi." .. name .. " failed: " .. tostring(err))
	return value
end

local function copy_file(from, to)
	local input = assert(io.open(from, "rb"))
	local data = input:read("a")
	input:close()
	local output = assert(io.open(to, "wb"))
	output:write(data)
	output:close()
end

local function metadata_of(path)
	return call("raw_open", path, T.tmp).session.metadata
end

local source = T.path("lib", "tests", "assets", "anomaly.dmi")
local path = app.fs.joinPath(T.tmp, "raw.dmi")
copy_file(source, path)
local metadata = metadata_of(source)

-- Open
local sprite = T.ok(RawDmi.open_file(path), "raw sprite opened")
T.eq(sprite.filename, path, "sprite keeps the .dmi filename")
T.ok(RawDmi.is_sprite(sprite), "sprite is raw")
T.ok(not app.fs.isFile(app.fs.joinPath(TEMP_DIR, "raw_open.png")), "temporary .png removed")
T.eq(sprite.colorMode, ColorMode.RGB, "RGB sprite")
local session = RawDmi.get_session(sprite)
T.eq(session, {
	original_width = sprite.width,
	original_height = sprite.height,
	cell_width = 32,
	cell_height = 32,
	metadata = metadata,
}, "session")
T.eq({ sprite.gridBounds.width, sprite.gridBounds.height }, { 32, 32 }, "grid is the icon size")

-- The session is also stored in the sprite's data, for when the in-memory one is gone.
RawDmi.sessions[sprite] = nil
RawDmi.sprites[sprite] = nil
T.ok(RawDmi.is_sprite(sprite), "sprite data marks the sprite raw")
T.eq(RawDmi.get_session(sprite), session, "session read back from sprite data")

-- Save an edit: pixels change, metadata stays.
local cel = sprite.cels[1]
local image = Image(cel.image)
local magenta = app.pixelColor.rgba(255, 0, 255, 255)
image:drawPixel(1 - cel.position.x, 1 - cel.position.y, magenta)
cel.image = image
T.ok(RawDmi.save(sprite, path), "raw save")
T.eq(metadata_of(path), metadata, "metadata kept")
local dmi = call("open_file", path, TEMP_DIR)
T.eq(#dmi.states, 9, "saved file opens in the editor")
local first = load_image_bytes(app.fs.joinPath(dmi.temp, dmi.states[1].frame_key .. ".0.bytes"))
T.eq(first:getPixel(1, 1), magenta, "edited pixel saved")

-- A resized canvas is refused and leaves the file alone.
local before = call("read_dmi_png", path)
sprite:crop(Rectangle(0, 0, sprite.width + 32, sprite.height))
T.ok(not RawDmi.save(sprite, path), "resized canvas refused")
T.eq(call("read_dmi_png", path), before, "file untouched")
RawDmi.before_close(sprite)
sprite:close()

-- Sprite data written by earlier versions still reads.
local legacy = Sprite(64, 32)
legacy.data = "notes\n__aseprite_dmi_raw__\nv1\n64\n32\n32\n32\n5\nhello"
T.ok(RawDmi.is_sprite(legacy), "legacy data marks the sprite raw")
T.eq(RawDmi.get_session(legacy), {
	original_width = 64,
	original_height = 32,
	cell_width = 32,
	cell_height = 32,
	metadata = "hello",
}, "legacy session")
legacy.data = "notes\n__aseprite_dmi_raw__\nv1\nbroken"
T.ok(RawDmi.is_sprite(legacy), "a damaged session still marks the sprite raw")
T.eq(RawDmi.get_session(legacy), nil, "damaged session unreadable")
legacy:close()

-- Non-ASCII state names survive a raw round trip as UTF-8.
local name = "caf\u{E9} \u{2014} \u{65E5}\u{672C} \u{1F389}"
local fresh = call("new_file", "utf8", 32, 32, TEMP_DIR)
fresh.states[1] = call("new_state", 32, 32, fresh.temp, name)
local utf8_path = app.fs.joinPath(T.tmp, "utf8.dmi")
call("save_file", fresh, utf8_path)
local utf8_sprite = T.ok(RawDmi.open_file(utf8_path), "UTF-8 DMI opened raw")
T.ok(RawDmi.save(utf8_sprite, utf8_path), "UTF-8 DMI raw save")
RawDmi.before_close(utf8_sprite)
utf8_sprite:close()
T.eq(call("open_file", utf8_path, TEMP_DIR).states[1].name, name, "UTF-8 state name kept")
T.ok(metadata_of(utf8_path):find(name, 1, true), "metadata holds the UTF-8 name")
