# Yazi–beets integration

This context describes a Yazi plugin that helps people see whether local music paths are represented in a beets library.

## Language

**Beets item**:
An audio file registered in the beets library database.
_Avoid_: tracked file, library record

**Collection membership**:
The fact that a file path corresponds to a beets item; beets’ library database is authoritative.
_Avoid_: being under the music root

**Candidate file**:
A non-directory, non-symlink filesystem entry included in collection-membership evaluation.
_Avoid_: audio file

**Collection status**:
A classification of a candidate file or directory by observed collection membership.
_Avoid_: tracked status

**Pending collection status**:
A collection status whose evaluation has not completed; it is distinct from unavailable and is not evidence of non-membership.

**Directory collection status**:
An aggregate view of collection membership for the candidate descendants of a directory.
_Avoid_: directory membership
