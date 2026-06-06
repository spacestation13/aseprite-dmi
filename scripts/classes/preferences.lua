
Preferences = {}

local DEFAULT_PREVIEW_SIZE = 128
local DEFAULT_PADDING_MULTIPLIER = 1.0

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
	if not Preferences.plugin.preferences.iconstate_padding_multiplier then
		Preferences.plugin.preferences.iconstate_padding_multiplier = DEFAULT_PADDING_MULTIPLIER
	end
end

--- Shows the preferences dialog.
function Preferences.show(plugin)
	local dialog = Dialog {
		title = "DMI Editor Preferences"
	}

	:label { text = "Max Iconstate Preview Size:" }

	:number {
		id = "preview_size",
		text = tostring(Preferences.plugin.preferences.preview_size or DEFAULT_PREVIEW_SIZE),
		decimals = 0,
	}

	:label { text = "Iconstate Padding Multiplier:" }

	:number {
		id = "iconstate_padding_multiplier",
		text = tostring(Preferences.plugin.preferences.iconstate_padding_multiplier or DEFAULT_PADDING_MULTIPLIER),
		decimals = 2,
	}

	:check {
		id = "auto_overwrite",
		label = "",
		text = "Auto-save .dmi to disk when saving a state.",
		selected = Preferences.plugin.preferences.auto_overwrite,
	}

	:check {
		id = "auto_flatten",
		label = "",
		text = "Flatten into dir layers when saving a state.",
		selected = Preferences.plugin.preferences.auto_flatten,
	}

	:check {
		id = "direction_layer_colors",
		label = "",
		text = "Enable dir-based layer colors for states.",
		selected = Preferences.plugin.preferences.direction_layer_colors ~= false,
	}

	:check {
		id = "animated_previews",
		label = "",
		text = "Animate (south) state previews.",
		selected = Preferences.plugin.preferences.animated_previews ~= false,
	}

	:separator {}

	dialog:button {
		text = "&Save",
		focus = true,
		onclick = function()
			local preview_size = math.floor(dialog.data.preview_size or DEFAULT_PREVIEW_SIZE)
			if preview_size < 16 then
				app.alert { title = "Warning", text = "Preview size must be at least 16 pixels" }
				return
			end

			local iconstate_padding_multiplier = dialog.data.iconstate_padding_multiplier or DEFAULT_PADDING_MULTIPLIER
			if iconstate_padding_multiplier < 0.8 then
				app.alert { title = "Warning", text = "Padding multiplier must be at least 0.8" }
				return
			end

			Preferences.plugin.preferences.preview_size = preview_size
			Preferences.plugin.preferences.auto_overwrite = dialog.data.auto_overwrite
			Preferences.plugin.preferences.auto_flatten = dialog.data.auto_flatten
			Preferences.plugin.preferences.direction_layer_colors = dialog.data.direction_layer_colors
			Preferences.plugin.preferences.animated_previews = dialog.data.animated_previews
			Preferences.plugin.preferences.iconstate_padding_multiplier = iconstate_padding_multiplier

			if open_editors then
				for _, editor in ipairs(open_editors) do
					if editor.dmi then
						editor:repaint_states()
					end
				end
			end

		end
	}

	:button {
		text = "&Close",
		onclick = function()
			dialog:close()
		end
	}

	dialog:show {
		wait = false
	}
end

function Preferences.getAutoOverwrite()
	return Preferences.plugin.preferences.auto_overwrite or false
end

function Preferences.getAutoFlatten()
	return Preferences.plugin.preferences.auto_flatten or false
end

function Preferences.getDirectionLayerColors()
	return Preferences.plugin.preferences.direction_layer_colors ~= false
end

function Preferences.getPreviewSize()
	return Preferences.plugin.preferences.preview_size or DEFAULT_PREVIEW_SIZE
end

function Preferences.getAnimatePreviews()
	return Preferences.plugin.preferences.animated_previews ~= false
end

function Preferences.getIconstatePaddingMultiplier()
	return Preferences.plugin.preferences.iconstate_padding_multiplier or DEFAULT_PADDING_MULTIPLIER
end

return Preferences
