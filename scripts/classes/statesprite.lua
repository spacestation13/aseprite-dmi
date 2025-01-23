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

--- Saves the state sprite by exporting each layer as a separate image file.
--- @return boolean boolean true if the save operation is successful, false otherwise.
function StateSprite:save()
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

	-- Store original layers if we need to flatten
	local original_layers = nil
	if Preferences.getAutoFlatten() then
		original_layers = {}
		for _, layer in ipairs(self.sprite.layers) do
			table.insert(original_layers, layer)
			app.alert("Found layer: " .. layer.name)
		end

		-- Start from top layer, work downwards
		for i = 1, #self.sprite.layers do
			local layer = self.sprite.layers[i]
			if table.index_of(DIRECTION_NAMES, layer.name) == 0 then
				app.alert("Found non-directional layer: " .. layer.name)
				-- Find nearest directional layer above this one
				local found_target = false
				for j = i - 1, 1, -1 do -- (this is an inverted list)
					if table.index_of(DIRECTION_NAMES, self.sprite.layers[j].name) > 0 then
						app.alert("Found target directional layer: " .. self.sprite.layers[j].name)
						-- Select the layer to merge
						app.activeLayer = layer
						app.alert("Set active layer to: " .. layer.name)
						app.command.MergeDownLayer()
						app.alert("Merged down layer")
						found_target = true
						break
					end
				end
				if not found_target then
					app.alert("No target directional layer found below " .. layer.name)
					break -- No more directional layers below
				end
			end
		end
	else
		app.alert("Auto-flatten is disabled")
	end

	self.state.frame_count = #self.sprite.frames
	self.state.delays = {}

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

				save_image_bytes(image, app.fs.joinPath(self.editor.dmi.temp, self.state.frame_key .. "." .. index .. ".bytes"))

				if frame_index == 1 and layer_index == #self.sprite.layers then
					self.editor.image_cache:set(self.state.frame_key, image)
				end
			end
			index = index + 1
		end
	end
	self.editor:repaint_states()
	self.editor.modified = true

	-- Restore original layers if we flattened
	if original_layers then
		-- Undo all the merges
		while #original_layers > #self.sprite.layers do
			app.command.Undo()
		end
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
