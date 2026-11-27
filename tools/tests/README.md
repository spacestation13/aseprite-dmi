# Aseprite test harness

Runs Lua scenarios inside a real, isolated Aseprite (Windows only).

```sh
cd lib && cargo build && cd ..                                   # or pass --build
py tools/aseprite_runner.py tools/tests/smoke_editor.lua         # batch
py tools/aseprite_runner.py tools/tests/gui_smoke.lua --gui --screenshot %TEMP%/gui.png
cd lib && cargo test --test lua_syntax                           # Lua syntax check
```

Options: `--gui`, `--param k=v` (repeatable, read with `T.param`), `--screenshot PNG` (GUI,
when done), `--timeout S` (default 60 batch / 120 GUI), `--keep-open` (GUI), `--window WxH`
(GUI main window size, default 1600x1000), `--build` (`cargo build` in `lib/` first).

Output: the JSON result and a `PASS`/`FAIL`/`TIMEOUT`/`CRASH` line. Exit codes: 0 pass,
1 fail, 2 timeout, 3 crash, 4 setup error.

## Writing a scenario

```lua
local dmi, err = libdmi.open_file(T.path("lib", "tests", "assets", "anomaly.dmi"), TEMP_DIR)
T.ok(err == nil, err)
T.eq(#dmi.states, 9, "state count")
```

Batch (default) runs `Aseprite -b`: no UI, so the bootstrap emulates the plugin's `init`
(scripts from `package.json`, `libdmi`, `TEMP_DIR`, `Preferences`/`RawDmi` with the fake
plugin `T.plugin`). `Dialog()` returns nil, `app.alert` is a no-op, `Timer`s never fire.

GUI (`--gui`) installs the extension into the run's user folder, so the real `init` runs
before the scenario. The scenario runs before the event loop: call `T.async()`, continue
from timers/callbacks and finish with `T.done()`.

## The T API

- Assertions (failures stop the scenario with `file:line: message` and a traceback):
  `T.ok(cond, msg)`, `T.eq(a, b, msg)` (deep), `T.neq`, `T.near(a, b, eps, msg)`,
  `T.pixels_equal(imageA, imageB, msg)`, `T.fail(msg)`.
- `T.detail(key, value)` adds to the result's `details`.
- `T.param(name, default)`, `T.path(...)` (repo-relative), `T.repo`, `T.tmp` (empty per-run dir).
- GUI only: `T.async()`, `T.done()`, `T.after(seconds, fn)`,
  `T.wait_until(pred, fn, {timeout, interval, what})` (`fn` gets pred's value),
  `T.steps{ function(next, ...) ... end, ... }`, `T.input(actions, fn)`, `T.screenshot(name, fn)`
  (saved to `<run>/screenshots/`).

```lua
T.input({
  { click = { x = 60, y = 40 }, dialog = editor.dialog, mods = "Ctrl" }, -- button = "right"/"middle", double = true
  { move = { x = 10, y = 10 } },
  { key = "F2" }, { key = "Ctrl+A" }, { text = "new_name" }, { key = "Enter" },
  { wait = 0.2 },
}, next)
```

Coordinates are UI units (as `Dialog.bounds`, `app.window`, canvas events), relative to the
main window or to `dialog.bounds`. Canvas positions inside a dialog aren't exposed to Lua:
calibrate with a `move` and the canvas `onmousemove` (see `gui_input.lua`). Input is sent as
window messages: it never moves the cursor, steals focus or touches your keyboard.

## Isolation

- The Steam install (or `ASEPRITE_EXE`) is copied once to
  `%LOCALAPPDATA%/aseprite-dmi-test/aseprite/` (override the root with `ASEPRITE_DMI_TEST_CACHE`).
- Each run gets `runs/<time>-<pid>-<scenario>-<mode>/` with its own `ASEPRITE_USER_FOLDER`
  (`user/`), `TMP` (so `TEMP_DIR`), `T.tmp`, `result.json`, `aseprite.log`, screenshots.
  Dirs older than 6 h are pruned. `%APPDATA%/Aseprite` is never touched.
- Concurrent runs from any worktree are safe; dll and scripts come from the runner's worktree.
- The runner only kills the Aseprite it launched (job object).

## Gotchas

- libdmi functions return `(value, error)` instead of raising: check the error.
- Script trust is keyed by the loading path: only the bootstrap, `.lua` files under the
  scenario's directory and `tools/tests/`, and the installed extension are trusted. A helper
  `dofile`d from elsewhere or by a relative path gets a hidden permission prompt: timeout.
- Never open `app.alert` or other modal dialogs in GUI scenarios: they block the script.
- On a GUI timeout the runner saves `timeout.png` of the stuck window in the run dir.
