--- @diagnostic disable: lowercase-global

-- shits fucked

local LUA_VERSION = "5.4.6"
local LUA_DOWNLOAD_URL = string.format("https://www.lua.org/ftp/lua-%s.tar.gz", LUA_VERSION)

--- Downloads a file using available system tools
--- @param url string URL to download from
--- @param output string Output file path
--- @return boolean success, string? error
function download_file(url, output)
	-- Try curl first
	local curl_success = os.execute(string.format("curl -L -o %q %q", output, url))
	if curl_success then
		return true
	end

	-- Try wget as fallback
	local wget_success = os.execute(string.format("wget -O %q %q", output, url))
	if wget_success then
		return true
	end

	return false, "Neither curl nor wget are available"
end

--- Extracts a tar.gz file
--- @param archive string Path to archive
--- @param destination string Destination directory
--- @return boolean success, string? error
function extract_archive(archive, destination)
	local success = os.execute(string.format("tar -xzf %q -C %q", archive, destination))
	return success == true, success and nil or "Failed to extract archive"
end

--- Check if required build tools are available
--- @return boolean
function check_build_tools()
	local success = os.execute("which make >/dev/null 2>&1")
	if not success then
		return false
	end
	success = os.execute("which gcc >/dev/null 2>&1")
	return success == true
end

--- Downloads and prepares Lua source code
--- @param build_dir string Build directory
--- @return boolean success, string? error
local function prepare_lua_source(build_dir)
    -- Create build directory if it doesn't exist
    app.fs.makeAllDirectories(build_dir)

    -- Download Lua source
    local archive = app.fs.joinPath(build_dir, "lua.tar.gz")
    local success, err = download_file(LUA_DOWNLOAD_URL, archive)
    if not success then
        return false, "Failed to download Lua source: " .. (err or "unknown error")
    end

    -- Extract archive
    success, err = extract_archive(archive, build_dir)
    if not success then
        return false, err
    end

    -- Remove archive
    os.remove(archive)

    return true
end

--- Compiles Lua for Unix-like systems
--- @param plugin_path string Path where the extension is installed
--- @return boolean success, string? error
function compile_lua(plugin_path)
    if not check_build_tools() then
        return false, "Required build tools (make, gcc) not found"
    end

    local build_dir = app.fs.joinPath(app.fs.tempPath, "lua_build")
    local success, err = prepare_lua_source(build_dir)
    if not success then
        return false, err
    end

    local src_dir = app.fs.joinPath(build_dir, "lua-" .. LUA_VERSION)

    -- Configure make for shared library
    local commands = {
        string.format("cd %q", src_dir),
        "make clean",
        "make MYCFLAGS=-fPIC MYLDFLAGS=-shared linux"
    }

    -- Execute build commands
    for _, cmd in ipairs(commands) do
        local success = os.execute(cmd)
        if not success then
            return false, "Failed to execute: " .. cmd
        end
    end

    -- Copy resulting library to plugin directory
    local lib_name = app.os.macos and "liblua.dylib" or "liblua.so"
    local src_lib = app.fs.joinPath(src_dir, "src", lib_name)
    local dest_lib = app.fs.joinPath(plugin_path, lib_name)

    if not app.fs.isFile(src_lib) then
        return false, "Failed to build Lua library"
    end

    -- Copy built library to plugin directory
    local copy_cmd = string.format("cp %q %q", src_lib, dest_lib)
	success = os.execute(copy_cmd) == 0
    if not success then
        return false, "Failed to copy library to plugin directory"
    end

    -- Clean up build directory
    os.execute(string.format("rm -rf %q", build_dir))

    return true
end
