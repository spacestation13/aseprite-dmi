--- @diagnostic disable: lowercase-global

--- After command listener.
--- @type number|nil
local after_listener = nil

--- Before command listener.
--- @type number|nil
local before_listener = nil

--- Aseprite is exiting.
local exiting = false

--- Open editors.
--- @type Editor[]
open_editors = {}

--- Lib module.
--- @type LibDmi
libdmi = nil

--- Tracks if we're doing a no-editor DMI open
local opening_dmi_noeditor = false

--- Initializes the plugin. Called when the plugin is loaded.
--- @param plugin Plugin The plugin object.
function init(plugin)
	if app.apiVersion < 27 then
		return app.alert("This script requires Aseprite v1.3.3 or above")
	end

	if not app.isUIAvailable then
		return
	end

	-- Initialize Preferences
	Preferences.initialize(plugin)

	after_listener = app.events:on("aftercommand", function(ev)
		if ev.name == "OpenFile" then
			-- Skip DMI editor if coming from Raw Open command
			if app.sprite and app.sprite.filename:ends_with(".dmi") and not opening_dmi_noeditor then
				local filename = app.sprite.filename
				app.command.CloseFile { ui = false }
				loadlib(plugin.path)

				Editor.new(DIALOG_NAME, filename)
			end
			-- Reset the flag after handling the OpenFile event
			opening_dmi_noeditor = false
		elseif ev.name == "Exit" then
			exiting = true
		end
	end)

	before_listener = app.events:on("beforecommand", function(ev)
		if ev.name == "Exit" then
			local stopped = false
			if #open_editors > 0 then
				local editors = table.clone(open_editors) --[[@as Editor[] ]]
				for _, editor in ipairs(editors) do
					if not editor:close(false) and not stopped then
						stopped = true
						ev.stopPropagation()
					end
				end
			end
		end
	end)

	local is_state_sprite = function()
		for _, editor in ipairs(open_editors) do
			for _, sprite in ipairs(editor.open_sprites) do
				if app.sprite == sprite.sprite then
					return sprite
				end
			end
		end
		return nil
	end

	plugin:newMenuSeparator {
		group = "file_import",
	}

	plugin:newMenuGroup {
		id = "dmi_editor",
		title = DIALOG_NAME,
		group = "file_import",
	}

	plugin:newCommand {
		id = "dmi_new_file",
		title = "New DMI File",
		group = "dmi_editor",
		onclick = function()
			Editor.new_file(plugin.path)
		end,
	}

	plugin:newCommand {
		id = "dmi_raw_open",
		title = "Open DMI (No Editor - Will Delete DMI Metadata!!)",
		group = "dmi_editor",
		onclick = function()
			opening_dmi_noeditor = true
			app.command.OpenFile()
		end,
	}

	plugin:newMenuSeparator {
		group = "dmi_editor",
	}

	plugin:newCommand {
		id = "dmi_expand",
		title = "Expand",
		group = "dmi_editor",
		onclick = function()
			local state_sprite = is_state_sprite()
			if state_sprite then
				state_sprite.editor:expand()
			end
		end,
		onenabled = function()
			return is_state_sprite() and true or false
		end,
	}

	plugin:newCommand {
		id = "dmi_resize",
		title = "Resize",
		group = "dmi_editor",
		onclick = function()
			local state_sprite = is_state_sprite()
			if state_sprite then
				state_sprite.editor:resize()
			end
		end,
		onenabled = function()
			return is_state_sprite() and true or false
		end,
	}

	plugin:newCommand {
		id = "dmi_crop",
		title = "Crop",
		group = "dmi_editor",
		onclick = function()
			local state_sprite = is_state_sprite()
			if state_sprite then
				state_sprite.editor:crop()
			end
		end,
		onenabled = function()
			return is_state_sprite() and true or false
		end,
	}

	plugin:newMenuSeparator {
		group = "dmi_editor",
	}

	plugin:newCommand {
		id = "dmi_preferences",
		title = "Preferences",
		group = "dmi_editor",
		onclick = function()
			Preferences.show(plugin)
		end,
	}

	plugin:newCommand {
		id = "dmi_report_issue",
		title = "Report Issue",
		group = "dmi_editor",
		onclick = function()
			loadlib(plugin.path)
			libdmi.open_repo("issues")
		end,
	}

	plugin:newCommand {
		id = "dmi_releases",
		title = "Releases",
		group = "dmi_editor",
		onclick = function()
			loadlib(plugin.path)
			libdmi.open_repo("releases")
		end,
	}
end

--- Exits the plugin. Called when the plugin is removed or Aseprite is closed.
--- @param plugin Plugin The plugin object.
function exit(plugin)
	if not exiting and libdmi then
		print(
			"To uninstall the extension, re-open the Aseprite without using the extension and try again.\nThis happens beacuse once the library (dll) is loaded, it cannot be unloaded.\n")
		return
	end
	if after_listener then
		app.events:off(after_listener)
		after_listener = nil
	end
	if before_listener then
		app.events:off(before_listener)
		before_listener = nil
	end
	if #open_editors > 0 then
		local editors = table.clone(open_editors) --[[@as Editor[] ]]
		for _, editor in ipairs(editors) do
			editor:close(false, true)
		end
	end
	if libdmi then
		libdmi.remove_dir(TEMP_DIR, true)
		if libdmi.exists(TEMP_DIR) and libdmi.instances() == 1 then
			libdmi.remove_dir(TEMP_DIR, false)
		end
		libdmi = nil
	end
end

--- Loads the DMI library.
--- @param plugin_path string Path where the extension is installed.
function loadlib(plugin_path)
    if not app.os.windows then
        local success, err = compile_lua(plugin_path)
        if not success then
            app.alert {
                title = "Lua Compilation Error",
                text = err or "Unknown error during Lua compilation",
            }
            return
        end

        -- Update library path based on OS
        if app.os.macos then
            package.cpath = package.cpath .. ";?.dylib"
            LUA_LIB = "liblua.dylib"
        else
            package.cpath = package.cpath .. ";?.so"
            LUA_LIB = "liblua.so"
        end
    end

    -- Load Lua library
    if LUA_LIB then
        local lua_path = app.fs.joinPath(plugin_path, LUA_LIB)
        local success, err = package.loadlib(lua_path, "")
        if not success then
            app.alert {
                title = "Lua Library Error",
                text = "Failed to load Lua library: " .. (err or "unknown error"),
            }
            return
        end
    end

    -- Load DMI library
    local dmi_path = app.fs.joinPath(plugin_path, DMI_LIB)
    local success, lib = pcall(package.loadlib, dmi_path, "luaopen_dmi_module")
    if not success then
        app.alert {
            title = "DMI Library Error",
            text = "Failed to load DMI library: " .. (lib or "unknown error"),
        }
        return
    end

    libdmi = lib()
    general_check()
end


--- General checks.
function general_check()
	if libdmi.check_update() then
		update_popup()
	end
end

--- Shows the update alert popup.
function update_popup()
	local dialog = Dialog {
		title = "Update Available",
	}

	dialog:label {
		focus = true,
		text = "An update is available for " .. DIALOG_NAME .. ".",
	}

	dialog:newrow()

	dialog:label {
		text = "Would you like to download it now?",
	}

	dialog:newrow()

	dialog:label {
		text = "Pressing \"OK\" will open the releases page in your browser.",
	}

	dialog:canvas { height = 1 }

	dialog:button {
		focus = true,
		text = "&OK",
		onclick = function()
			libdmi.open_repo("issues")
			dialog:close()
		end,
	}

	dialog:button {
		text = "&Later",
		onclick = function()
			dialog:close()
		end,
	}

	dialog:show()
end
