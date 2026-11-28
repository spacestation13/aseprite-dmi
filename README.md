# DMI Editor for Aseprite

This project is a DMI (BYOND's Dream Maker icon files) editor extension for [Aseprite](https://www.aseprite.org), a popular pixel art tool.
It aims to enhance the Aseprite experience by providing tools for editing and managing DMI files.

![demo screenshot](./.github/demo.png)

## Download

The latest version of this extension is available for download from the [Releases](https://github.com/spacestation13/aseprite-dmi/releases) page.

The plugin will also prompt you to download an update when a new version is released.

### Requires Aseprite v1.3.18 or later.

## Usage

### Quickstart

1. **Install the extension:**
	- Download or build the extension, then add it to Aseprite by dragging and dropping the file into the application, or use `Edit > Preferences > Extensions > Add Extension`
2. **Open or create a DMI file:**
	- Open DMI files as you would any other file format in Aseprite
	- To create a new DMI file, go to `File > DMI Editor > New DMI File`

### Features

- Edit and manage BYOND DMI icon files directly in Aseprite
- Change icon state properties (name, directions, frames, etc.) via right-click or clicking the name
- Copy and paste icon states using the context menu (states are copied as JSON with embedded PNG images)
- Expand, resize, or crop DMI files from the `File > DMI Editor` menu
- Split/combine icon states in multiple ways
- <kbd>Ctrl+click</kbd> toggles a state in the selection and <kbd>Ctrl+Shift+click</kbd> selects a range
- Keyboard navigation in the state grid
- Type a state name to jump to it (names starting with the typed text first, then names containing it)
- <kbd>Ctrl+F</kbd>, <kbd>/</kbd> or right-click empty space > Find... filters the DMI by your search
- Access plugin preferences under `File > DMI Editor > Preferences`

### Platforms

Download the extension for your platform from the release:

- **Windows:** `aseprite-dmi-windows`
- **macOS:** `aseprite-dmi-macos`
- **Linux:** `aseprite-dmi-linux` (Steam or standalone)

<details>
<summary>Linux alternative: Windows Aseprite via Wine/Lutris</summary>

On older distros, you can run the Windows version of Aseprite and the extension through Lutris instead.

1. [Download](https://www.aseprite.org/buy/) or [compile](https://github.com/aseprite/aseprite) the **latest** Aseprite installer for Windows.
2. Open Lutris, click the plus icon in the top left, and select "Install a windows game from an executable".
3. Set the name to Aseprite and then click through the installer.
4. For "Select the setup file", choose the compiled or downloaded Aseprite Windows installer `Aseprite-*.exe`.
5. Finish the installation.
6. Open Aseprite and follow the Quickstart above, using `aseprite-dmi-windows`.

</details>

## Building the Project

### Requirements

-	[Rust](https://www.rust-lang.org/)
-	[Python](https://www.python.org/)
-	A C++ compiler (MSVC Build Tools on Windows, `g++`/`clang++` elsewhere)
-	The `lib/lua` submodule: `git submodule update --init`

Lua is compiled into the library from [Aseprite's Lua fork](https://github.com/aseprite/lua).

To build the project, run the `tools/build.py` Python script.

### Releasing

Push a git tag like `v1.0.8`, after changing the Cargo.toml and package.json files.

## LICENSE

**GPLv3**, for more details see the [LICENSE](./LICENSE).

Originally created by [Seefaaa](https://github.com/Seefaaa) at https://github.com/Seefaaa/aseprite-dmi
