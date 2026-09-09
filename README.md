# yazi-beets

A read-only [Yazi](https://yazi-rs.github.io/) plugin that shows whether a path has **collection membership** in a local [beets](https://beets.io/) library. A beets item is authoritative: neither a filename extension nor being beneath the music root proves membership.

## Support

- Yazi **25.2.13 or later** (the plugin declares this minimum at load time).
- beets **2.x**, using the documented `beet list -p` CLI.
- The automated suite is exercised with Lua 5.5; the verification environment provides Yazi 26.8.15 and beets 2.13.1.

The plugin never imports, moves, retags, deletes, or otherwise modifies beets items. Symlinks are not followed or evaluated.

## Install

Copy or symlink `yazi-beets.yazi/` into Yazi's plugin directory:

```sh
mkdir -p ~/.config/yazi/plugins
cp -R yazi-beets.yazi ~/.config/yazi/plugins/
```

Add this to `~/.config/yazi/init.lua`:

```lua
local beets = require("yazi-beets")

beets:setup({
  -- Leave both fields out to use beets' effective default configuration.
  -- library = "/absolute/path/to/library.db",
  -- directory = "/absolute/path/to/music-root",

  -- Optional: cache successful lookups for an explicit library override.
  -- cache = true,

  -- Omit either list, or use an empty list, to exclude nothing.
  -- ignore_extensions = { "jpg", "png" },
  -- ignore_subdirectories = { "Artwork", "Downloads" },
})

function Linemode:beets()
  return beets:linemode(self._file)
end
```

A custom linemode must also be selected in `~/.config/yazi/yazi.toml`:

```toml
[mgr]
linemode = "beets"
```

### Explicit library override

Set **both** `library` and `directory` to non-empty absolute paths. Every lookup then runs:

```text
beet -l <library> -d <directory> list -p
```

With neither field, the plugin runs `beet list -p` and lets beets load its effective default configuration. Each active-directory snapshot intersects that full library path set with its recursively scanned candidates. This avoids beets’ configured-root `path:` query edge case. A partial or empty override is unavailable; it is never treated as uncollected.

With an explicit `directory` override, the plugin does not scan or invoke `beet` for an active directory outside that root. Those entries display `—` because collection membership is not evaluated there. This guard is unavailable with the default configuration because the effective beets root is not known to the plugin.

### Optional lookup cache

`cache = true` enables an in-memory cache of successful `beet` lookup output when both `library` and `directory` are explicitly configured. The plugin checks the library database's modification time and size, plus its SQLite `-wal` sidecar when present, before reusing that output. A change starts a fresh lookup. The active directory is still recursively scanned on every entry, so filesystem additions, removals, and renames are reflected immediately.

Caching is unavailable with the default beets configuration because the plugin does not know the effective library database path; `cache = true` therefore leaves the usual fresh-lookup behavior in place. The cache is never persisted and is cleared when `setup()` is called again. A manual refresh always bypasses it and performs a new lookup.

### Candidate exclusions

`ignore_extensions` and `ignore_subdirectories` are optional lists that remove entries from collection-membership evaluation. Extension values are bare final extensions, matched case-insensitively: `jpg` excludes both `cover.jpg` and `COVER.JPG`. Subdirectory values match directory basenames case-sensitively at every depth, including the active directory.

Both settings must be dense arrays of nonblank, unpadded strings. A leading `.` is invalid for an extension. Scalars, maps, holes, non-string entries, and padded values are invalid; an invalid list makes the active snapshot unavailable before either scanning or running `beet`.

An excluded file or directory subtree displays `—` (not applicable) and does not contribute to ancestor counts or collection status. A scanned tree with no remaining candidate files becomes ready with not-applicable statuses and skips the `beet` command.

### Refresh

By default, the plugin begins a fresh lookup whenever Yazi emits an active-directory change. Bind its functional entry point in `~/.config/yazi/keymap.toml` to refresh the active directory explicitly (and to start the initial lookup if no directory-change event has occurred yet):

```toml
[[manager.prepend_keymap]]
on = "<C-r>"
run = "plugin yazi-beets"
desc = "Refresh beets collection status"
```

Each entry or refresh discards the old snapshot. The default behavior does not poll or keep a session-wide cache; the optional lookup cache above changes only the lookup behavior on directory entry.

### Progressive updates

An active directory initially displays pending collection statuses. After the beets lookup is available (immediately on an optional cache hit), direct candidate files in the active directory are published first. The plugin then scans and publishes each direct subdirectory's complete subtree in turn. Unfinished paths remain pending, including the active directory itself, until every subtree is complete. This keeps large collection roots responsive without treating incomplete work as uncollected.

## Markers

| Marker | Collection status |
| --- | --- |
| `●` | collected |
| `◐` | mixed directory |
| `○` | uncollected |
| `!` | unavailable |
| `…` | pending collection status |
| `—` | not applicable (excluded by configuration or no candidate descendants) |

A **candidate file** is any non-directory, non-symlink entry not removed by a candidate exclusion. Directories aggregate every recursive candidate descendant. Pending and unavailable results are never evidence that a path is uncollected.

## Selected-entry card and ordinary previews

The plugin includes a `peek()` previewer that renders an accessible status card with the status name, explanation, path, library identity, directory counts, and recovery guidance.

Yazi previewers replace the previewer rule they match; it has no generic preview-overlay or previewer-chaining API. To avoid silently taking away ordinary previews, the installation above **does not install the card as a catch-all previewer**. Ordinary Yazi previews remain visible by default.

To intentionally use the status card instead of normal previews, opt in with this `yazi.toml` rule:

```toml
[plugin]
prepend_previewers = [
  { url = "*", run = "yazi-beets" },
]
```

Remove that rule to safely fall back to Yazi's ordinary previewer. This explicit choice is necessary because a generic custom previewer cannot compose with every built-in image, video, archive, and code previewer.

## Verification

Run deterministic fixtures and syntax checks:

```sh
make check
```

For a real fixture beets library, manually verify:

1. markers progress from `…` to their completed values after opening a directory;
2. `Ctrl-r` performs one new lookup and a bad override shows `!`, not `○`; and
3. with `cache = true` and an explicit override, revisiting an unchanged library avoids `beet`, while changing the database or its `-wal` sidecar triggers a new lookup;
4. default and paired-override lookups use the expected library;
5. empty, all-collected, all-uncollected, mixed, symlink-containing, and excluded directories aggregate correctly;
6. extension and subdirectory exclusions show `—`, including an active directory excluded by basename, and a malformed list shows `!`; and
7. the opt-in card is readable, shows recovery guidance on failure, and removing its preview rule restores ordinary Yazi previews.
