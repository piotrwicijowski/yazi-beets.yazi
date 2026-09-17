# Configuration reference

Configure the plugin in `~/.config/yazi/init.lua`:

```lua
local beets = require("yazi-beets")

beets:setup({
  -- library = "/absolute/path/to/library.db",
  -- directory = "/absolute/path/to/music-root",
  -- cache = true,
  -- ignore_extensions = { "jpg", "png" },
  -- ignore_subdirectories = { "Artwork", "Downloads" },
  -- tag_markers = {
  --   { label = "S", field = "onsync" },
  -- },
})
```

## Library and directory

Omit both `library` and `directory` to use beets' effective configuration. The plugin runs `beet list -p` and evaluates the returned paths against the candidates scanned beneath the active Yazi directory.

To use an explicit library, set **both** fields to non-empty absolute paths. Lookups then run:

```text
beet -l <library> -d <directory> list -p
```

A partial or empty override is unavailable, never uncollected. With an explicit `directory`, the plugin does not scan or invoke beets outside that root; its linemode is hidden there.

## Lookup cache

Set `cache = true` only with an explicit `library` and `directory`. The in-memory cache is reused while the library database and its optional SQLite `-wal` sidecar retain their modification time and size. It is never persisted, failed lookups are never cached, and an explicit refresh always runs fresh lookups.

Without explicit paths, `cache = true` leaves the usual fresh-lookup behavior in place because the effective library database path is unknown.

## Candidate exclusions

`ignore_extensions` and `ignore_subdirectories` remove entries from collection-membership evaluation.

- Extension values are bare final extensions and match case-insensitively: `jpg` excludes `cover.jpg` and `COVER.JPG`.
- Subdirectory values match directory basenames case-sensitively at every depth, including the active directory.
- Both values must be dense Lua arrays of unpadded, nonblank strings. Extension values cannot begin with `.`.

Excluded paths display `—` and do not affect ancestor counts or collection status. A tree with no remaining candidate files is ready with not-applicable status and does not invoke beets.

For `tag_markers`, see [Tag markers and actions](tag-markers.md).
