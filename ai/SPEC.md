# yaml-zig — Specification

**Status:** 0.2.0, implemented and tested within the subset below; see "Known deviations and limits".

## Purpose

Read YAML (notably Solus `package.yml`) and write it back without losing comments. Reference: YAML 1.2.2, https://yaml.org/spec/1.2.2/ (source https://github.com/yaml/yaml-spec). Scalar typing follows the core schema (section 10.3).

## Requirements

- **YAML-1 (MUST):** Read block mappings and sequences (a sequence may sit at its key's column), plain, single- and double-quoted scalars (with escapes, over several lines), literal and folded block scalars with chomping and indentation indicators, flow sequences and mappings (including single `key: value` pairs in sequences), empty keys, an optional `---` (which may be followed by a scalar or flow collection on its line) and `...`. Tabs are accepted wherever YAML allows them, and LF, CR LF and CR end lines.
- **YAML-2 (MUST):** Reject, with `error.Unsupported`, anchors, aliases, tags, directives, complex keys (`? `, or a collection used as a key) and multiple documents rather than misreading them. Reject invalid input (duplicate keys, bad indentation, tabs as indentation, indicators where a scalar cannot start, `: ` inside a plain scalar, document markers inside a scalar, non-printable characters, bad escapes and block headers, unterminated scalars, invalid UTF-8) with `error.Syntax` / `error.InvalidUtf8`.
- **YAML-3 (MUST):** Untrusted input: bounded nesting (`Options.max_depth`, 64 collections, block and flow together), bounded size (`Options.max_bytes`, 16 MiB), parse time linear in the input, no undefined behavior on malformed bytes (random-input tests), no leaks or swallowed errors on allocation failure (tested).
- **YAML-4 (MUST):** Report the first error with a 1-based line, a 1-based byte column and a static message (`Diagnostic`). For an error in a block collection's structure the column is that of the line's first character.
- **YAML-5 (MUST):** Comments survive parse → edit → write: comment and blank lines before an item, a trailing comment on its line, comments on a root scalar or flow collection, the comment on the `---` line, and comments after the last item. They stay with their item, are dropped with a removed key, and can be set with `Document.setComments`. Where a comment cannot keep its place it moves rather than disappears, except inside flow collections (below).
- **YAML-6 (MUST):** The written text is valid UTF-8 of printable characters and parses back, with the same options, to an equal tree (values, kinds, key order). What cannot be written that way is an error (`InvalidUtf8`, `NestingTooDeep`). Strings and keys created through the API are quoted when plain text would read as another type or break the syntax.
- **YAML-7 (SHOULD):** Plain scalars keep their text (`7.20`, `0x1F`); quoted keys stay quoted; the writer keeps the source's indentation step.
- **YAML-8 (SHOULD):** No dependencies beyond the Zig standard library. Met.

## Conformance

`zig build conformance -Dsuite=PATH` runs the official suite, https://github.com/yaml/yaml-test-suite (not vendored; see `test/conformance.zig`). At tag `data-2022-01-17`, of 402 cases:

| Result | Cases |
|---|---:|
| Pass: read to the expected value and written back to the same value, or invalid input rejected | 292 |
| Valid input refused with `error.Unsupported` | 109 |
| Rejected on purpose: duplicate keys (2JQS) | 1 |
| Fail | 0 |

An invalid case counts as passing whichever error rejects it. Where a case has no `in.json`, only acceptance and the round trip are checked, not the value. This is therefore **not** a claim of full YAML 1.2.2 conformance: the unsupported features are a large part of the language.

## Known deviations and limits

- **Accepted although YAML 1.2.2 forbids it:** a closing `]` or `}` in the column of the block node's parent (`os: [` ... `]` lined up under `os`). It is common in real files and libyaml-based readers accept it. Any other content in that column is rejected.
- Not read: the features listed under YAML-2. Keys are always strings (a key `1` is the text `1`, and `1:` and `"1":` in one mapping are duplicates).
- Folded scalars are written as literal (same value). A sequence indented like its key is written one step in. Spacing around `:` is normalized. The `...` marker is not written.
- Comments inside a flow collection are dropped, except that the last one moves after the closing bracket if that line has none.
- A flow collection that comes to hold a block collection or a comment is written in block style.
- A whole document is read into memory (the input is split into lines); `parseReader` reads it all first.
