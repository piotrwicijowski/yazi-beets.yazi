# yazi-beets

A [Yazi](https://yazi-rs.github.io/) plugin that shows whether paths have **collection membership** in a local [beets](https://beets.io/) library. A beets item is authoritative: a file extension or location beneath a music root does not prove membership.

## Requirements

- Yazi **25.5.28 or later**
- beets **2.x**, with the `beet` command on `PATH`

## Install

Install the package from GitHub:

```sh
ya pkg add piotrwicijowski/yazi-beets
```

The package is published at [piotrwicijowski/yazi-beets.yazi](https://github.com/piotrwicijowski/yazi-beets.yazi). For a manual installation, copy this repository into `~/.config/yazi/plugins/yazi-beets.yazi/`.

## Quick start

Add the plugin and its linemode to `~/.config/yazi/init.lua`:

```lua
local beets = require("yazi-beets")

beets:setup({
  -- By default, beets' effective configuration is used.
  -- library = "/absolute/path/to/library.db",
  -- directory = "/absolute/path/to/music-root",

  -- cache = true,
  -- ignore_extensions = { "jpg", "png" },
  -- ignore_subdirectories = { "Artwork", "Downloads" },

  -- tag_markers = {
  --   { label = "S", field = "onsync" },
  -- },
})

function Linemode:beets()
  return beets:linemode(self._file)
end
```

Select it in `~/.config/yazi/yazi.toml`:

```toml
[mgr]
linemode = "beets"
```

Optionally bind an explicit refresh in `~/.config/yazi/keymap.toml`:

```toml
[[manager.prepend_keymap]]
on = "<C-r>"
run = "plugin yazi-beets"
desc = "Refresh beets collection status"
```

## Status markers

| Marker | Meaning |
| --- | --- |
| `●` | collected |
| `◐` | directory with collected and uncollected candidates |
| `○` | uncollected |
| `…` | evaluation is pending |
| `!` | unavailable; inspect configuration or beets output |
| `—` | not applicable; excluded or has no candidate descendants |

Symlinks are not evaluated. Pending and unavailable status are never evidence that a path is uncollected.

## Documentation

- [Configuration reference](docs/configuration.md)
- [Collection-status behavior and preview card](docs/behavior.md)
- [Tag markers and their mutating actions](docs/tag-markers.md)
- [Testing and manual verification](docs/testing.md)

## Development

Run the automated checks with:

```sh
make check
```

## License

[MIT](LICENSE)
