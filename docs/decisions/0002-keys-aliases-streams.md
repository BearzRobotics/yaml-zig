# 0002: Keys are values, aliases are references, streams are separate

- **Status:** Accepted, 2026-11-25
- **Applies to:** the data model (`src/value.zig`, `src/root.zig`)

## Context

Complete YAML has keys of any kind, nodes referred to more than once, and
streams of several documents. The model had string keys, a plain tree and one
document.

## Decisions

**A key is a `Value`.** Keys are equal as YAML defines it: the same tag and
canonical content. `get`, `getInt` and the other lookups by text remain. The
alternative, string keys with the others held apart, would have left every
user two kinds of key to handle.

**An alias is a reference, `Value.alias`, to an `Anchor`.** It is never
expanded. Reading and writing therefore cost what the text costs, whatever the
aliases could unfold to. Lookups follow one alias at a time. Replacing an
anchored value keeps the anchor in that place, so editing through any name
changes the one node. Writing checks that every alias would read back as the
node it stands for, and fails otherwise.

Comparing and hashing keys are the only places that go through aliases. An
anchor's hash is computed once, when its node is complete, and one comparison
has one allowance of work and depth.

**`Stream` is separate from `Document`.** `Document.parse` still reads exactly
one document and refuses more, so existing callers cannot silently get only
the first. `Stream.parse` reads them all, each into an arena of its own.

## Consequences

- `Value` has a fourth case, and `Map.entries` changed type: code that
  switches on every case or reads the entries directly must be updated.
- Code that walks a tree and follows aliases must bound the walk.
- A key must not be changed while it is in a map.
