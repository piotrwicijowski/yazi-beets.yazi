# Manual fixture-library verification

Run this checklist in a supported Yazi installation after creating a beets fixture library with paths beneath the active directory.

- [ ] Opening a directory initially shows `…`, then completes without blocking list rendering.
- [ ] A candidate with a returned `beet list -p` path shows `●`; an unmatched candidate shows `○`.
- [ ] Re-entering the directory and the refresh binding each issue a new lookup, without polling.
- [ ] Default beets configuration works; a complete `library`/`directory` pair works; partial configuration displays `!`.
- [ ] Empty, all-collected, all-uncollected, mixed, and symlink-containing directories have the documented aggregate status.
- [ ] The opt-in selected-entry card has the correct path, library identity, status explanation, counts, and unavailable recovery guidance.
- [ ] Removing the opt-in previewer rule restores Yazi's ordinary preview.
