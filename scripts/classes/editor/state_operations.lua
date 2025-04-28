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
	if not self.dmi or not self.selected_widgets or #self.selected_widgets < 2 then
		app.alert { title = self.title, text = "Select at least two states to combine." }
		return
	end
	local dialog = Dialog { title = "Combine States" }
	dialog:entry {
		id = "combined_name",
		label = "Combined Name:",
		text = self.getCombinedDefaultName(self),
	}
	dialog:combobox {
		id = "combine_type",
		label = "Combine Method:",
		option = COMBINE_TYPES.onedir,
		options = { COMBINE_TYPES.onedir },
	}
	dialog:button {
		text = "&OK",
		focus = true,
		onclick = function()
			local combinedName = dialog.data.combined_name or "Combined"
			local combineType = dialog.data.combine_type or COMBINE_TYPES.onedir
			dialog:close()
			self:performCombineStates(combinedName, combineType)
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

-- Add a new function to compute the default combined name
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

	local commonBase = normalize(self.selected_widgets[1].state.name)
	for i = 2, #self.selected_widgets do
		commonBase = commonPrefix(commonBase, normalize(self.selected_widgets[i].state.name))
		if commonBase == "" then break end
	end
	if commonBase and #commonBase > 2 then -- <3 char names are not useful
		return commonBase
	else
		return "Combined"
	end
end

-- Modified performCombineStates function to use combine1direction
function Editor:performCombineStates(combinedName, combineType)
	local combined_state, error = libdmi.new_state(self.dmi.width, self.dmi.height, self.dmi.temp)
	if error or not combined_state then
		app.alert { title = "Error", text = { "Failed to create combined state", error } }
		return
	end

	-- Reorder selected states based on DMI order
	local sortedStates = {}
	for _, state in ipairs(self.dmi.states) do
		for _, selWidget in ipairs(self.selected_widgets) do
			if state == selWidget.state then
				table.insert(sortedStates, state)
				break
			end
		end
	end

	combined_state.name = combinedName
	if combineType == COMBINE_TYPES.onedir then
		if not self:combine1direction(combined_state, sortedStates) then
			return
		end
	else
		-- Future expansion placeholder for other combine types.
	end
	table.insert(self.dmi.states, combined_state)
	self.image_cache:load_state(self.dmi, combined_state)
	self.modified = true
	self.selected_widgets = {}
	self:repaint_states()
end

function Editor:combine1direction(combined_state, sortedStates)
	combined_state.frame_count = #sortedStates
	for i, state in ipairs(sortedStates) do
		local preview = self.image_cache:get(state.frame_key)
		if not preview then
			app.alert { title = "Error", text = "Preview image missing for state: " .. (state.name or "unknown") }
			return false
		end
		save_image_bytes(preview, app.fs.joinPath(self.dmi.temp, combined_state.frame_key .. "." .. (i - 1) .. ".bytes"))
	end
	return true
end
