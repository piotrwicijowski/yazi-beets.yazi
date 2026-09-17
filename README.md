# yazi-beets

A [Yazi](https://yazi-rs.github.io/) plugin that shows whether paths have been imported into the local [beets](https://beets.io/) library. Helpful during transition period of having an existing music collection directory and doing successive collection import in place.

## Requirements

- Yazi **25.5.28 or later**
- beets **2.x**, with the `beet` command on `PATH`

## Install

Install the package from GitHub:

```sh
ya pkg add piotrwicijowski/yazi-beets
```

For a manual installation, clone this repository into `~/.config/yazi/plugins/yazi-beets.yazi/`.

## Quick start

Add the plugin and its linemode to `~/.config/yazi/init.lua`:

```lua
local beets = require("yazi-beets")

beets:setup({})

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
