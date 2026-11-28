--- Represents sprite of a state.
--- @class StateSprite
--- @field editor Editor The editor object.
--- @field dmi Dmi The DMI file object.
--- @field state State The state of the sprite.
--- @field sprite Sprite The sprite object.
--- @field transparentColor Color The transparent color of the sprite.
StateSprite = {}
StateSprite.__index = StateSprite

--- Creates a new instance of the StateSprite class.
--- @param editor Editor The editor object.
--- @param state State The state of the sprite.
--- @param sprite Sprite The sprite object.
--- @param transparentColor Color The transparent color of the sprite.
--- @return StateSprite statesprite The newly created StateSprite object.
function StateSprite.new(editor, dmi, state, sprite, transparentColor)
	local self = setmetatable({}, StateSprite)

	self.editor = editor
	self.dmi = dmi
	self.state = state
	self.sprite = sprite
	self.transparentColor = transparentColor

	return self
end

--- Image layers inside a group, bottom-up, nested groups included.
--- @param group Layer
--- @param out Layer[]
--- @return Layer[]
local function image_descendants(group, out)
	for _, layer in ipairs(group.layers) do
		if layer.isGroup then
			image_descendants(layer, out)
		elseif layer.isImage and not layer.isTilemap then
			table.insert(out, layer)
		end
	end
	return out
end

--- Whether any layer (or a layer inside a group) is a tilemap.
--- @param layers Layer[]
--- @return boolean
local function has_tilemap(layers)
	for _, layer in ipairs(layers) do
		if layer.isTilemap or (layer.isGroup and has_tilemap(layer.layers)) then
			return true
		end
	end
	return false
end

--- Layers that auto-flatten merges into each direction layer on save: every top-level
--- non-direction layer merges down into the nearest direction layer below it, bottom-up (see
--- the flatten in StateSprite:save). A group counts as the image layers inside it, in order:
--- Aseprite renders a group's layers as siblings (no group opacity or blend mode) and Save
--- moves them out of the group before merging. Empty when auto-flatten is off.
--- @param sprite Sprite
--- @return table<string, Layer[]> sources Direction name -> layers merged into it, bottom-up.
--- @return table<string, Layer> targets Direction name -> the direction layer they merge into.
function StateSprite.flatten_sources(sprite)
	local sources, targets = {}, {}
	if not Preferences.getAutoFlatten() then return sources, targets end
	local current = nil
	for _, layer in ipairs(sprite.layers) do
		if table.index_of(DIRECTION_NAMES, layer.name) > 0 then
			current = {}
			if not sources[layer.name] then
				sources[layer.name], targets[layer.name] = current, layer
			end
		elseif current then
			if layer.isGroup then
				image_descendants(layer, current)
			else
				table.insert(current, layer)
			end
		end
	end
	return sources, targets
end

--- Why auto-flatten can't run, checked before the sprite is touched: every direction layer
--- receiving merges must be a regular image layer, and no layer inside a merged group may
--- be named after a direction (it would become one once moved out of the group).
--- @param sprite Sprite
--- @return string|nil error
local function flatten_error(sprite)
	local sources, targets = StateSprite.flatten_sources(sprite)
	for name, merged in pairs(sources) do
		local target = targets[name]
		if #merged > 0 and (not target.isImage or target.isTilemap) then
			return "Layers above \"" .. name .. "\" can't be merged into it: direction layers must be regular image layers, not groups."
		end
		for _, layer in ipairs(merged) do
			if table.index_of(DIRECTION_NAMES, layer.name) > 0 then
				return "The layer \"" .. layer.name .. "\" inside a group is named like a direction: rename it or move it out of the group."
			end
		end
	end
end

--- Moves the image layers of every group above a direction layer out to the group's place
--- (bottom-up) and deletes the group, so Merge Down merges each of them like a top-level
--- layer (it can't merge groups). Call inside a transaction.
--- @param sprite Sprite
local function ungroup_merged_groups(sprite)
	local groups = {}
	local above_direction = false
	for _, layer in ipairs(sprite.layers) do
		if table.index_of(DIRECTION_NAMES, layer.name) > 0 then
			above_direction = true
		elseif above_direction and layer.isGroup then
			table.insert(groups, layer)
		end
	end
	for _, group in ipairs(groups) do
		for _, layer in ipairs(image_descendants(group, {})) do
			layer.parent = sprite
			layer.stackIndex = group.stackIndex -- below the group, above the layers moved before
		end
		sprite:deleteLayer(group)
	end
end

--- Saves the state sprite by exporting each layer as a separate image file.
--- @return boolean boolean true if the save operation is successful, false otherwise.
function StateSprite:save()
	if has_tilemap(self.sprite.layers) then
		app.alert {
			title = self.editor.title,
			text = "Tilemap layers are not supported in DMI files. Please convert or remove them before saving."
		}
		return false
	end

	if #self.sprite.layers < self.state.dirs then
		app.alert { title = self.editor.title, text = "There must be at least " .. math.floor(self.state.dirs) .. " layers matching direction names" }
		return false
	end

	local matches = {}
	local duplicates = {}

	for _, layer in ipairs(self.sprite.layers) do
		local direction = table.index_of(DIRECTION_NAMES, layer.name)
		if direction > 0 and direction <= self.state.dirs then
			if matches[layer.name] then
				table.insert(duplicates, layer.name)
			else
				matches[layer.name] = true
			end
		end
	end

	if #duplicates > 0 then
		app.alert {
			title = self.editor.title,
			text = {
				"There must be only one layer for each direction",
				table.concat_with_and(duplicates) .. ((#duplicates > 1) and " are " or " is ") .. "duplicated"
			}
		}

		return false
	end

	if table.keys_len(matches) ~= self.state.dirs then
		local missing = {}

		for i, direction in ipairs(DIRECTION_NAMES) do
			if i <= self.state.dirs then
				if not matches[direction] then
					table.insert(missing, direction)
				end
			else
				break
			end
		end

		app.alert {
			title = self.editor.title,
			text = {
				"There must be one layer for each direction",
				table.concat_with_and(missing) .. ((#missing > 1) and " are " or " is ") .. "missing"
			}
		}

		return false
	end

	-- Store original layers if we need to auto-flatten
	-- And only if there's layers that aren't the magic directional names
	local original_layers = nil
	local hasNonDirectional = false
	for _, layer in ipairs(self.sprite.layers) do
		if table.index_of(DIRECTION_NAMES, layer.name) == 0 then
			hasNonDirectional = true
			break
		end
	end
	if Preferences.getAutoFlatten() and hasNonDirectional then
		-- Fail before touching the sprite: a failed flatten inside a caller's transaction
		-- would not be rolled back.
		local err = flatten_error(self.sprite)
		if err then
			app.alert { title = self.editor.title, text = { "Can't flatten the layers into directions.", err } }
			return false
		end

		original_layers = {}
		for _, layer in ipairs(self.sprite.layers) do
			table.insert(original_layers, layer)
		end

		local ok
		ok, err = pcall(app.transaction,
			"Flatten Layers (DMI Editor)",
			function()
				ungroup_merged_groups(self.sprite)
				-- Process each directional layer, rebuilding layer list after each merge
				local i = 1
				while i <= #self.sprite.layers do
					local layer = self.sprite.layers[i]
					if table.index_of(DIRECTION_NAMES, layer.name) > 0 then
						-- Look for any non-directional layers above this one
						local merged = false
						for j = i + 1, #self.sprite.layers do
							local above_layer = self.sprite.layers[j]
							if table.index_of(DIRECTION_NAMES, above_layer.name) == 0 then
								local count = #self.sprite.layers
								app.layer = above_layer
								app.command.MergeDownLayer()
								if #self.sprite.layers == count then
									-- Merge Down refused (flatten_error should have caught why):
									-- stop instead of retrying forever.
									error("Can't merge \"" .. above_layer.name .. "\" into \"" ..
										self.sprite.layers[j - 1].name .. "\".", 0)
								end
								merged = true
								break
							end
						end
						-- Don't increment i if we merged, as we need to check the same position again
						if not merged then
							i = i + 1
						end
					else
						i = i + 1
					end
				end
			end
		)
		if not ok then
			app.alert { title = self.editor.title, text = { "Auto-flatten failed.", tostring(err) } }
			return false
		end
	end

	self.state.frame_count = #self.sprite.frames
	self.state.delays = {}

	-- Clear the old cache entry so stale frames from a prior frame count don't linger.
	self.editor.image_cache:remove(self.state.frame_key)

	local save_error = nil
	local index = 0
	for frame_index, frame in ipairs(self.sprite.frames) do
		if #self.sprite.frames > 1 then
			self.state.delays[frame_index] = frame.duration * 10
		end
		for layer_index = #self.sprite.layers, 1, -1 do
			local layer = self.sprite.layers[layer_index]
			if table.index_of(DIRECTION_NAMES, layer.name) > 0 then
				local cel = layer:cel(frame.frameNumber)
				local image = Image(ImageSpec {
					width = self.editor.dmi.width,
					height = self.editor.dmi.height,
					colorMode = ColorMode.RGB,
					transparentColor = app.pixelColor.rgba(self.transparentColor.red, self.transparentColor.green, self.transparentColor.blue, self.transparentColor.alpha)
				})

				if cel and cel.image then
					image:drawImage(cel.image, cel.position)
				end

				local path = app.fs.joinPath(self.editor.dmi.temp, self.state.frame_key .. "." .. index .. ".bytes")
				local _, frame_error = libdmi.save_frame_bytes(path, image.width, image.height, image.bytes)
				save_error = save_error or frame_error

				-- Update the preview cache for the south (top-layer) direction of each frame
				-- so animated previews reflect the saved content immediately.
				if layer_index == #self.sprite.layers then
					self.editor.image_cache:set(self.state.frame_key, image, frame_index)
				end
			end
			index = index + 1
		end
	end
	self.editor:repaint_states()
	self.editor.modified = true

	-- Restore original layers if we flattened by undoing the transaction from above
	if original_layers then
		app.command.Undo()
	end

	if save_error then
		app.alert { title = self.editor.title, text = { "Failed to save the state", save_error } }
		return false
	end

	return true
end

--- Displays a warning dialog asking the user to save changes to the sprite before closing.
--- @return 0|1|2 result 0 if the user cancels the operation, 1 if the user saves the file, 2 if the user doesn't save the file.
function StateSprite:save_warning()
	local result = 0

	local dialog = Dialog {
		title = "DMI Editor - Warning",
	}

	local unnamed = false

	if #self.state.name == 0 then
		unnamed = true
	end

	local text = "Save changes to the iconstate " .. (not unnamed and ('"' .. self.state.name .. '" ') or '') .. 'of "' .. app.fs.fileName(self.editor:path()) .. '" before closing?'
	local lines = string.split_lines(text, 36)

	for i, line in ipairs(lines) do
		dialog:newrow()
		dialog:label { text = line, focus = i == 1 }
	end

	dialog:canvas { height = 1 }

	dialog:button {
		text = "&Save",
		focus = true,
		onclick = function()
			if self:save() then
				self.sprite:saveAs(self.sprite.filename)
				result = 1
				dialog:close()
			end
		end
	}

	dialog:button {
		text = "Do&n't Save",
		onclick = function()
			result = 2
			dialog:close()
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	self.editor.switch_tab(self.sprite)

	dialog:show()

	return result
end
