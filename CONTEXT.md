# Yazi–beets integration

This context describes a Yazi plugin that helps people see whether local music paths are represented in a beets library.

## Language

**Beets item**:
An audio file registered in the beets library database.
_Avoid_: tracked file, library record

**Flexible attribute**:
A user-defined beets database field, queried with the ordinary `field:value` syntax. An `alternatives` selection may match an item-level or album-level flexible attribute.
_Avoid_: custom tag (ambiguous with on-disk metadata tags)

**Collection membership**:
The fact that a file path corresponds to a beets item; beets’ library database is authoritative.
_Avoid_: being under the music root

**Tag marker**:
A labelled beets item query displayed independently alongside collection status.
_Avoid_: collection marker

**Tag status**:
A classification of a candidate file or directory by whether its paths match one tag marker’s query.
_Avoid_: collection status

**Candidate file**:
A non-directory, non-symlink filesystem entry included in collection-membership evaluation.
_Avoid_: audio file

**Candidate exclusion**:
A configured rule that removes a filesystem entry or subtree from collection-membership evaluation; excluded entries report not applicable and do not contribute to directory collection status.
_Avoid_: ignored audio file

**Collection status**:
A classification of a candidate file or directory by observed collection membership.
_Avoid_: tracked status

**Pending collection status**:
A collection status whose evaluation has not completed; it is distinct from unavailable and is not evidence of non-membership.

**Directory collection status**:
An aggregate view of collection membership for the candidate descendants of a directory.
_Avoid_: directory membership
