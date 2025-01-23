
Preferences = {}

--- Initializes the Preferences

-- Store the plugin object in the Preferences class
Preferences.plugin = plugin

-- Initialize default preferences if not set
if not Preferences.plugin.preferences.auto_overwrite then
    Preferences.plugin.preferences.auto_overwrite = false
end

--- Shows the preferences dialog.
function Preferences.show(plugin)
    local dialog = Dialog {
        title = "DMI Editor Preferences"
    }

    dialog:check {
        id = "auto_overwrite",
        text = "Overwrite source DMI files when saving an iconstate.",
        selected = Preferences.plugin.preferences.auto_overwrite,
    }

    -- dialog:newrow()

    -- dialog:check {
    --     id = "auto_flatten",
    --     text = "Flatten layers downwards into directional layers when saving an iconstate.",
    --     selected = Preferences.plugin.preferences.auto_flatten,
    -- }

    dialog:button {
        text = "&OK",
        focus = true,
        onclick = function()
            Preferences.plugin.preferences.auto_overwrite = dialog.data.auto_overwrite
            -- Preferences.plugin.preferences.auto_flatten = dialog.data.auto_flatten
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

return Preferences
