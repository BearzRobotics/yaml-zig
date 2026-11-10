# yaml-zig — Specification

**Status:** 0.1.0, implemented and tested; see "Known deviations".

## Purpose

Read YAML (notably Solus `package.yml`) and write it back without losing comments. Reference: YAML 1.2.2, https://yaml.org/spec/1.2.2/ (source https://github.com/yaml/yaml-spec). Scalar typing follows the core schema (section 10.3).

## Requirements

- **YAML-1 (MUST):** Read block mappings and sequences (a sequence may sit at its key's column), plain, single- and double-quoted scalars (with escapes, over several lines), literal and folded block scalars with chomping and indentation indicators, flow sequences and mappings, an optional `---` and `...`.
- **YAML-2 (MUST):** Reject, with `error.Unsupported`, anchors, aliases, tags, directives, complex keys and multiple documents rather than misreading them. Reject invalid input (duplicate keys, bad indentation, tabs as indentation, unterminated scalars, invalid UTF-8) with `error.Syntax` / `error.InvalidUtf8`.
- **YAML-3 (MUST):** Untrusted input: bounded nesting (`Options.max_depth`, 64), bounded size (`Options.max_bytes`, 16 MiB), no undefined behavior on malformed bytes (random-input test), no leaks on allocation failure (tested).
- **YAML-4 (MUST):** Report the first error with a 1-based line and a static message (`Diagnostic`).
- **YAML-5 (MUST):** Comments survive parse → edit → write: comment and blank lines before an item, a trailing comment on its line, comments before `---`, and after the last item. They stay with their item, are dropped with a removed key, and can be set with `Document.setComments`.
- **YAML-6 (MUST):** The written text parses back to an equal tree (values, kinds, order). Strings created through the API are quoted when plain text would read as another type or break the syntax.
- **YAML-7 (SHOULD):** Plain scalars keep their text (`7.20`, `0x1F`); the writer keeps the source's indentation step.
- **YAML-8 (SHOULD):** No dependencies beyond the Zig standard library. Met.

## Known deviations and limits

- The official yaml-test-suite is not vendored and has **not** been run. Treat conformance beyond the listed subset as unverified.
- Folded scalars are written as literal (same value). A sequence indented like its key is written one step in. Spacing around `:` is normalized. Comments inside flow collections are dropped.
- A whole document is read into memory (the input is split into lines); `parseReader` reads it all first.
- Keys are always strings (a key `1` is the text `1`).
