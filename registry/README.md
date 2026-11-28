# Registry

Data the extension downloads on demand from this directory on `main`
(`https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/<name>.json`).
A copy of this directory ships inside the extension, so everything also works offline.

How the extension uses it (`scripts/classes/registry.lua`):

- The network is used only when a dialog that needs the data opens, never at startup.
  Downloads time out after 5 seconds.
- Downloads are cached in `<Aseprite user config>/aseprite-dmi/registry/` (`meta.json` keeps
  download times). A cached file counts as fresh for 24 hours; after a failed download the
  extension waits 10 minutes before trying again on its own (Refresh always tries).
- When a download fails it uses the cached copy, else the bundled copy. Between the cache and
  the bundled copy it uses the one with the newer `updated` date, so a stale cache never hides
  a newer list shipped with an extension update.
- Files an entry points at (`url`) are cached by a hash of the URL, with the same freshness
  rules, and fall back to the bundled copy.
- Only files in this repository are fetched: every URL must start with
  `https://raw.githubusercontent.com/spacestation13/aseprite-dmi/`. Entries pointing anywhere
  else are not listed, and such URLs are refused without touching the cache or the network.
  Files in other repositories could go stale or be swapped for something else after review.

## palettes.json

Codebase palettes, listed in `File > DMI Editor > Codebase Palettes`, where they can be
installed into Aseprite's palette Presets.

```json
{
	"version": 1,
	"updated": "2026-11-27",
	"palettes": [
		{
			"id": "goonstation",
			"name": "Goonstation",
			"codebase": "Goonstation",
			"url": "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/goonstation.gpl",
			"format": "gpl",
			"description": "Goonstation's spriting palette: 20 color ramps, darkest first.",
			"guidelines": "Keep palettes small: build each sprite from a few of these ramps.",
			"homepage": "https://github.com/goonstation/goonstation"
		}
	]
}
```

Top level:

| Field      | Required | Meaning                                                              |
|------------|----------|----------------------------------------------------------------------|
| `version`  | yes      | Schema version, `1`.                                                 |
| `updated`  | yes      | `YYYY-MM-DD` of the last change. Bump it in every PR.                |
| `palettes` | yes      | Entries, shown in this order.                                        |

Entry:

| Field         | Required | Meaning                                                                    |
|---------------|----------|----------------------------------------------------------------------------|
| `id`          | yes      | Unique, lowercase, `a-z0-9-`.                                              |
| `name`        | yes      | Shown in the list; also the Presets file name (`<name>.gpl`).              |
| `url`         | yes      | Raw URL of the file in this repository: `https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/<id>.<ext>`. Any other host or repository is refused. |
| `format`      | no       | `gpl` (GIMP palette), `hex` (one `RRGGBB` per line, Lospec's export) or `png` (unique colors in reading order, transparent pixels skipped). Default: the URL's extension. |
| `codebase`    | no       | The codebase it belongs to.                                                |
| `description` | no       | One sentence.                                                              |
| `guidelines`  | no       | One sentence on how the codebase wants it used.                            |
| `homepage`    | no       | Where it comes from (repository, wiki page). Credit only, never fetched.   |
| `license`     | no       | If the palette file has one.                                               |

Keep text fields short: the dialog wraps them but has room for only a few lines.

### Adding your codebase's palette

Palettes are contributed by pull request to this repository; the extension never downloads
from a codebase's own repository.

1. Add the palette file as `registry/palettes/<id>.gpl` (or `.hex`/`.png`). If it comes from
   your codebase (for example its `.github/palette.png`), copy the file in and credit it in
   `homepage` and the list below. To update it later, open another PR here.
2. Give every `.gpl` color line a name: Aseprite skips color lines without one, and reads
   only the first word of a name (it shows as the color's tooltip). Use names like `Red-1`
   (ramp, then step, darkest first); the dialog groups colors into ramps by that prefix.
3. Add the entry to `palettes.json` with
   `"url": "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/<id>.gpl"`
   (keep the list alphabetical by `name`), bump `updated` and open a pull request. The file is
   downloadable once the PR is merged into `main`, and bundled with the next release.

### Palettes

- `palettes/goonstation.gpl`: taken from the palette reference image Goonstation artists use
  (ramps of 3-5 swatches above example jumpsuits). Only the swatch ramps, in the order of the
  image, left to right, top row first, then the grey scale ramp, then the bottom row. The
  ramp names are inferred from the image (its labels: `BONE`, `NT`, `SYNDIE`, grey scale
  chairs, robots, tools); NT and Syndicate share one dark grey ramp (`Faction-Grey`).
