# Architecture

This describes the code as it is in 0.3.1: how the parts fit, how data moves,
and what must stay true when changing them. The requirements are in
`ai/SPEC.md`, the reasons for two large choices in `docs/decisions/`, and the
public interface in `docs/manpages/`.

```
              bytes (UTF-8, -16, -32)
                       |
   parser.zig   Reader: detect encoding, decode, split into lines
                       |
                Parser (block structure) <---> Flow ([...] and {...})
                       |                 one Result per document
   root.zig     Document / Stream  ---- each Document owns one arena
                       |
                edits: set, setComments, Map and Seq methods
                       |
   writer.zig   Checker: can all of it be written and read back?
                       |
                Gen: write block and flow YAML, with comments
                       |
                  std.Io.Writer (UTF-8)

   value.zig    the data model and the rules reader and writer share
```

| File | Role |
|---|---|
| `src/root.zig` | The public API: `Document`, `Stream`, building and path editing |
| `src/value.zig` | `Value`, `Scalar`, `Seq`, `Map`, `Anchor`, `Comments`; core schema typing; equality and hashing of keys; the grammar of directives, tags and anchor names; comment validation |
| `src/parser.zig` | `Reader`, `Parser`, `Flow`; limits and diagnostics |
| `src/writer.zig` | `Checker` and `Gen` |
| `src/tests.zig` | The tests |
| `test/conformance.zig` | Runner for the official yaml-test-suite |
| `scripts/fetch-conformance.sh` | Downloads the suite at a fixed commit into an ignored directory |

There are no dependencies beyond the Zig standard library, and no global
mutable state.

## Data model

```
Value = scalar: Scalar            by value
      | seq:    *Seq              items + one Comments per item (same length)
      | map:    *Map              entries: Value -> { value, comments }
      | alias:  *Anchor           a reference, never expanded

Scalar, Seq, Map  --anchor-->  Anchor { name, value }  <--  every alias of it
```

- A tag is stored in full on its node. A scalar's `kind` follows from its tag,
  style and text (`kindOf`).
- A scalar keeps its text and style, so it can be written as it was.
- An anchor "stays with its place": `replaceNode`, used by `Map.put`,
  `Map.putValue` and `Document.set`, moves it to the new node.

### Keys

`Map.entries` is an array hash map in insertion order, keyed by `Value` with
`KeyContext`. Keys are equal by effective tag and canonical content: numbers by
value, any spelling of a boolean or null, mappings regardless of order.

Comparing and hashing keys are the only operations that recurse through
aliases, so they carry the defences:

- An anchor's hash is computed once, by `sealAnchor`, when the parser has read
  the whole node. Anchors and aliases inside it are already hashed, so hashing
  never follows a chain of aliases. An unfinished anchor hashes to a constant.
- One comparison (`compareKeys`) has one allowance, 65,536 steps and 128
  levels, shared by every nested comparison. A mapping is compared by searching
  the other's keys with that same allowance, not through its index, whose
  lookups would each start a new one.
- Running out gives `.too_large`. `eql` treats that as equal, so that nothing
  more is compared, and the parser reports `LimitExceeded`.

`Map.find` looks a key up by text: first as a string, then as the type the text
spells. Tagged keys and alias keys may hash differently from their text;
`odd_keys` makes `find` fall back to a linear search for those.

## Reading

`Reader.init` checks the size, recognises and decodes UTF-16 and UTF-32, and
splits the text into lines (LF, CR LF or CR). Each call to `Reader.next` reads
one document into the arena it is given.

### Block structure

The parser's position is a line number, `pos`; within a line, functions are
passed the rest of it as a slice, from which `columnOf` gets the column.

| Function | Does |
|---|---|
| `document` | Prefix, directives, `---`, the root node, `...` |
| `block` | A node on the following lines, indented past its parent |
| `collectionOrNode` | What starts at a position where a block collection may start |
| `takeProps` | Reads `&anchor` and `!tag` before a node |
| `readNode` | Reads a node, **then** reports whether a `:` made it a key |
| `sequence`, `mapping` | Collections whose entries stand in a given column |
| `indented` | What follows `-`, `?` or an explicit `:` |
| `explicitEntry`, `implicitValue` | The two forms of mapping entry |
| `plainScalar`, `gatherQuoted`, `blockScalar` | The scalar styles |
| `flowNode` | A flow collection, as a value or a key |

`readNode` is the central choice (decision 0001): the parser does not guess
what a line is before reading it. A collection that starts after `- ` is told
its column, so no line is ever rewritten.

Properties on a line of their own belong to the node that follows. On the same
line as a key they belong to the key, not to the mapping it starts.

`Flow` is a cursor of its own over the same lines. Its `skip` passes blanks,
comments and line breaks, and enforces the indentation of continuation lines.

### Comments

Comments are the part most easily broken. The rules:

- `skipBlank` collects comment and blank lines in `pending`. They are slices of
  the source, because the document that will own them may not be known yet;
  whoever takes them copies them into its arena (`takeBefore`, `footerLines`).
- A comment after a value on its line goes to `trailing`. **Every path that
  reads a value must take it**, or it is lost or given to another item.
- `commentsAround` handles a value that starts below its `key:` or `-`: if the
  value is one node (a scalar, alias or flow collection), the comments around
  it have no other owner than the item.
- **An empty item must not take the comments that follow it.** `block` uses
  `nodeFollows`, and `own_pending` when only property lines were there.

### Errors and limits

`failAt` fills the `Diagnostic` with a static message. Recursion is bounded
because every collection passes `enter`, which counts toward `max_depth`;
collections used as keys are counted too (`levelsIn`).

| Limit | Where |
|---|---|
| `max_bytes` (input) | `Reader.init`, `parseReader` |
| `max_bytes` (total expanded tag names) | `readTag` |
| `max_depth` | `enter`, `enterAt`, the checks using `levelsIn`; `Checker` |
| 64 `%TAG` directives | `document`, `TagTable.init` |
| Key comparison | `compare` in `value.zig` |

## Writing

`writer.check` runs over everything before the first byte is written. With
`Stream`, all documents are checked first. It verifies:

- UTF-8 everywhere, and that **every comment field holds only comments**: they
  are public and are copied to the output as they are;
- nesting within `max_depth`, which also stops a collection that contains
  itself;
- directives, and that each tag has a written form;
- anchor names, and that each alias will read back as the same node.

`Gen` then writes. The main decisions:

- `isInline`: a collection stays in flow style only if nothing would be lost,
  that is, it holds no block collection and no comment.
- `needsExplicitKey`: the `?` form for block collection keys, block scalar
  keys and long keys.
- `plainOk`: whether plain text would read back with the same kind; if not,
  the scalar is quoted.
- `looksLikeMarker`: `---` and `...` are quoted at column 0.
- `drop_blank`, `blank_written`: empty comment lines that the reader would
  drop, merge or read as part of a `|+` block are not written.

**The invariant:** whatever is written parses to an equal tree. Anything that
adds a way to write output must keep it, and needs a check in `Checker` if a
caller can build something that would break it.

## Memory and ownership

Each `Document` has an arena that owns everything in it; nothing is freed
singly. The parser uses the caller's allocator for what lives only while
parsing: the line list, decoded input, pending comments and one reused scratch
buffer. `check` takes temporary memory from the allocator that backs the
document's arena. See RESOURCE USAGE in **yaml-zig**(3) for measurements.

## Testing

| What | How |
|---|---|
| Behaviour and regressions | `zig build test` (`src/tests.zig`) |
| Allocation failure | `std.testing.checkAllAllocationFailures` over parsing, writing, editing and reading |
| Round trips | A test feeds random YAML tokens and requires each accepted input to read back equal and be written the same twice |
| Hostile input | Tests for the former quadratic paths, alias expansion, key comparison, deep alias chains and tag expansion |
| The specification | `zig build conformance -Dsuite=conformance-suite`, comparing the suite's event streams and JSON |

The conformance step needs the suite, so `zig build test` only compiles it.

Before the 0.3.x releases, longer random testing, deliberate breaking of
safeguards to see that a test fails, and comparisons with earlier releases and
with PyYAML were also run. Those tools are not in the repository.

## Known weak spots

- Writing twice can change indentation: the step is learned from the first
  nested block, and if that is a mapping the writer moves onto its `-` line,
  the second write has nothing to learn it from. Values are unaffected.
- Copying an anchored node to a second place writes its anchor twice (see
  CAVEATS in **yaml-zig**(3)).
- A key changed in place, or an anchored node changed while an alias key
  refers to it, leaves hashes stale.
