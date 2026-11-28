--- Batch: saving a state sprite with layer groups above direction layers. Save used to loop
--- forever (Merge Down can't merge a group), then blended grouped layers against transparency.
--- py tools/aseprite_runner.py tools/tests/save_groups.lua

local rgba = app.pixelColor.rgba
local A, C, D, E = rgba(255, 0, 0), rgba(0, 0, 255), rgba(255, 255, 0), rgba(0, 255, 255)

--- A sprite laid out like Editor:open_state builds it: one layer per direction, South on top.
local function make_state(dirs, size)
	local sprite = Sprite(ImageSpec { width = size, height = size, colorMode = ColorMode.RGB })
	app.sprite = sprite
	while #sprite.layers < dirs do sprite:newLayer() end
	for i = 1, dirs do
		sprite.layers[#sprite.layers - i + 1].name = DIRECTION_NAMES[i]
	end
	local layers = {}
	for _, layer in ipairs(sprite.layers) do
		layers[layer.name] = layer
		local cel = layer:cel(1)
		if cel then sprite:deleteCel(cel) end -- newLayer() puts a cel in frame 1
	end
	return sprite, layers
end

--- Image from rows of pixel values (0 = transparent).
local function image(rows)
	local img = Image(#rows[1], #rows, ColorMode.RGB)
	for y, row in ipairs(rows) do
		for x, value in ipairs(row) do img:drawPixel(x - 1, y - 1, value) end
	end
	return img
end

local function new_layer(sprite, name, parent)
	local layer = sprite:newLayer()
	layer.name = name
	if parent then layer.parent = parent end
	return layer
end

--- Names of all layers, groups expanded as name{children}.
local function tree(layers)
	local out = {}
	for _, layer in ipairs(layers) do
		out[#out + 1] = layer.isGroup and (layer.name .. "{" .. tree(layer.layers) .. "}") or layer.name
	end
	return table.concat(out, ",")
end

--- Every layer's cel for frame 1 drawn onto a sprite-sized canvas, in layer order.
local function snapshot(sprite)
	local snap = {}
	for _, layer in ipairs(sprite.layers) do
		local out = Image(sprite.spec)
		local cel = layer.isImage and layer:cel(1) or nil
		if cel then out:drawImage(cel.image, cel.position) end
		snap[layer.name] = out
	end
	return snap
end

local function same_snapshot(a, b, what)
	for name, img in pairs(a) do T.pixels_equal(img, b[name], what .. ": " .. name) end
end

--- A state sprite with a stand-in editor, enough for StateSprite:save and set_state_dirs.
--- Exports go to "<T.tmp>/<key>/<key>.<index>.bytes".
local function stub_state_sprite(sprite, key, dirs)
	local temp = app.fs.joinPath(T.tmp, key)
	app.fs.makeAllDirectories(temp)
	local editor = setmetatable({
		title = "test",
		dmi = { width = sprite.width, height = sprite.height, temp = temp },
		image_cache = { remove = function() end, set = function() end, get = function() end },
		repaint_states = function() end,
		open_sprites = {},
	}, { __index = Editor })
	local state = { dirs = dirs or 4, frame_key = key, frame_count = #sprite.frames, delays = {} }
	local state_sprite = StateSprite.new(editor, editor.dmi, state, sprite, Color { r = 0, g = 0, b = 0, a = 0 })
	editor.open_sprites[1] = state_sprite
	return state_sprite, temp
end

--- Saves a 4-direction state sprite through StateSprite:save; South is exported as index 0, then
--- North, East, West.
--- @return boolean saved
--- @return fun(name: string): Image export The exported image of a direction.
local function save_state(sprite, key)
	local state_sprite, temp = stub_state_sprite(sprite, key)
	T.ok(Preferences.getAutoFlatten(), "auto-flatten on")
	local saved = state_sprite:save()
	return saved, function(name)
		local index = table.index_of(DIRECTION_NAMES, name) - 1
		return T.ok(load_image_bytes(app.fs.joinPath(temp, key .. "." .. index .. ".bytes")), "missing export " .. name)
	end
end

------------------------------------------------------------------------
-- Groups above direction layers: their layers merge into the direction below, nested groups
-- and hidden layers included, and Save restores the layers afterwards.
do
	local sprite, L = make_state(4, 8)
	local details = sprite:newGroup()
	details.name = "Details"
	details.stackIndex = 3 -- between East and North
	local ink = new_layer(sprite, "Ink", details)
	local glow = new_layer(sprite, "Glow", details)
	local inner = sprite:newGroup()
	inner.name = "Inner"
	inner.parent = details
	local spark = new_layer(sprite, "Spark", inner)
	local empty = sprite:newGroup() -- above South, nothing inside
	empty.name = "Empty"
	T.eq(tree(sprite.layers), "West,East,Details{Ink,Glow,Inner{Spark}},North,South,Empty{}", "layer tree")

	sprite:newCel(L.East, 1, image { { E } }, Point(0, 0))
	sprite:newCel(ink, 1, image { { A } }, Point(1, 1))
	glow.isVisible = false -- hidden layers inside are merged too
	sprite:newCel(glow, 1, image { { D } }, Point(2, 2))
	sprite:newCel(spark, 1, image { { C } }, Point(3, 3))
	details.opacity = 40 -- groups have no opacity of their own when rendered

	local before = snapshot(sprite)
	local saved, exported = save_state(sprite, "groups")
	T.ok(saved, "save with groups finishes")
	same_snapshot(snapshot(sprite), before, "save restores the layers")
	T.eq(tree(sprite.layers), "West,East,Details{Ink,Glow,Inner{Spark}},North,South,Empty{}", "groups restored")
	local east = exported("East")
	T.eq({ east:getPixel(0, 0), east:getPixel(1, 1), east:getPixel(2, 2), east:getPixel(3, 3) }, { E, A, D, C },
		"East has its own pixel plus every layer of the group above it")
	T.eq(exported("North"):getPixel(1, 1), 0, "nothing leaks into the direction below the group")
	sprite:close()
end

-- A Multiply layer gives the same saved pixel inside a group as at the top level, matching what
-- the canvas shows (grouped used to save 800000ff instead of 640000ff).
do
	local results = {}
	for _, grouped in ipairs({ false, true }) do
		local sprite, L = make_state(4, 4)
		sprite:newCel(L.South, 1, image { { rgba(200, 200, 200) } }, Point(0, 0))
		local shade = new_layer(sprite, "Shade")
		shade.blendMode = BlendMode.MULTIPLY
		sprite:newCel(shade, 1, image { { rgba(128, 0, 0) } }, Point(0, 0))
		if grouped then
			local group = sprite:newGroup()
			group.name = "Shading"
			shade.parent = group
		end
		for _, name in ipairs({ "North", "East", "West" }) do L[name].isVisible = false end
		local canvas = Image(sprite.spec)
		canvas:drawSprite(sprite, 1)
		local key = grouped and "multiply_grouped" or "multiply_top"
		local saved, exported = save_state(sprite, key)
		T.ok(saved, key .. ": saved")
		results[key] = { canvas:getPixel(0, 0), exported("South"):getPixel(0, 0) }
		sprite:close()
	end
	local expected = rgba(100, 0, 0)
	T.eq(results.multiply_top, { expected, expected }, "top-level Multiply: canvas, saved")
	T.eq(results.multiply_grouped, { expected, expected }, "grouped Multiply: canvas, saved")
end

------------------------------------------------------------------------
-- Save refuses up front (nothing touched), even inside a caller's transaction, where a failure
-- half-way through could not be rolled back.
do
	-- A direction layer that is a group can't take merges.
	local sprite, L = make_state(4, 8)
	local extra = new_layer(sprite, "Extra")
	extra.stackIndex = 2 -- merges into West: would happen before the North failure
	sprite:newCel(extra, 1, image { { A } }, Point(1, 1))
	L.North.name = "North art"
	local north = sprite:newGroup()
	north.name = "North"
	north.stackIndex = 4 -- West, Extra, East, North{}, North art, South
	T.eq(tree(sprite.layers), "West,Extra,East,North{},North art,South", "group direction layer tree")
	sprite:newCel(sprite.layers[5], 1, image { { C } }, Point(0, 0))
	local before = snapshot(sprite)
	local saved
	app.transaction("Outer", function() saved = save_state(sprite, "group_direction") end)
	T.ok(not saved, "save refuses a group direction layer with merges")
	same_snapshot(snapshot(sprite), before, "refused save inside a transaction leaves the sprite unchanged")
	T.eq(tree(sprite.layers), "West,Extra,East,North{},North art,South", "layers unchanged")
	sprite:close()

	-- A layer inside a merged group named like a direction would become one when moved out.
	sprite = make_state(4, 8)
	local group = sprite:newGroup()
	group.name = "Overlay"
	new_layer(sprite, "East", group)
	before = snapshot(sprite)
	saved = save_state(sprite, "direction_named_child")
	T.ok(not saved, "save refuses a direction-named layer inside a merged group")
	T.eq(tree(sprite.layers), "West,East,North,South,Overlay{East}", "layers unchanged")
	sprite:close()
end

------------------------------------------------------------------------
-- Changing a state's directions saves after its own transaction: the flatten is undone without
-- touching the direction change, and one undo reverts the direction change.
do
	local sprite = Sprite(ImageSpec { width = 8, height = 8, colorMode = ColorMode.RGB })
	app.sprite = sprite
	local south = sprite.layers[1]
	south.name = "South"
	sprite:newCel(south, 1, image { { A } }, Point(2, 2))
	local group = sprite:newGroup()
	group.name = "Shading"
	sprite:newCel(new_layer(sprite, "Shade", group), 1, image { { D } }, Point(3, 3))
	local state_sprite, temp = stub_state_sprite(sprite, "set_dirs", 1)
	T.eq(tree(sprite.layers), "South,Shading{Shade}", "1-dir layers")

	state_sprite.editor:set_state_dirs(state_sprite.state, 4)
	T.eq(state_sprite.state.dirs, 4, "dirs changed")
	T.eq(tree(sprite.layers), "West,East,North,South,Shading{Shade}", "directions added, group kept")
	local exported = load_image_bytes(app.fs.joinPath(temp, "set_dirs.0.bytes")) -- South: top of the export order
	T.eq({ exported:getPixel(2, 2), exported:getPixel(3, 3) }, { A, D }, "South saved with the group merged")

	app.undo()
	T.eq(tree(sprite.layers), "South,Shading{Shade}", "one undo reverts the direction change")
	sprite:close()
end
