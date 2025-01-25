#!/usr/bin/python
import os
import shutil
import subprocess
import urllib.request
import urllib.error
import zipfile

EXTENSION_NAME = "aseprite-dmi"
LIBRARY_NAME = "dmi"
TARGET = "debug"
CI = False

import sys
args = sys.argv[1:]

if "--release" in args:
    TARGET = "release"
elif "--ci" in args:
    try:
        index = args.index("--ci")
        TARGET = args[index + 1]
        CI = True
    except IndexError:
        print("Error: Please provide a target name after --ci flag.")
        sys.exit(1)

working_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.chdir(working_dir)

if not CI:
    try:
        rust_version_output = subprocess.check_output(["rustc", "--version"]).decode()
    except FileNotFoundError:
        print("Error: Rust is not installed.")
        sys.exit(1)
    os.chdir(os.path.join(working_dir, "lib"))
    try:
        print("Building main library...")
        if TARGET == "debug":
            subprocess.run(["cargo", "build"], check=True)
        else:
            subprocess.run(["cargo", "build", "--release"], check=True)
    except subprocess.CalledProcessError:
        print("Error: lib build failed. Please check for errors.")
        sys.exit(1)

os.chdir(working_dir)

win = sys.platform.startswith('win')
if win:
    library_extension = ".dll"
    library_prefix = ""
elif sys.platform.startswith('darwin'):
    library_extension = ".dylib"
    library_prefix = "lib"
else:
    library_extension = ".so"
    library_prefix = "lib"

library_source = os.path.join("lib", "target", TARGET if not CI else os.path.join(TARGET, "release"), f"{library_prefix}{LIBRARY_NAME}{library_extension}")

dist_dir = os.path.join(working_dir, "dist")
unzipped_dir = os.path.join(dist_dir, "unzipped")

if not os.path.exists(library_source):
    print("Error: lib was not built. Please check for errors.")
    sys.exit(1)

if win:
    lua_library = f"{library_prefix}lua54{library_extension}"
    if not os.path.exists(lua_library):
        print("Lua library not found. Downloading...")
        zip_path = os.path.join(working_dir, "lua54.zip")
        try:
            url = "https://netix.dl.sourceforge.net/project/luabinaries/5.4.2/Windows%20Libraries/Dynamic/lua-5.4.2_Win64_dllw6_lib.zip"
            urllib.request.urlretrieve(url, zip_path)
        except urllib.error.URLError as e:
            if os.path.exists(zip_path):
                os.remove(zip_path)
            print(f"Could not download lua library. Please check your internet connection and try again.")
            print(f"Error details: {e}")
            sys.exit(1)
        else:
            with zipfile.ZipFile(zip_path, "r") as zip_ref:
                zip_ref.extract(lua_library, working_dir)
            os.remove(zip_path)
elif CI and sys.platform.startswith('linux'):
    # For CI Linux builds, Lua library should already be in dist/unzipped
    lua_library = f"{library_prefix}lua5.4{library_extension}"
    print(f"Working directory: {working_dir}")
    print(f"Looking for Lua library: {lua_library}")

    # List contents of working directory
    print("Contents of working directory:")
    for item in os.listdir(working_dir):
        print(f"  {item}")

    # Check to-copy directory
    to_copy_path = os.path.join(working_dir, "to-copy")
    lua_path = os.path.join(to_copy_path, lua_library)
    print(f"Checking for Lua at: {lua_path}")

    if os.path.exists(to_copy_path):
        print("Contents of to-copy directory:")
        for item in os.listdir(to_copy_path):
            print(f"  {item}")
    else:
        print("to-copy directory does not exist!")

    if not os.path.exists(lua_path):
        print("Error: Steam Runtime Lua library not found")
        sys.exit(1)
elif not CI and sys.platform.startswith('linux'):
    print("Warning: On Linux, the Lua library must be built in Steam Runtime.")
    print("Please run the build-lua workflow in GitHub Actions to get the correct library.")
    sys.exit(1)

if os.path.exists(dist_dir):
    shutil.rmtree(dist_dir)

os.makedirs(dist_dir)
os.makedirs(unzipped_dir)

shutil.copy("package.json", unzipped_dir)
shutil.copy("LICENSE", unzipped_dir)
shutil.copy("README.md", unzipped_dir)
shutil.copy(library_source, unzipped_dir)

if win or (CI and sys.platform.startswith('linux')):
	# On Windows, copy from working dir
	# On Linux CI, it's in to-copy
	if win:
		shutil.copy(lua_library, unzipped_dir)
	else:
		shutil.copy(os.path.join(working_dir, "to-copy", lua_library), unzipped_dir)

shutil.copytree(os.path.join("scripts"), os.path.join(unzipped_dir, "scripts"))

if CI:
    if TARGET.find("windows") != -1:
        target_name = "-windows"
    elif TARGET.find("linux") != -1:
        target_name = "-linux"
    elif TARGET.find("darwin") != -1:
        target_name = "-macos"
else:
    target_name = ""

zip_path = os.path.join(dist_dir, f"{EXTENSION_NAME}{target_name}.zip")
with zipfile.ZipFile(zip_path, "w") as zipf:
    for root, dirs, files in os.walk(unzipped_dir):
        for file in files:
            zipf.write(os.path.join(root, file), os.path.relpath(os.path.join(root, file), unzipped_dir))

extension_path = os.path.join(dist_dir, f"{EXTENSION_NAME}{target_name}.aseprite-extension")
if os.path.exists(extension_path):
    os.remove(extension_path)

shutil.copy(zip_path, extension_path)

print("Build completed successfully.")
