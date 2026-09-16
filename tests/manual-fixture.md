# Manual fixture-library verification

Run this checklist in a supported Yazi installation after creating a beets fixture library with paths beneath the active directory.

## Fixture setup

Configure two flexible attributes on fixture items: `onsync` and `portable`. Put at least two candidate files in one directory, with one matching each attribute and one not matching it, so the directory is mixed for both queries. Set `onsync:true` as an **album-level** flexible attribute for one album and confirm its item path is returned by `beet list -p onsync:true`.

Configure the plugin with both markers:

```lua
beets:setup({
  tag_markers = {
    { label = "S", query = "onsync:true" },
    { label = "P", query = "portable:true" },
  },
})
```

## Checklist

- [ ] Opening a directory initially shows collection and tag-marker `…` values, then completes without blocking list rendering.
- [ ] A candidate with a returned `beet list -p` path shows collection `●`; an unmatched candidate shows collection `○`.
- [ ] `S` and `P` reflect their separate flexible attributes. The album-level `onsync:true` attribute yields `S●` for its item, and the prepared directory displays a mixed marker (`S◐` or `P◐`) where appropriate.
- [ ] Tag markers remain independent of collection membership: a collected candidate can show `S○`, and an uncollected candidate can show `P●`.
- [ ] Temporarily configure one invalid marker query while retaining a valid marker. Only the invalid marker shows `!` and its selected-entry-card line explains the failure; collection status and the valid marker remain truthful.
- [ ] Change a fixture flexible attribute, then use the `plugin yazi-beets` refresh binding (for example `Ctrl-r`). The affected tag marker updates, proving refresh ran every configured tag query rather than reusing stale results.
- [ ] Re-entering the directory and the refresh binding each issue a new lookup, without polling.
- [ ] Default beets configuration works; a complete `library`/`directory` pair works; partial configuration displays `!`.
- [ ] Empty, all-collected, all-uncollected, mixed, and symlink-containing directories have the documented aggregate status.
- [ ] Case-insensitive extension exclusions and case-sensitive subdirectory exclusions show `—`, do not affect ancestors, and skip `beet` when every candidate is excluded.
- [ ] A malformed exclusion list displays `!` before directory scanning or a `beet` command runs.
- [ ] A malformed `tag_markers` array appends `tags!`, shows its validation reason in the selected-entry card, and does not prevent collection status from completing.
- [ ] The opt-in selected-entry card has the correct path, library identity, status explanation, counts, tag-marker lines, and unavailable recovery guidance.
- [ ] Removing the opt-in previewer rule restores Yazi's ordinary preview.
