# Registry

Data the extension downloads on demand from this directory on `main`
(`https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/<name>.json`).

A copy of this dir also ships inside the extension for offline use.

Use:

- Downloads are cached in `<Aseprite user config>/aseprite-dmi/registry/` (`meta.json` keeps
  download times). A cached file counts as fresh for 24 hours; after a failed download the
  extension waits 10 minutes before trying again on its own. Downloads time out after 5 seconds.
- When a download fails it uses the cached copy, else the bundled copy. Between the cache and
  the bundled copy it uses the one with the newer `updated` date.
- Files an entry points at (`url`) are cached by a hash of the URL, with the same freshness
  rules, and fall back to the bundled copy.
- Only files in this repository are fetched.

## palettes.json

Codebase palettes, listed in `File > DMI Editor > Codebase Palettes`, where they can be
installed into Aseprite's palette Presets.

```json
{
	"version": 1,
	"updated": "2026-11-27",
	"palettes": [
		{
			"id": "best",
			"name": "Best Palette",
			"codebase": "Gamers R Us",
			"url": "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/goonstation.gpl",
			"description": "Build each sprite from a few of these ramps."
		}
	]
}
```

Top level:

| Field      | Required | Meaning                                                              |
|------------|----------|----------------------------------------------------------------------|
| `version`  | yes      | Schema version, `1`.                                                 |
| `updated`  | yes      | `YYYY-MM-DD` of the last change. Always bump this.                   |
| `palettes` | yes      | Entries, shown in this order.                                        |

Entry:

| Field         | Required | Meaning                                                                    |
|---------------|----------|----------------------------------------------------------------------------|
| `id`          | yes      | Unique, lowercase, `a-z0-9-`.                                              |
| `name`        | yes      | Shown in the list, also the Presets file name (`<name>.gpl`).              |
| `url`         | yes      | Raw URL of the file in this repository: `https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/<id>.gpl`. |
| `codebase`    | no       | The codebase it belongs to.                                                |
| `description` | no       | One sentence shown under the swatches, e.g. how to best use it.            |
| `license`     | no       | If the palette file has one.                                               |

Keep text fields short: the dialog wraps them but has room for only a few lines.

### Adding your codebase's palette

1. Add your GIMP gpl palette file as `registry/palettes/<id>.gpl`
2. Give every `.gpl` color line a name. Use names like `Red-1` (ramp, then step, darkest first) - the dialog groups colors into ramps by that prefix.
3. Add the entry to `palettes.json` with
   `"url": "https://raw.githubusercontent.com/spacestation13/aseprite-dmi/main/registry/palettes/<id>.gpl"`
   (keep the list alphabetical), bump `updated` and open a pull request.
