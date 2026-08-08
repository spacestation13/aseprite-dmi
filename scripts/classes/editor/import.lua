-- Import functionality for DMI editor
-- This file contains functions related to importing PNG files and splitting them into DMI states

--- Imports a PNG file into the DMI editor
--- The PNG will be split into tiles of dmi.width x dmi.height size
--- @param self Editor The editor instance
function Editor:import_png()
	if not self.dmi then return end

	local filename = libdmi.open_dialog("Import PNG", app.fs.userDocsPath, "png")
	if filename and #filename > 0 then
		if app.fs.isFile(filename) then
			self:process_png_import(filename)
		else
			app.alert { title = "Error", text = "Selected file does not exist" }
		end
	end
end

--- Processes a PNG file import by splitting it into tiles (delegated to Rust)
--- @param self Editor The editor instance
--- @param filename string Full path to the PNG file to import
function Editor:process_png_import(filename)
	-- Confirm with user
	local updated_dmi, error = libdmi.import_png(self.dmi, filename)
	if error or not updated_dmi then
		app.alert { title = "Error", text = { "Failed to import PNG", error or "Unknown error" } }
		return
	end
	self.dmi = updated_dmi
	self.image_cache:clear()
	self.modified = true
	self:repaint_states()
	self:gc_open_sprites()
end
