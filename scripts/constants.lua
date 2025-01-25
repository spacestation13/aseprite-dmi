------------------- CONSTANTS -------------------

DIRECTION_NAMES = { "South", "North", "East", "West", "Southeast", "Southwest", "Northeast", "Northwest" }
DIALOG_NAME = "DMI Editor"
TEMP_NAME = "aseprite-dmi"

-- OS-specific library extensions and names
local function get_lib_info()
	if app.os.windows then
		return "lua54", "dmi"
	elseif app.os.macos then
		return "lua54", "libdmi.dylib"
	else -- Linux
		return "lua5.4", "libdmi.so"
	end
end

LUA_LIB, DMI_LIB = get_lib_info()

TEMP_DIR = app.fs.joinPath(app.fs.tempPath, TEMP_NAME)

COMMON_STATE = {
	normal = { part = "sunken_normal", color = "button_normal_text" },
	hot = { part = "sunken_focused", color = "button_hot_text" },
} --[[@as WidgetState]]
