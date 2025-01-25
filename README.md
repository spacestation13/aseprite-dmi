> [!NOTE]
> This project has been taken under stewardship of the SS13 org to provide updates and allow for community support, as the original creator [is no longer maintaining it](https://github.com/Seefaaa/aseprite-dmi).

# DMI Editor for Aseprite

This project is a DMI (BYOND's Dream Maker icon files) editor extension for Aseprite, a popular pixel art tool. It is written in Rust and Lua and aims to enhance the Aseprite experience by providing tools for editing and managing DMI files.

## Download

The latest version of this extension is available for download from the [Releases](https://github.com/spacestation13/aseprite-dmi/releases) page on the project's GitHub repository.

The plugin will also prompt you to download an update when a new version is released.

### Additional Instructions for Linux and macOS

To use this project, you need to have Lua 5.4 installed on your system.

#### Linux


rust 1.63 required due to scout being ancient

`rustup install 1.63.0`
`rustup override set 1.63.0`

For Debian-based distributions, you can install Lua 5.4 using the following command:

```sh
apt install lua5.4
```

Otherwise, follow the relevant instructions for your distribution to install Lua 5.4.

#### macOS

For macOS, you can install Lua 5.4 using Homebrew. First, ensure you have Homebrew installed, then run:

```sh
brew install lua
```

Make sure Lua 5.4 is correctly installed by running `lua -v` in your terminal, which should display the version information.

## Usage

Once the project has been downloaded or built, the extension can be added to Aseprite by dragging and dropping it into the application or by selecting the 'Add Extension' button in the 'Edit > Preferences > Extensions' menu.

DMI files can now be opened in Aseprite in the same way as any other file format. You will need to change the open file dialog filter to 'All Files'.

### Creating New Files

New files can be created via the following pathway: `File > DMI Editor > New DMI File`.

### Changing Iconstate Properties

The state properties, including the state name, can be modified by right clicking on the state or by clicking on the text below the state in the editor.

### Copy and Paste

Right-clicking on the state will bring up the context menu. The context menu allows the user to copy the state to the clipboard, which can then be pasted at a later stage. Right click on an empty space within the editor to paste the copied state. The states are copied in the JSON format, with PNG images, which are base64-encoded, included for the frames.

### Frames and Delays

In Aseprite's timeline, new frames can be added and delays between frames can be modified.

### Expand, Resize, Crop

The DMI file may be expanded, resized, or cropped via the `File > DMI Editor` menu. It should be noted that the active sprite must be a DMI iconstate in order to utilise these commands.

### Plugin Preferences
Under the `File > DMI Editor` menu, there is an `Preferences` menu which contains various options:

- **Auto Overwrite**: Automatically overwrites the source DMI file when saving an iconstate.
- **Auto Flatten** *(Enabled by Default)*: Automatically flattens layers downward into directional layers when saving an iconstate, allowing you to fully use Aseprite layers.

## Building the Project

### Requirements

- [Rust](https://www.rust-lang.org/)
- [Python](https://www.python.org/) (build script)

To build the project, run `tools/build.py` Python script.

### Releasing

Push a tag like `v1.0.8` via `git`, after changing the Cargo.toml and package.json files.

## LICENSE

**GPLv3**, for more details see the [LICENSE](./LICENSE).

Originally created by [Seefaaa](https://github.com/Seefaaa) at https://github.com/Seefaaa/aseprite-dmi.
