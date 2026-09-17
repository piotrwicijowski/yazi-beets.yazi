# Tag markers and actions

A tag marker is a labelled beets flexible attribute displayed independently after the collection marker. Most useful for determinig the status of [alternatives](https://github.com/geigerzaehler/beets-alternatives) custom tags. Configure markers in `init.lua` during plugin `setup`:

```lua
beets:setup({
  tag_markers = {
    { label = "S", field = "onsync" },
    { label = "P", field = "portable" },
  },
})
```

Each marker queries `<field>:true`. `label` values must be distinct, nonblank, unpadded strings. `field` must begin with a letter or underscore and contain only letters, digits, and underscores. Markers render in configuration order.

A marker suffix is its label plus one glyph: `●` all candidates match, `◐` some match, `○` none match, `…` pending, `!` unavailable, or `—` not applicable. Marker status does not alter collection membership or exclusion behavior. A marker-query failure affects only that marker.

## Mutating actions

> **Warning:** these actions run `beet modify` and update the configured flexible attribute for beets items. Depending on beets' `modify` configuration, beets may also write the change to files.

Bind one marker action with its label as a positional argument:

```toml
[[manager.prepend_keymap]]
on = "<C-s>"
run = "plugin yazi-beets -- toggle-marker=S"
desc = "Toggle onsync"

[[manager.prepend_keymap]]
on = ["b", "s"]
run = "plugin yazi-beets -- set-marker=S"
desc = "Set onsync"

[[manager.prepend_keymap]]
on = ["b", "c"]
run = "plugin yazi-beets -- clear-marker=S"
desc = "Clear onsync"
```

`toggle-marker` clears the field when every target candidate already matches it; otherwise it sets the field. `set-marker` always sets it, and `clear-marker` always removes it.

Actions apply to every selected item, or the hovered item when there is no selection. Directories are scanned recursively; candidate exclusions and symlinks are respected. A successful action refreshes only the affected marker in the active directory, preserving collection status and its cache.
