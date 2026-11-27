--- Duplicates states and inserts each copy immediately after its source state.
--- @param states State[] The states to duplicate.
function Editor:duplicate_states(states)
	if not self.dmi or #states == 0 then return end

	for _, state in ipairs(states) do
		for _, state_sprite in ipairs(self.open_sprites) do
			if state_sprite.state == state and state_sprite.sprite.isModified then
				app.alert { title = self.title, text = "Save the open iconstate(s) first" }
				return
			end
		end
	end

	local selected = {}
	for _, state in ipairs(states) do
		selected[state] = true
	end

	local original_states = table.clone(self.dmi.states)
	local duplicates = {}
	for _, state in ipairs(original_states) do
		if selected[state] then
			local duplicate, error = libdmi.duplicate_state(state, self.dmi.temp)
			if error or not duplicate then
				app.alert { title = "Error", text = { "Failed to duplicate state", error } }
				return
			end

			duplicates[state] = duplicate
		end
	end

	local states_with_duplicates = {}
	for _, state in ipairs(original_states) do
		table.insert(states_with_duplicates, state)
		local duplicate = duplicates[state]
		if duplicate then
			table.insert(states_with_duplicates, duplicate)
			self.image_cache:load_state(self.dmi, duplicate)
		end
	end

	self.dmi.states = states_with_duplicates
	self.modified = true
	self.selected_states = {}
	self:repaint_states()
	self:gc_open_sprites()
end

--- Duplicates all selected states.
function Editor:duplicate_selected_states()
	self:duplicate_states(self.selected_states)
end

--- Renames selected states using {name} and {index} replacement tokens.
function Editor:mass_rename_states()
	if not self.dmi or #self.selected_states == 0 then return end

	local dialog = Dialog { title = "Mass Rename States" }
	dialog:label { text = "Special: {name}, {index}" }
	dialog:entry {
		id = "pattern",
		label = "Pattern:",
		text = "{name}_{index}",
		focus = true,
	}
	dialog:number {
		id = "start_index",
		label = "Start index:",
		text = "1",
		decimals = 0,
	}
	dialog:button {
		text = "&Rename",
		focus = true,
		onclick = function()
			local pattern = dialog.data.pattern or ""
			local start_index = math.floor(tonumber(dialog.data.start_index) or 1)
			if #pattern == 0 then
				app.alert { title = "Mass Rename States", text = "Enter a rename pattern." }
				return
			end

			local selected = {}
			local selected_set = {}
			for _, state in ipairs(self.selected_states) do
				selected_set[state] = true
			end

			for _, state in ipairs(self.dmi.states) do
				if selected_set[state] then
					table.insert(selected, state)
				end
			end

			for index, state in ipairs(selected) do
				local name = pattern
				name = name:gsub("{name}", function() return state.name end)
				name = name:gsub("{index}", function() return tostring(start_index + index - 1) end)
				state.name = name
			end

			self.modified = true
			self:repaint_states()
			dialog:close()
		end
	}
	dialog:button {
		text = "&Cancel",
		onclick = function() dialog:close() end,
	}
	dialog:show()
end

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

	local new_states, error = libdmi.split_state(state, self.dmi.temp)
	if error or not new_states then
		app.alert { title = "Error", text = { "Failed to split state", error } }
		return
	end

	for _, new_state in ipairs(new_states) do
		table.insert(self.dmi.states, new_state)
		self.image_cache:load_state(self.dmi, new_state)
	end

	-- Mark as modified and remove the original state
	self.modified = true
	self:remove_state(state)
end

--- Splits all selected multi-directional states into individual states.
function Editor:split_selected_states()
	if not self.dmi or #self.selected_states == 0 then return end

	local to_split = {}
	for _, state in ipairs(self.selected_states) do
		if state.dirs > 1 then
			table.insert(to_split, state)
		end
	end

	if #to_split == 0 then
		app.alert { title = "Warning", text = "No selected states have multiple directions to split" }
		return
	end

	for _, state in ipairs(to_split) do
		self:split_state(state)
	end

	self.selected_states = {}
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
	-- Only show frame selection if any selected state has multiple frames
	local hasMultipleFrames = false
	for _, st in ipairs(self.selected_states) do
		if st.frame_count > 1 then
			hasMultipleFrames = true
			break
		end
	end
	if hasMultipleFrames then
		dialog:combobox {
			id = "frame_sel_type",
			label = "Frame Selection:",
			option = FRAME_SEL_TYPES.all_seq,
			options = { FRAME_SEL_TYPES.all_seq, FRAME_SEL_TYPES.first_only, },
		}
	end
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
	local combine = COMBINE_LAYOUTS[combineType]
	if not combine then return end

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

	local combined_state, error = libdmi.combine_states(
		sortedStates,
		self.dmi.temp,
		combinedName,
		combine.layout,
		combine.dirs,
		frameSelType == FRAME_SEL_TYPES.first_only
	)
	if error or not combined_state then
		app.alert { title = "Error", text = { "Failed to combine states", error } }
		return
	end

	table.insert(self.dmi.states, combined_state)
	self.image_cache:load_state(self.dmi, combined_state)
	self.modified = true
	self.selected_states = {}
	self:repaint_states()
	self:gc_open_sprites()
end
