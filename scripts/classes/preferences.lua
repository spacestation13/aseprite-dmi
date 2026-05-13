
Preferences = {}

local DEFAULT_PREVIEW_SIZE = 128

--- Initializes the Preferences
function Preferences.initialize(plugin)
	-- Store the plugin object in the Preferences class
	Preferences.plugin = plugin

	-- Initialize default preferences if not set
	if not Preferences.plugin.preferences.auto_overwrite then
		Preferences.plugin.preferences.auto_overwrite = false
	end
	if not Preferences.plugin.preferences.auto_flatten then
		Preferences.plugin.preferences.auto_flatten = true
	end
	if Preferences.plugin.preferences.direction_layer_colors == nil then
		Preferences.plugin.preferences.direction_layer_colors = true
	end
	if not Preferences.plugin.preferences.preview_size then
		Preferences.plugin.preferences.preview_size = DEFAULT_PREVIEW_SIZE
	end
	if Preferences.plugin.preferences.animated_previews == nil then
		Preferences.plugin.preferences.animated_previews = true
	end
end

--- Shows the preferences dialog.
function Preferences.show(plugin)
	local dialog = Dialog {
		title = "DMI Editor Preferences"
	}

	dialog:label {
		text = "Maximum Preview Size:"
	}
	dialog:number {
		id = "preview_size",
		text = tostring(Preferences.plugin.preferences.preview_size or DEFAULT_PREVIEW_SIZE),
		decimals = 0,
	}

	dialog:newrow()

	dialog:check {
		id = "auto_overwrite",
		text = "Auto-save .dmi to disk when saving an iconstate.",
		selected = Preferences.plugin.preferences.auto_overwrite,
	}

	dialog:newrow()

	dialog:check {
		id = "auto_flatten",
		text = "Flatten layers downwards into directional layers when saving an iconstate.",
		selected = Preferences.plugin.preferences.auto_flatten,
	}

	dialog:newrow()

	dialog:check {
		id = "direction_layer_colors",
		text = "Apply direction-based layer colors to states.",
		selected = Preferences.plugin.preferences.direction_layer_colors ~= false,
	}

	dialog:newrow()

	dialog:check {
		id = "animated_previews",
		text = "Animate (south)state previews.",
		selected = Preferences.plugin.preferences.animated_previews ~= false,
	}

	dialog:button {
		text = "&OK",
		focus = true,
		onclick = function()
			local preview_size = math.floor(dialog.data.preview_size or DEFAULT_PREVIEW_SIZE)
			if preview_size < 16 then
				app.alert { title = "Warning", text = "Preview size must be at least 16 pixels" }
				return
			end

			Preferences.plugin.preferences.preview_size = preview_size
			Preferences.plugin.preferences.auto_overwrite = dialog.data.auto_overwrite
			Preferences.plugin.preferences.auto_flatten = dialog.data.auto_flatten
			Preferences.plugin.preferences.direction_layer_colors = dialog.data.direction_layer_colors
			Preferences.plugin.preferences.animated_previews = dialog.data.animated_previews

			if open_editors then
				for _, editor in ipairs(open_editors) do
					if editor.dmi then
						editor:repaint_states()
					end
				end
			end

			dialog:close()
		end
	}

	dialog:button {
		text = "&Cancel",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show {
		wait = false
	}
end

--- Gets whether auto-overwrite is enabled
function Preferences.getAutoOverwrite()
	return Preferences.plugin.preferences.auto_overwrite or false
end

--- Gets whether auto-flatten is enabled
function Preferences.getAutoFlatten()
	return Preferences.plugin.preferences.auto_flatten or false
end

--- Gets whether direction layer coloring is enabled
function Preferences.getDirectionLayerColors()
	return Preferences.plugin.preferences.direction_layer_colors ~= false
end

function Preferences.getPreviewSize()
	return Preferences.plugin.preferences.preview_size or DEFAULT_PREVIEW_SIZE
end

function Preferences.getAnimatePreviews()
	return Preferences.plugin.preferences.animated_previews ~= false
end

return Preferences
