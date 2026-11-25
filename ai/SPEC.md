# yaml-zig — Specification

**Status:** 0.3.0, implemented and tested; see "Known deviations and limits".

## Purpose

Read YAML (notably Solus `package.yml`) and write it back without losing comments, as a complete YAML library. Reference: YAML 1.2.2, https://yaml.org/spec/1.2.2/ (source https://github.com/yaml/yaml-spec). Scalar typing follows the core schema (section 10.3).

## Requirements

- **YAML-1 (MUST):** Read the YAML 1.2.2 syntax: block and flow collections, every scalar style, comments, several documents in a stream, `%YAML` and `%TAG` directives, tags, anchors and aliases, and keys of any kind (including `?` entries and collections as keys). Input is UTF-8, UTF-16 or UTF-32 (section 5.2); LF, CR LF and CR end lines.
- **YAML-2 (MUST):** Reject invalid input with `error.Syntax` (or `error.InvalidUtf8` for bytes that are not text) rather than misreading it: repeated keys (equal by tag and canonical content, 3.2.1.3), bad indentation, tabs as indentation, indicators where a scalar cannot start, `: ` inside a plain scalar, document markers inside a scalar, non-printable characters, a byte order mark inside a document, bad escapes, headers, directives, tags, anchors and undefined aliases.
- **YAML-3 (MUST):** Untrusted input: time and memory in proportion to the input. Bounded nesting (`Options.max_depth`, 64 collections, block and flow together), bounded size (`Options.max_bytes`, 16 MiB, which also limits the total length of expanded tag names), at most 64 `%TAG` directives in a document, aliases never expanded, bounded work to compare keys; no undefined behavior or stack overflow on malformed or hostile input; no leaks or swallowed errors on allocation failure (tested).
- **YAML-4 (MUST):** Report the first error with a 1-based line, a 1-based byte column and a static message (`Diagnostic`). For some errors in a block collection's structure the column is that of the line's first character. For input that was not UTF-8, columns count bytes of its UTF-8 form.
- **YAML-5 (MUST):** Comments survive parse → edit → write: comment and blank lines before an item, a trailing comment on its line, comments on a root scalar or flow collection, the comment on the `---` line, and comments after the last item of a document or stream. They stay with their item, are dropped with a removed key, and can be set with `Document.setComments`. Where a comment cannot keep its place it moves rather than disappears, except inside flow collections (below).
- **YAML-6 (MUST):** The written text is UTF-8 of printable characters and parses back, with the same options, to an equal tree: values, kinds, order, tags, anchors and aliases, document by document. What cannot be written that way is an error before anything is written (`InvalidUtf8`, `NestingTooDeep`, `InvalidDirective`, `InvalidTag`, `InvalidAnchor`, `BrokenAlias`). Strings and keys created through the API are quoted when plain text would read as another type or break the syntax.
- **YAML-7 (SHOULD):** Plain scalars keep their text (`7.20`, `0x1F`); scalars and keys keep their quotes; tags, anchors and directives are kept; the writer keeps the source's indentation step.
- **YAML-8 (SHOULD):** No dependencies beyond the Zig standard library. Met.

## Conformance

`scripts/fetch-conformance.sh` downloads the official suite, https://github.com/yaml/yaml-test-suite (not vendored), and `zig build conformance -Dsuite=conformance-suite` runs it (see `test/conformance.zig`). At tag `data-2022-01-17`, of 402 cases:

| Result | Cases |
|---|---:|
| Pass: read with the structure in `test.event` (and the value in `in.json`, where there is one), written and read back the same, or invalid input rejected | 400 |
| Rejected on purpose: a repeated key (2JQS, X38W) | 2 |
| Fail | 0 |
| Refused as unsupported | 0 |

An invalid case counts as passing whichever error rejects it. The comparison leaves out whether a document's `---` and `...` were written. Passing the suite does **not** prove full conformance: it cannot cover every input, and the deviations below are known.

## Known deviations and limits

Accepted although YAML 1.2.2 forbids it:

- A closing `]` or `}` in the column of the block node's parent (`os: [` ... `]` lined up under `os`). It is common in real files and libyaml-based readers accept it. Any other content in that column is rejected.
- A key longer than 1024 characters before its `:`. (The writer uses the `?` form for long keys of block mappings.)
- A standard tag on content that does not match it (`!!int abc`, `!!seq` on a scalar). The tag is kept; for a scalar, the typed lookups return null.

Refused although it may be valid:

- A key that holds an alias of a node that contains the key (`&a [*a]: x`): `error.Unsupported`.
- Anything beyond the limits in YAML-3: `error.LimitExceeded`. Two keys that cannot be told apart within the comparison limit (65,536 nodes, 128 levels) count as too large.

Not interpreted:

- Tags outside the core schema are kept on their node; a scalar with one is a string.
- `<<` merge keys belong to YAML 1.1 types, not to 1.2. `<<` is an ordinary key.
- A `%YAML 1.1` document is read by the 1.2 rules (so `yes` is a string). Reserved directives are kept and ignored.
- Aliases are references (`Value.alias`). A caller that follows them must bound how far: a node can contain itself, and a few lines can stand for an enormous tree.

Writing:

- Output is UTF-8, whatever the input was.
- Folded scalars are written as literal (same value). A sequence indented like its key is written one step in. Spacing around `:` is normalized. A single document is written without `...`; a stream writes it where needed.
- An explicit `?` entry whose key fits on one line is written as `key: value`. Its comments are kept, moving above the item if there is not room for them.
- Comments inside a flow collection are dropped, except that the last one moves after the closing bracket if that line has none.
- Comments between two documents belong to the second unless a `...` separates them.
- A flow collection that comes to hold a block collection or a comment is written in block style.
- Some valid output, such as an empty key in a flow mapping (`{: v}`), is not read by every YAML library.

Editing:

- A collection used as a key must not be changed while it is in its map, and neither should an anchored node that a key reaches through an alias: key lookups and duplicate checks rely on it.
- A whole stream is read into memory (the input is split into lines); `parseReader` reads it all first.
