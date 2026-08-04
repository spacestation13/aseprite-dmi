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


--- Initializes the plugin. Called when the plugin is loaded.
--- @param plugin Plugin The plugin object.
function init(plugin)
	if not app.isUIAvailable then
		return
	end

	local min_version = Version("1.3.18")
	local v = app.version
	if v < min_version then
		return app.alert { title = DIALOG_NAME, text = "This extension requires Aseprite v1.3.18 or later." }
	end

	-- Initialize Preferences
	Preferences.initialize(plugin)
	RawDmi.initialize(plugin.path)

	-- Load the native library early so newFileFormat callbacks can use it
	loadlib(plugin.path)

	-- Register .dmi as a custom file format
	plugin:newFileFormat {
		name = "Dream Maker Image",
		extension = "dmi",
		onload = function(ev)
			-- Return a minimal placeholder sprite. The DMI editor reads the
			-- file itself; raw mode bypasses this handler entirely by opening
			-- a temp .png copy with Aseprite's native PNG loader.
			return Sprite(1, 1)
		end,
		onsave = function(ev)
			if RawDmi.is_sprite(ev.sprite) then
				return RawDmi.save(ev.sprite, ev.filename)
			end
			-- Non-raw .dmi saves shouldn't happen normally (the editor manages its own saves).
			-- Refuse the save to prevent silent DMI metadata loss.
			app.alert { title = DIALOG_NAME, text = "Use the DMI Editor to save .dmi files with metadata preserved." }
			return false
		end,
	}

	after_listener = app.events:on("aftercommand", function(ev)
		if ev.name == "OpenFile" then
			-- Collect all .dmi placeholder sprites first, then close them, then create editors.
			local filenames = {}
			local processed = 0
			while app.sprite and app.sprite.filename:ends_with(".dmi")
				and not RawDmi.is_sprite(app.sprite) do
				processed = processed + 1
				if processed > 100 then break end -- safety limit

				local filename = app.sprite.filename
				app.command.CloseFile { ui = false }

				-- Prevent duplicate editor instances for the same file
				local normalized = string.lower(filename)
				local found = false
				for _, editor in ipairs(open_editors) do
					if not editor.closed and string.lower(editor:path()) == normalized then
						editor:repaint()
						found = true
						break
					end
				end

				if not found then
					table.insert(filenames, filename)
				end
			end

			-- Now create editors outside the close loop
			for _, filename in ipairs(filenames) do
				Editor.new(DIALOG_NAME, filename)
			end
		elseif ev.name == "Exit" then
			exiting = true
		end

		-- Dispatch to open editors.  We do NOT register per-editor
		-- listeners because calling app.events:on() from inside an
		-- event callback can reallocate Aseprite's internal callback
		-- vector while Events::call is iterating it (use-after-free).
		for _, editor in ipairs(open_editors) do
			if not editor.closed then
				editor:onaftercommand(ev)
			end
		end
	end)

	local function active_state_sprite()
		for _, editor in ipairs(open_editors) do
			for _, state_sprite in ipairs(editor.open_sprites) do
				if app.sprite == state_sprite.sprite then
					return state_sprite
				end
			end
		end
		return nil
	end

	local function active_state_editor()
		local state_sprite = active_state_sprite()
		return state_sprite and state_sprite.editor or nil
	end

	local function find_renamable_editor()
		local editor = active_state_editor()
		if editor and editor:can_rename_selected_or_open_state() then
			return editor
		end

		for _, editor in ipairs(open_editors) do
			if not editor.closed and editor:can_rename_selected_or_open_state() then
				return editor
			end
		end
		return nil
	end

	before_listener = app.events:on("beforecommand", function(ev)
		-- Dispatch to open editors first (same reason as aftercommand above).
		if ev.name == "Copy" then
			Editor.clear_frame_clipboard()
		end
		for _, editor in ipairs(open_editors) do
			if not editor.closed then
				editor:onbeforecommand(ev)
			end
		end

		if RawDmi.beforecommand(ev) then
			return
		elseif ev.name == "Exit" then
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
		id = "dmi_open",
		title = "Open DMI",
		group = "dmi_editor",
		onclick = function()
			app.command.OpenFile()
		end,
	}

	plugin:newCommand {
		id = "dmi_raw_open",
		title = "Open DMI as Spritesheet",
		group = "dmi_editor",
		onclick = function()
			RawDmi.open()
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
			local editor = active_state_editor()
			if editor then editor:expand() end
		end,
		onenabled = function()
			return active_state_sprite() and true or false
		end,
	}

	plugin:newCommand {
		id = "dmi_resize",
		title = "Resize",
		group = "dmi_editor",
		onclick = function()
			local editor = active_state_editor()
			if editor then editor:resize() end
		end,
		onenabled = function()
			return active_state_sprite() and true or false
		end,
	}

	plugin:newCommand {
		id = "dmi_crop",
		title = "Crop",
		group = "dmi_editor",
		onclick = function()
			local editor = active_state_editor()
			if editor then editor:crop() end
		end,
		onenabled = function()
			return active_state_sprite() and true or false
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
			libdmi.open_repo("issues")
		end,
	}

	plugin:newCommand {
		id = "dmi_releases",
		title = "Releases",
		group = "dmi_editor",
		onclick = function()
			libdmi.open_repo("releases")
		end,
	}

	plugin:newMenuSeparator {
		group = "dmi_editor",
	}

	plugin:newCommand {
		id = "dmi_rename_state",
		title = "Rename State",
		group = "dmi_editor",
		onclick = function()
			local editor = find_renamable_editor()
			if editor then
				editor:rename_selected_or_open_state()
			end
		end,
		onenabled = function()
			return find_renamable_editor() and true or false
		end,
	}
end

--- Exits the plugin. Called when the plugin is removed or Aseprite is closed.
--- @param plugin Plugin The plugin object.
function exit(plugin)
	-- Always clean up event listeners to prevent duplicates if init() runs again
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
	if not exiting and libdmi then
		-- DLL cannot be unloaded while the process is running; keep libdmi
		-- alive so a subsequent init() can reuse it via loadlib().
		print(
			"To uninstall the extension, re-open the Aseprite without using the extension and try again.\nThis happens because once the library dll is loaded, it cannot be unloaded.\n")
		return
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
	if not libdmi then
		if app.fs.pathSeparator ~= "/" then
			package.loadlib(app.fs.joinPath(plugin_path, LUA_LIB --[[@as string]]), "")
		elseif package.config:sub(1,1) == "/" and not package.cpath:find("%.dylib") then
			package.cpath = package.cpath .. ";?.so"
		elseif package.config:sub(1,1) == "/" and package.cpath:find("%.dylib") then
			package.cpath = package.cpath .. ";?.dylib"
		end
		local loader, err = package.loadlib(app.fs.joinPath(plugin_path, DMI_LIB), "luaopen_dmi_module")
		if not loader then
			app.alert { title = DIALOG_NAME, text = { "Failed to load DMI library", err or "Unknown error" } }
			return
		end

		local ok, module = pcall(loader)
		if not ok then
			app.alert { title = DIALOG_NAME, text = { "Failed to initialize DMI library", tostring(module) } }
			return
		end

		libdmi = module
		general_check()
	end
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
		text = "Pressing \"OK\" will open the latest release page in your browser.",
	}

	dialog:canvas { height = 1 }

	dialog:button {
		focus = true,
		text = "&OK",
		onclick = function()
			libdmi.open_repo("releases/latest")
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
