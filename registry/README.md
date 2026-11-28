# Registry

Data the extension downloads on demand from this directory on `main`
(`https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/<name>.json`).
A copy of this directory ships inside the extension, so everything also works offline.

How the extension uses it (`scripts/classes/registry.lua`):

- The network is used only on an explicit user action (opening a dialog that needs the data,
  or pressing its Refresh button), never at startup. Downloads time out after 5 seconds.
- Downloads are cached in `<Aseprite user config>/aseprite-dmi/registry/` (`meta.json` keeps
  download times). A cached file counts as fresh for 24 hours; after a failed download the
  extension waits 10 minutes before trying again on its own (Refresh always tries).
- When a download fails it uses the cached copy, else the bundled copy. Between the cache and
  the bundled copy it uses the one with the newer `updated` date, so a stale cache never hides
  a newer list shipped with an extension update.
- Files an entry points at (`url`) are cached by a hash of the URL, with the same freshness
  rules. URLs inside this directory fall back to the bundled copy.

## palettes.json

Codebase palettes, listed in `File > DMI Editor > Palettes > Codebase Palettes...`, where they
can be applied to the open sprite or installed into Aseprite's palette Presets.

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
| `url`         | yes      | Raw file URL (http/https). Here or in the codebase's own repository.      |
| `format`      | no       | `gpl` (GIMP palette), `hex` (one `RRGGBB` per line, Lospec's export) or `png` (unique colors in reading order, transparent pixels skipped). Default: the URL's extension. |
| `codebase`    | no       | The codebase it belongs to.                                                |
| `description` | no       | One sentence.                                                              |
| `guidelines`  | no       | One sentence on how the codebase wants it used.                            |
| `homepage`    | no       | Where it comes from (repository, wiki page).                               |
| `license`     | no       | If the palette file has one.                                               |

Keep text fields short: the dialog shows about 60 characters per line.

### Adding your codebase's palette

1. Either commit the palette here as `registry/palettes/<id>.gpl` and use its raw URL
   (`https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/<id>.gpl`),
   or point `url` at a raw file in your codebase's repository (for example
   `https://raw.githubusercontent.com/<org>/<repo>/master/.github/palette.png`). A file in your
   repository lets maintainers update the palette without a PR here, but it is only bundled
   with the extension if it lives here.
2. Give every `.gpl` color line a name: Aseprite skips color lines without one, and reads
   only the first word of a name (it shows as the color's tooltip). Use names like `Red-1`
   (ramp, then step, darkest first); the dialog groups colors into ramps by that prefix.
3. Add the entry to `palettes.json` (keep the list alphabetical by `name`), bump `updated`
   and open a pull request.

### Palettes

- `palettes/goonstation.gpl`: taken from the palette reference image Goonstation artists use
  (ramps of 3-5 swatches above example jumpsuits). Only the swatch ramps, in the order of the
  image, left to right, top row first, then the grey scale ramp, then the bottom row. The
  ramp names are inferred from the image (its labels: `BONE`, `NT`, `SYNDIE`, grey scale
  chairs, robots, tools); NT and Syndicate share one dark grey ramp (`Faction-Grey`).
