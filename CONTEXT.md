# Yazi–beets integration

This context describes a Yazi plugin that helps people see whether local music paths are represented in a beets library.

## Language

**Beets item**:
An audio file registered in the beets library database.
_Avoid_: tracked file, library record

**Collection membership**:
The fact that a file path corresponds to a beets item; beets’ library database is authoritative.
_Avoid_: being under the music root

**Directory collection status**:
An aggregate view of collection membership for the relevant audio descendants of a directory.
_Avoid_: directory membership
