# Collection-status behavior

A **candidate file** is a non-directory, non-symlink filesystem entry that is not excluded. A directory aggregates all of its recursive candidate descendants.

| Status | Meaning |
| --- | --- |
| collected | Every candidate corresponds to a beets item. |
| mixed | Some candidates correspond to beets items and some do not. |
| uncollected | No candidates correspond to a beets item after a completed lookup. |
| pending | Evaluation has not completed. |
| unavailable | Collection membership could not be evaluated. |
| not applicable | The path is excluded, outside the explicit music root, or has no candidate descendants. |

## Refresh and progressive updates

The plugin starts a fresh lookup when Yazi emits an active-directory change. Bind `plugin yazi-beets` to refresh explicitly or to start the initial lookup before an active-directory event occurs.

Direct candidate files are published first after a lookup resolves. The plugin then scans direct subdirectory trees one at a time and coalesces status updates. Unfinished paths, including the active directory, remain pending. This keeps large music directories responsive without presenting incomplete work as uncollected.

The default behavior does not poll or keep a session-wide cache. See [Configuration](configuration.md) for the optional lookup cache.

## Selected-entry status card

The plugin provides a `peek()` previewer that shows a status card with the path, library identity, candidate counts, explanation, and recovery guidance. It is deliberately opt-in because Yazi custom previewers replace the rule they match and cannot be generically overlaid on built-in previews.

To use the card instead of normal previews, add this to `~/.config/yazi/yazi.toml`:

```toml
[plugin]
prepend_previewers = [
  { url = "*", run = "yazi-beets" },
]
```

Remove that rule to restore ordinary previews.
