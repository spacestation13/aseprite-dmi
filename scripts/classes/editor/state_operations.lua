--- Splits a multi-directional state into individual states, one for each direction.
--- @param state State The state to be split.
function Editor:split_state(state)
	if not self.dmi then return end
	if state.dirs == 1 then
		app.alert { title = "Warning", text = "Cannot split a state with only one direction" }
		return
	end

	-- Check if state is open and modified
	for _, state_sprite in ipairs(self.open_sprites) do
		if state_sprite.state == state then
			if state_sprite.sprite.isModified then
				app.alert { title = self.title, text = "Save the open sprite first" }
				return
			end
			break
		end
	end

	local original_name = state.name
	local direction_names = {
		[4] = { "S", "N", "E", "W" },
		[8] = { "S", "N", "E", "W", "SE", "SW", "NE", "NW" }
	}

	-- Create a new state for each direction
	for i = 1, state.dirs do
		local new_state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp)
		if error then
			app.alert { title = "Error", text = { "Failed to create new state", error } }
			return
		end

		if not new_state then
			app.alert { title = "Error", text = "Failed to create new state" }
			return
		end

		-- Set the new state properties
		new_state.name = original_name .. " - " .. direction_names[state.dirs][i]
		new_state.dirs = 1
		new_state.loop = state.loop
		new_state.rewind = state.rewind
		new_state.movement = state.movement
		new_state.delays = table.clone(state.delays)

		-- Copy the image data for this direction
		-- Layout is frame-major: index = frame * dirs + dir
		local dir = i - 1
		for frame = 0, state.frame_count - 1 do
			local src_index = frame * state.dirs + dir
			local src_path = app.fs.joinPath(self.dmi.temp,
				state.frame_key .. "." .. src_index .. ".bytes")
			local dst_path = app.fs.joinPath(self.dmi.temp,
				new_state.frame_key .. "." .. frame .. ".bytes")

			self:copyImageBytes(src_path, dst_path)
		end

		table.insert(self.dmi.states, new_state)
		self.image_cache:load_state(self.dmi, new_state)
	end

	-- Mark as modified and remove the original state
	self.modified = true
	self:remove_state(state)
	self:repaint_states()
end

--- Combines multiple selected states into one state.
function Editor:combine_selected_states()
	if not self.dmi or #self.selected_states < 2 then
		app.alert { title = self.title, text = "Select at least two states to combine." }
		return
	end
	-- Determine the maximum dirs across selected states to filter options
	local maxDirs = 1
	for _, st in ipairs(self.selected_states) do
		if st.dirs > maxDirs then maxDirs = st.dirs end
	end

	local combineOptions = { COMBINE_TYPES.onedir }
	local defaultOption = COMBINE_TYPES.onedir
	if maxDirs <= 4 then
		table.insert(combineOptions, COMBINE_TYPES.frames_4dir)
		table.insert(combineOptions, COMBINE_TYPES.dirs4_frames)
		defaultOption = COMBINE_TYPES.frames_4dir
	end
	table.insert(combineOptions, COMBINE_TYPES.frames_8dir)
	table.insert(combineOptions, COMBINE_TYPES.dirs8_frames)
	if maxDirs > 4 then
		defaultOption = COMBINE_TYPES.frames_8dir
	end

	local dialog = Dialog { title = "Combine States" }
	dialog:entry {
		id = "combined_name",
		label = "Combined Name:",
		text = self.getCombinedDefaultName(self),
	}
	dialog:combobox {
		id = "combine_type",
		label = "Used Directions:",
		option = defaultOption,
		options = combineOptions,
	}
	dialog:combobox {
		id = "frame_sel_type",
		label = "Frame Selection:",
		option = FRAME_SEL_TYPES.all_seq,
		options = { FRAME_SEL_TYPES.all_seq, FRAME_SEL_TYPES.first_only, },
	}
	dialog:button {
		text = "&OK",
		focus = true,
		onclick = function()
			local combinedName = dialog.data.combined_name or "Combined"
			local combineType = dialog.data.combine_type or COMBINE_TYPES.onedir --[[@as CombineType]]
			local frameSelType = dialog.data.frame_sel_type or FRAME_SEL_TYPES.all_seq --[[@as FrameSelType]]
			dialog:close()
			self:performCombineStates(combinedName, combineType, frameSelType)
		end
	}
	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}
	dialog:show()
end

--- Gets the default name for the combined state based on the selected states.
function Editor:getCombinedDefaultName()
	local function normalize(s) -- Remove _ and - and numbers
		return s:gsub("[-_%d]", "")
	end
	local function commonPrefix(a, b)
		local i = 1
		while i <= #a and i <= #b and a:sub(i, i) == b:sub(i, i) do
			i = i + 1
		end
		return a:sub(1, i - 1)
	end

	local commonBase = normalize(self.selected_states[1].name)
	for i = 2, #self.selected_states do
		commonBase = commonPrefix(commonBase, normalize(self.selected_states[i].name))
		if commonBase == "" then break end
	end
	if commonBase and #commonBase > 2 then -- < 3 char names are not useful
		return commonBase
	else
		return "Combined"
	end
end

--- Combines the selected states into one state, based off of the selected combination type.
--- @param combinedName string The name for the combined state.
--- @param combineType CombineType The type of combination to perform.
--- @param frameSelType FrameSelType The frame selection type.
function Editor:performCombineStates(combinedName, combineType, frameSelType)
	local combined_state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp, combinedName)
	if error or not combined_state then
		app.alert { title = "Error", text = { "Failed to create combined state", error } }
		return
	end

	-- Selected iconstates based on DMI order
	local sortedStates = {}
	for _, state in ipairs(self.dmi.states) do
		for _, selState in ipairs(self.selected_states) do
			if state == selState then
				table.insert(sortedStates, state)
				break
			end
		end
	end

	combined_state.name = combinedName

	local success
	if combineType == COMBINE_TYPES.onedir then
		success = self:combine1direction(combined_state, sortedStates, frameSelType)
	elseif combineType == COMBINE_TYPES.frames_4dir then
		success = self:combineFramesFirst(combined_state, sortedStates, frameSelType, 4)
	elseif combineType == COMBINE_TYPES.frames_8dir then
		success = self:combineFramesFirst(combined_state, sortedStates, frameSelType, 8)
	elseif combineType == COMBINE_TYPES.dirs4_frames then
		success = self:combineDirectionsFirst(combined_state, sortedStates, frameSelType, 4)
	elseif combineType == COMBINE_TYPES.dirs8_frames then
		success = self:combineDirectionsFirst(combined_state, sortedStates, frameSelType, 8)
	end

	if not success then return end

	table.insert(self.dmi.states, combined_state)
	self.image_cache:load_state(self.dmi, combined_state)
	self.modified = true
	self.selected_states = {}
	self:repaint_states()
	self:gc_open_sprites()
end

--- Combines the selected states into one new 1-dir iconstate, taking direction 0 (south) from each.
--- @param combined_state State The combined state to inject all the parts into.
--- @param sortedStates State[] The iconstates to combine.
--- @param frameSelType FrameSelType The frame selection type.
function Editor:combine1direction(combined_state, sortedStates, frameSelType)
	combined_state.dirs = 1
	local framesToUseList, total_frames = self:getFrameUsage(sortedStates, frameSelType)
	combined_state.frame_count = total_frames

	local combinedDelays = {}
	local frameIndex = 0
	for idx, st in ipairs(sortedStates) do
		local framesToUse = framesToUseList[idx]
		for frame = 0, framesToUse - 1 do
			-- Pick direction 0 (south) from each frame of the source state
			local srcIndex = frame * st.dirs
			local srcPath = app.fs.joinPath(self.dmi.temp, st.frame_key .. "." .. srcIndex .. ".bytes")
			local dstPath = app.fs.joinPath(self.dmi.temp, combined_state.frame_key .. "." .. frameIndex .. ".bytes")
			self:copyImageBytes(srcPath, dstPath)
			table.insert(combinedDelays, st.delays[frame + 1] or 1)
			frameIndex = frameIndex + 1
		end
	end
	combined_state.delays = combinedDelays
	return true
end

--- Combines the selected states with frames first, then directions.
--- For example, if 2 selected states are 4-dir with 2 frames, the combined state will be 4-dir with 4 frames.
--- @param combined_state State The combined state to inject all the parts into.
--- @param sortedStates State[] The iconstates to combine.
--- @param frameSelType FrameSelType The frame selection type.
--- @param targetDirs number The number of directions for the combined state (4 or 8).
function Editor:combineFramesFirst(combined_state, sortedStates, frameSelType, targetDirs)
	-- Check that all states have the same number of directions or can be converted
	for _, st in ipairs(sortedStates) do
		if st.dirs > targetDirs then
			app.alert { title = "Error", text = "Cannot combine states with more directions than the target (" .. targetDirs .. ")." }
			return false
		end
	end

	combined_state.dirs = targetDirs

	local framesToUseList, totalFrames = self:getFrameUsage(sortedStates, frameSelType)
	combined_state.frame_count = totalFrames

	local combinedDelays = {}
	local frameOffset = 0
	for idx, st in ipairs(sortedStates) do
		local framesToUse = framesToUseList[idx]
		for frame = 0, framesToUse - 1 do
			for d = 0, targetDirs - 1 do
				local srcIndex
				if d < st.dirs then
					-- If the source has this direction, use it
					srcIndex = (frame * st.dirs) + d
				else
					-- Otherwise, use the first direction (usually south)
					srcIndex = (frame * st.dirs)
				end

				local dstIndex = ((frameOffset + frame) * targetDirs) + d
				local srcPath = app.fs.joinPath(self.dmi.temp, st.frame_key .. "." .. srcIndex .. ".bytes")
				local dstPath = app.fs.joinPath(self.dmi.temp, combined_state.frame_key .. "." .. dstIndex .. ".bytes")
				self:copyImageBytes(srcPath, dstPath)
			end
			table.insert(combinedDelays, st.delays[frame + 1] or 1)
		end
		frameOffset = frameOffset + framesToUse
	end
	combined_state.delays = combinedDelays
	return true
end

--- Combines the selected states with directions first, then frames.
--- Each direction comes from a different state (First→South, Second→North, etc.)
--- If fewer states than directions, the last state fills remaining directions.
--- @param combined_state State The combined state to inject all the parts into.
--- @param sortedStates State[] The iconstates to combine.
--- @param frameSelType FrameSelType The frame selection type.
--- @param targetDirs number The number of directions for the combined state (4 or 8).
function Editor:combineDirectionsFirst(combined_state, sortedStates, frameSelType, targetDirs)
	if #sortedStates < 2 then
		app.alert { title = "Error", text = "Direction-first combination requires at least 2 states." }
		return false
	end

	combined_state.dirs = targetDirs

	-- Determine max frame count across all used states
	local maxFrameCount = 1
	if frameSelType == FRAME_SEL_TYPES.all_seq then
		for i = 1, math.min(#sortedStates, targetDirs) do
			maxFrameCount = math.max(maxFrameCount, sortedStates[i].frame_count)
		end
	end
	combined_state.frame_count = maxFrameCount

	-- Build delays from the first state (South direction source)
	local firstState = sortedStates[1]
	local combinedDelays = {}
	for f = 1, maxFrameCount do
		table.insert(combinedDelays, firstState.delays[f] or 1)
	end
	combined_state.delays = combinedDelays

	-- Iterate over each target direction and assign a source state
	for d = 0, targetDirs - 1 do
		-- Clamp to last state if fewer states than directions
		local stateIdx = math.min(d + 1, #sortedStates)
		local currentState = sortedStates[stateIdx]

		-- Pick matching direction from source, or dir 0 if source has fewer dirs
		local srcDir = math.min(d, currentState.dirs - 1)

		local frameCount = (frameSelType == FRAME_SEL_TYPES.first_only) and 1 or currentState.frame_count

		for frame = 0, maxFrameCount - 1 do
			-- Repeat last frame if source has fewer frames
			local srcFrame = math.min(frame, frameCount - 1)
			local srcIndex = srcFrame * currentState.dirs + srcDir
			local dstIndex = frame * targetDirs + d

			local srcPath = app.fs.joinPath(self.dmi.temp, currentState.frame_key .. "." .. srcIndex .. ".bytes")
			local dstPath = app.fs.joinPath(self.dmi.temp, combined_state.frame_key .. "." .. dstIndex .. ".bytes")
			self:copyImageBytes(srcPath, dstPath)
		end
	end

	return true
end

--- Gets the number of frames to use for each state based on the selected frame selection type.
--- @param sortedStates State[] The states to use.
--- @param frameSelType FrameSelType The frame selection type.
function Editor:getFrameUsage(sortedStates, frameSelType)
	local framesToUseList = {}
	local totalFrames = 0
	for _, st in ipairs(sortedStates) do
		local useCount = ((frameSelType == FRAME_SEL_TYPES.first_only) and 1) or st.frame_count
		table.insert(framesToUseList, useCount)
		totalFrames = totalFrames + useCount
	end
	return framesToUseList, totalFrames
end

--- Copies the image bytes from the source path to the destination path.
--- @param srcPath string The source path
--- @param dstPath string The destination path
function Editor:copyImageBytes(srcPath, dstPath)
	local src_file = io.open(srcPath, "rb")
	if src_file then
		local content = src_file:read("*all")
		src_file:close()
		local dst_file = io.open(dstPath, "wb")
		if dst_file then
			dst_file:write(content)
			dst_file:close()
		end
	end
end
