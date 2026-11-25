# 0001: The block parser reads a node, then asks whether it was a key

- **Status:** Accepted, 2026-11-25
- **Applies to:** `src/parser.zig`
- **Commit:** `a870586`

## Context

yaml-zig is to read all of YAML 1.2.2: several documents, directives, tags,
anchors, aliases and keys of any kind.

The block parser decided what a line was before reading it: `splitKey`
searched the text for `: `, and a compact entry (`- key: value`) was handled
by rewriting its line into an indented copy. That works while a key is a plain
or quoted scalar. It does not work once a key can be a flow collection, an
alias, or a node with an anchor or tag (`&k [a, b]: v`), or once properties on
one line belong to a node that starts on a later one.

## Decision

One function reads the node at the current position and reports whether a
`:` made it a key. Block collections are told the column their entries stand
in, so a compact collection is read where it is, without rewriting lines. The
scalar readers and the flow parser, which already worked from a position in a
line, are unchanged.

## Alternatives

- **Add the new syntax to the line-classifying parser.** Smaller first
  changes, but each new form of key needs its own case wherever lines are
  classified, and comment ownership is already spread over those paths.
- **A separate tokenizer and event parser**, as libyaml has. It is the usual
  design for a complete reader, but comments, which this library exists to
  keep, would have to be carried through both stages. It would also replace
  the working scalar and flow code.

## Consequences

- The new structure was first built with no new features and compared with the
  old parser on the tests, the official suite, real files and random input.
- A key that is not wanted after all is not read twice: the caller gets the
  node and decides.
- Recursion stays bounded by `Options.max_depth`.
