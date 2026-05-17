# DMI Editor for Aseprite

This project is a DMI (BYOND's Dream Maker icon files) editor extension for [Aseprite](https://www.aseprite.org), a popular pixel art tool.
It aims to enhance the Aseprite experience by providing tools for editing and managing DMI files.

![demo screenshot](./.github/demo.png)

## Download

The latest version of this extension is available for download from the [Releases](https://github.com/spacestation13/aseprite-dmi/releases) page.

The plugin will also prompt you to download an update when a new version is released.

**Requires Aseprite v1.3.18-beta3 or later.**

## Usage

### Quickstart

1. **Install the extension:**
	- Download or build the extension, then add it to Aseprite by dragging and dropping the file into the application, or use `Edit > Preferences > Extensions > Add Extension`
2. **Open or create a DMI file:**
	- Open DMI files as you would any other file format in Aseprite
	- To create a new DMI file, go to `File > DMI Editor > New DMI File`

### Features

- Edit and manage BYOND DMI icon files directly in Aseprite
- Change icon state properties (name, directions, frames, etc.) via right-click or by clicking below the state
- Copy and paste icon states using the context menu (states are copied as JSON with embedded PNG images)
- Expand, resize, or crop DMI files from the `File > DMI Editor` menu
- Split/combine icon states in multiple ways
- Access plugin preferences under `File > DMI Editor > Preferences`

### Linux

Not supported on Steam builds due to dynamic library issues. Running the Windows build via Wine is recommended and reportedly works.

## Building the Project

### Requirements

-	[Rust](https://www.rust-lang.org/)
-	[Python](https://www.python.org/)

To build the project, run `tools/build.py` Python script.

### Releasing

Push a git tag like `v1.0.8`, after changing the Cargo.toml and package.json files.

## LICENSE

**GPLv3**, for more details see the [LICENSE](./LICENSE).

Originally created by [Seefaaa](https://github.com/Seefaaa) at https://github.com/Seefaaa/aseprite-dmi
