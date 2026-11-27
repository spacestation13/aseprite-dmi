------------------- CONSTANTS -------------------

DIRECTION_NAMES = { "South", "North", "East", "West", "Southeast", "Southwest", "Northeast", "Northwest" }
DIALOG_NAME = "DMI Editor"
TEMP_NAME = "aseprite-dmi"

DMI_LIB = app.os.windows and "dmi.dll"
	or app.os.macos and "libdmi.dylib"
	or "libdmi.so"

TEMP_ROOT = app.os.macos and (os.getenv("TMPDIR") or app.fs.tempPath) or app.fs.tempPath
TEMP_DIR = app.fs.joinPath(TEMP_ROOT, TEMP_NAME)

COMMON_STATE = {
	normal = { part = "sunken_normal", color = "button_normal_text" },
	hot = { part = "sunken_focused", color = "button_hot_text" },
	focused = { part = "sunken_focused", color = "button_normal_text" },
	selected = { part = "button_selected", color = "button_hot_text" },
} --[[@as WidgetState]]

--- @alias CombineType "1 direction"|"Frames first, 4 directions"|"Frames first, 8 directions"|"4 directions first, then frames"|"8 directions first, then frames"
COMBINE_TYPES = {
	onedir = "1 direction",
	frames_4dir = "Frames first, 4 directions",
	frames_8dir = "Frames first, 8 directions",
	dirs4_frames = "4 directions first, then frames",
	dirs8_frames = "8 directions first, then frames",
}

--- The `libdmi.combine_states` layout and directions of each combine type.
--- @type table<CombineType, {layout: "frames_first"|"directions_first", dirs: number}>
COMBINE_LAYOUTS = {
	[COMBINE_TYPES.onedir] = { layout = "frames_first", dirs = 1 },
	[COMBINE_TYPES.frames_4dir] = { layout = "frames_first", dirs = 4 },
	[COMBINE_TYPES.frames_8dir] = { layout = "frames_first", dirs = 8 },
	[COMBINE_TYPES.dirs4_frames] = { layout = "directions_first", dirs = 4 },
	[COMBINE_TYPES.dirs8_frames] = { layout = "directions_first", dirs = 8 },
}

--- @alias FrameSelType "First frame only"|"All frames"
FRAME_SEL_TYPES = {
	first_only = "First frame only",
	all_seq = "All frames",
}
