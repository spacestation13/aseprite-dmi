-- This file defines split_state and combine_selected_states for the Editor.
-- Assumes global Editor is already defined.

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
		local frames_per_dir = state.frame_count
		local start_frame = (i - 1) * frames_per_dir

		for frame = 1, frames_per_dir do
			local src_path = app.fs.joinPath(self.dmi.temp, state.frame_key .. "." .. tostring(start_frame + frame - 1) .. ".bytes")
			local dst_path = app.fs.joinPath(self.dmi.temp, new_state.frame_key .. "." .. tostring(frame - 1) .. ".bytes")

			-- Copy the image file
			local src_file = io.open(src_path, "rb")
			if src_file then
				local content = src_file:read("*all")
				src_file:close()

				local dst_file = io.open(dst_path, "wb")
				if dst_file then
					dst_file:write(content)
					dst_file:close()
				end
			end
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
	if not self.dmi or not self.selected_states or #self.selected_states < 2 then
		app.alert { title = self.title, text = "Select at least two states to combine." }
		return
	end
	local combined_state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp)
	if error or (not combined_state) then
		app.alert { title = "Error", text = { "Failed to create combined state", error } }
		return
	end

	-- Normalize a string by removing dashes, underscores, and numbers.
	local function normalize(s)
		return s:gsub("[-_%d]", "")
	end

	-- Compute longest common prefix between two strings.
	local function commonPrefix(a, b)
		local len = math.min(#a, #b)
		local prefix = ""
		for i = 1, len do
			if a:sub(i, i) == b:sub(i, i) then
				prefix = prefix .. a:sub(i, i)
			else
				break
			end
		end
		return prefix
	end

	local commonBase = normalize(self.selected_states[1].name)
	for i = 2, #self.selected_states do
		commonBase = commonPrefix(commonBase, normalize(self.selected_states[i].name))
		if commonBase == "" then break end
	end
	if commonBase and #commonBase > 0 then
		combined_state.name = commonBase
	else
		combined_state.name = "Combined"
	end

	-- Reorder selected states in the order they appear in the dmi.
	local sortedStates = {}
	for _, state in ipairs(self.dmi.states) do
		for _, sel in ipairs(self.selected_states) do
			if state == sel then
				table.insert(sortedStates, state)
				break
			end
		end
	end

	combined_state.frame_count = #sortedStates
	combined_state.delays = {}
	-- For each state in sorted order, copy its preview image as a new frame.
	for i, state in ipairs(sortedStates) do
		local preview = self.image_cache:get(state.frame_key)
		if not preview then
			app.alert { title = "Error", text = "Preview image missing for state: " .. (state.name or "unknown") }
			return
		end
		save_image_bytes(preview, app.fs.joinPath(self.dmi.temp, combined_state.frame_key .. "." .. (i - 1) .. ".bytes"))
		combined_state.delays[i] = 100  -- set default delay
	end
	table.insert(self.dmi.states, combined_state)
	self.image_cache:load_state(self.dmi, combined_state)
	self.modified = true
	self:repaint_states()
	-- Clear selection after combining.
	self.selected_states = {}
	app.alert { title = self.title, text = "States have been combined." }
end
