# NAME

yaml-zig - YAML 1.2 reader, editor and writer for Zig that keeps comments

# SYNOPSIS

```zig
const yaml = @import("yaml");

var diag: yaml.Diagnostic = .{};
var doc = try yaml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();

const name = doc.root.map.getString("name");
try doc.set(&.{"release"}, try doc.integer(101));
const out = try doc.toOwnedString(gpa); // caller frees
```

Build setup:

```sh
zig fetch --save=yaml https://github.com/BearzRobotics/yaml-zig/releases/download/v0.3.1/yaml-0.3.1.tar.gz
```

```zig
// build.zig
exe.root_module.addImport("yaml", b.dependency("yaml", .{}).module("yaml"));
```

# DESCRIPTION

yaml-zig reads YAML into a tree, lets a program inspect and change the tree,
and writes it back as YAML with the author's comments. It targets Zig 0.17 and
depends only on the standard library. It performs no file-system or
operating-system calls itself: input comes from a byte slice or a
`std.Io.Reader`, output goes to any `std.Io.Writer`.

`Document` holds one YAML document. `Stream` holds all the documents of a
file. The YAML that is read, and how it is written back, is described in
**yaml-syntax**(5).

# CONVENTIONS

`gpa` is a `std.mem.Allocator`. A value described as *arena-owned* lives in a
document's arena and is invalid after that document's `deinit`. Function names
are given as `Type.function`.

A *path* is a slice of segments, such as `&.{ "servers", "0", "port" }`. In a
mapping a segment is the text of a key. In a sequence it is a decimal index.

# TYPES

## Values

**Value**
: A tagged union: `scalar: Scalar`, `seq: *Seq`, `map: *Map`,
  `alias: *Anchor`.

**Scalar**
: `text: []const u8`, `style: Style`, `kind: Kind`, `tag: ?[]const u8`,
  `anchor: ?*Anchor`. `text` is the value: a plain scalar exactly as written
  (`7.20`, `0x1F`), any other after unescaping and folding.

**Kind**
: What a scalar means: `.null`, `.boolean`, `.integer`, `.float`, `.string`.

**Style**
: How a scalar is written: `.plain`, `.single`, `.double`, `.literal`,
  `.folded`.

**Seq**
: `items: std.ArrayList(Value)`, `comments: std.ArrayList(Comments)`,
  `flow: bool`, `tag`, `anchor`. `items` and `comments` must stay the same
  length.

**Map**
: An insertion-ordered mapping: `entries: Map.Entries` (from a key `Value` to a
  `Map.Entry`), `flow: bool`, `tag`, `anchor`. The field `odd_keys` is
  maintained by `putValue` for the library's own use.

**Map.Entry**
: `value: Value` and `comments: Comments`.

**Anchor**
: `name: []const u8` and `value: Value`, the anchored node, which is never
  itself an alias. The fields `complete` and `hash` are for the library's own
  use.

**Comments**
: `before: []const []const u8`, the lines above an item (each `#...`, or empty
  for a blank line), and `after: ?[]const u8`, a `#...` comment on its line.
  `isEmpty()` is true when there are neither.

## Reading

**Options**
: `max_depth: u32 = 64`, the most collections nested in one another;
  `max_bytes: usize = 16 * 1024 * 1024`, the largest input, which also limits
  the total length of the tag names that `%TAG` prefixes expand to.

**Diagnostic**
: `line: usize`, `column: usize` (both 1-based; the column counts bytes) and
  `message: []const u8`, a static string. Prints as `line:column: message` with
  `{f}`.

# FUNCTIONS

## Document

**Document** owns one arena. Every string, sequence, mapping and anchor
reachable from its root is allocated there. Its fields:

| Field | Meaning |
|---|---|
| `arena` | The arena itself. |
| `root: Value` | The document's node. Never an alias after parsing. |
| `indent: u8` | Spaces per level when written. Learned from the source; 2 otherwise. |
| `explicit_start: bool` | Written with `---`. |
| `explicit_end: bool` | The source closed the document with `...`. Used by `Stream`. |
| `directives` | `%YAML` and `%TAG` lines, as text. |
| `header` | Comment lines above `---`. |
| `start_comment: ?[]const u8` | The comment on the `---` line. |
| `root_comments: Comments` | Comments on a root that is a scalar or flow collection. |
| `footer` | Comment lines after the last item. |
| `max_depth: u32` | The deepest nesting `write` accepts. Taken from `Options`. |

Comment fields use the same form as `Comments`. They may be assigned directly;
`write` checks them all and fails with `InvalidComment` if one holds anything
but comments. Strings assigned to any field must be arena-owned or outlive the
document.

### Creating and destroying

`Document.init(gpa) !Document`
: A document whose root is an empty mapping, for building one.

`Document.parse(gpa, source, options, diag) ParseError!Document`
: Parse `source`, which holds at most one document, in UTF-8, UTF-16 or
  UTF-32. The slice is not retained. With no document in it, the root is a
  null scalar. A second document is `error.Unsupported`. `diag` may be `null`.

`Document.parseReader(gpa, reader, options, diag) ParseReaderError!Document`
: Read everything from a `*std.Io.Reader`, then parse it. The input is held in
  memory whole. Fails with `LimitExceeded` past `options.max_bytes`, and with
  `ReadFailed` if the reader fails.

`Document.deinit()`
: Free everything. The document must not be used afterwards.

`Document.allocator() Allocator`
: The arena allocator. Use it for anything placed in the tree.

`Document.dupe(s) ![]const u8`
: Copy `s` into the arena.

### Making values

All of these return arena-owned values for use with `set`, `Map.put` or
`Seq.append`.

`Document.string(s) !Value`
: A string. It is copied. The writer quotes it if plain text would read as
  something else, and writes a string of several lines as a `|` block where it
  can. Fails with `InvalidUtf8`.

`Document.integer(i: i64) !Value`, `Document.boolean(b) Value`, `Document.nullValue() Value`
: An integer, a boolean and a null.

`Document.newMap() !Value`, `Document.newSeq() !Value`
: An empty mapping or sequence, in block style.

`Document.anchorNode(v: *Value, name) !*Anchor`
: Give the node `v` points to the anchor `&name`. Store `v.*` afterwards,
  not an earlier copy of it. `.{ .alias = anchor }` is an alias of the node and
  must come after it in the output. `v` must not be an alias.

### Reading and editing by path

`Document.lookup(path) ?Value`
: The value at `path`, following aliases, or `null`.

`Document.set(path, value) Document.PathError!void`
: Set the value at a non-empty path, creating mappings for missing keys on the
  way. Replacing a value keeps the item's comments, and keeps its anchor in
  that place, so aliases then stand for the new value. A path through an alias
  changes the shared node; a path ending at an alias replaces the alias only.
  `value` must be arena-owned. An existing empty value (`a:`) is a scalar, so a
  path through it fails with `NotACollection`.

`Document.setComments(path, comments) !void`
: Set the comments of the item at a non-empty path; empty `Comments` removes
  them. The strings are copied. Each line in `before` must be empty or start
  with `#`, after any blanks, and `after` must start with `#`. Fails with
  `InvalidComment`, `NotFound` or `NotACollection`.

### Writing

`Document.write(writer) WriteError!void`
: Write YAML to a `*std.Io.Writer`. The tree is checked first, so an error
  other than `WriteFailed` means nothing was written.

`Document.toOwnedString(gpa) ToStringError![]u8`
: The YAML text. The caller frees it with `gpa`.

## Stream

**Stream** holds `documents: []Document`, each with an arena of its own, and
`comments`, the comment lines of a stream that has no document. Its other
fields (`gpa`, `comment_arena`) hold that storage.

`Stream.parse(gpa, source, options, diag) ParseError!Stream`
: Parse every document in `source`. `options.max_bytes` limits the whole
  input. Empty input gives no documents.

`Stream.deinit()`
: Free the stream and every document in it.

`Stream.write(writer) WriteError!void`, `Stream.toOwnedString(gpa) ToStringError![]u8`
: Write all documents, adding the `---` and `...` lines needed to keep them
  apart. All are checked before anything is written.

Documents may be edited, reordered or have `explicit_start` changed. A value
must not be moved from one document into another: it belongs to the first
one's arena, and anchors belong to one document.

## Value

`Value.deref() Value`
: The node an alias stands for; any other value unchanged.

`Value.anchorOf() ?*Anchor`
: The anchor on this node. An alias has none of its own.

`Value.typeName() []const u8`
: `"null"`, `"boolean"`, `"integer"`, `"float"`, `"string"`, `"sequence"` or
  `"mapping"`, following an alias.

## Scalar

`Scalar.asBool() ?bool`, `Scalar.asInt() ?i64`, `Scalar.asFloat() ?f64`
: The value, or `null` if the scalar is not of that kind or does not fit.
  `asFloat` also accepts integers, including ones too large for `asInt`, with
  the usual loss of precision.

`Scalar.isNull() bool`
: Whether its kind is `.null`.

## Map

Functions that take `key` as text find a scalar key written exactly that way.
If there are several, such as `1` and `"1"`, the string key wins.

`Map.count() usize`
: The number of entries.

`Map.keys() []const Value`
: The keys, in order.

`Map.find(key) ?usize`
: The position of the entry with that key.

`Map.get(key) ?Value`
: The value, following an alias.

`Map.getPtr(key) ?*Value`
: Where the value is stored, as written, so possibly an alias. Valid until the
  map next changes.

`Map.getValue(key: Value) ?Value`
: As `get`, for a key of any kind, compared as YAML compares keys.

`getString`, `getInt`, `getFloat`, `getBool`, `getMap`, `getSeq`
: Typed lookups. Each returns `null` both when the key is absent and when the
  value is of another type. `getString` returns the text of any scalar: `""`
  for an empty value.

`Map.put(arena, key, value) !void`
: Set the value under the key written `key`, keeping that key and its comments,
  or add `key` as a string. `key` and `value` must be arena-owned.

`Map.putValue(arena, key: Value, value) !void`
: The same for a key of any kind.

`Map.remove(key) bool`, `Map.removeValue(key: Value) bool`
: Remove an entry and its comments, keeping the order of the rest. True if
  there was one.

`Map.commentsOf(key) ?Comments`
: The entry's comments, or `null` if it has none.

`Map.setComments(key, comments) !void`
: Set the comments of an existing key. The strings are **not** copied and must
  be arena-owned. Fails with `InvalidComment` or `NotFound`.

## Seq

`Seq.append(arena, value) !void`
: Add an item without comments. Prefer this to appending to `items`.

# ERRORS

`ParseError`, from `parse`:

| Error | Meaning |
|---|---|
| `Syntax` | The input is not valid YAML, including a repeated key. |
| `Unsupported` | A key holds an alias that leads back into it, or `Document.parse` was given several documents. |
| `InvalidUtf8` | The bytes are not valid UTF-8, UTF-16 or UTF-32. |
| `LimitExceeded` | Nesting, input size, tag names, `%TAG` count, or keys too large to compare. |
| `OutOfMemory` | Allocation failed. |

`ParseReaderError` adds `ReadFailed`.

`WriteError`, from `write`, and `ToStringError`, from `toOwnedString`:

| Error | Meaning |
|---|---|
| `InvalidUtf8` | A string in the tree is not UTF-8. |
| `InvalidComment` | A comment field holds something that is not a comment (see `Document.setComments`). |
| `NestingTooDeep` | Collections nest beyond `max_depth`, or contain themselves other than through an alias. |
| `InvalidDirective` | A line in `directives` is not a directive, or there are more than 64 `%TAG` lines. |
| `InvalidTag` | A tag has no written form that reads back. |
| `InvalidAnchor` | An anchor name is empty or has blanks or `[]{},`. |
| `BrokenAlias` | An alias would not read back as the node it stands for: that node is gone, comes later, or another took its name. |
| `OutOfMemory` | Allocation failed. |
| `WriteFailed` | The writer failed. |

`Document.PathError` is `NotACollection`, `NotFound` (a bad sequence index, or
a missing item for `setComments`), `InvalidUtf8` or `OutOfMemory`.

# OWNERSHIP AND LIFETIME

A document owns everything in its tree and frees it in `deinit`. Slices and
pointers returned by lookups point into the arena. Edits do not free what they
replace; the memory is reclaimed by `deinit`. A program that edits one
long-lived document without end will therefore grow.

# EXAMPLES

## Edit a recipe

```zig
var doc = try yaml.Document.parse(gpa, "# recipe\nname: nano\nrelease: 100 # bump\n", .{}, null);
defer doc.deinit();
try doc.set(&.{"release"}, try doc.integer(101));
const out = try doc.toOwnedString(gpa);
defer gpa.free(out);
// # recipe
// name: nano
// release: 101 # bump
```

## Report a parse error

```zig
var diag: yaml.Diagnostic = .{};
var doc = yaml.Document.parse(gpa, text, .{}, &diag) catch |err| {
    std.log.err("config.yml:{f} ({t})", .{ diag, err });
    return err;
};
defer doc.deinit();
```

## Several documents

```zig
var stream = try yaml.Stream.parse(gpa, "a: 1\n---\na: 2\n", .{}, null);
defer stream.deinit();
var total: i64 = 0;
for (stream.documents) |*document| total += document.root.map.getInt("a") orelse 0;
```

## Walk a mapping

```zig
for (map.entries.keys(), map.entries.values()) |key, entry| {
    // `entry.value` is as written; `deref` follows an alias one step.
    if (key == .scalar) std.log.info("{s}: {s}", .{ key.scalar.text, entry.value.typeName() });
}
```

## Make an anchor and an alias

```zig
var doc = try yaml.Document.init(gpa);
defer doc.deinit();
var defaults = try doc.newMap();
try defaults.map.put(doc.allocator(), "retries", try doc.integer(3));
const anchor = try doc.anchorNode(&defaults, "defaults");
try doc.set(&.{"base"}, defaults);
try doc.set(&.{"job"}, .{ .alias = anchor });
// base: &defaults
//   retries: 3
// job: *defaults
```

# SECURITY CONSIDERATIONS

Input is limited in nesting (`max_depth`), size (`max_bytes`), expanded tag
length, `%TAG` count and the work spent comparing keys. The tests include
random and hostile input. This is not a proof that no input can cause trouble.

**Memory can be far larger than the input.** See RESOURCE USAGE, and lower
`max_bytes` to what your files really need before parsing untrusted ones.

**Following aliases is your responsibility.** The library never expands them,
but a node can contain itself (`&a [*a]`), and a few hundred bytes can stand
for a tree of astronomical size (the "billion laughs" input). A function that
walks a tree through `get`, `lookup` or `deref` must limit its depth *and* the
total number of nodes it visits.

Comments cannot add content to a document: `setComments` validates them, and
`write` checks every comment field, however it was set. (Before 0.3.1, fields
assigned directly were written unchecked.) Tags are only text to this library: do not choose code to run from an
untrusted tag without a list of the tags you allow.

# RESOURCE USAGE

Parsing time grew in proportion to the input on the stress inputs measured. The
whole input is split into lines and the whole tree is held in memory.

Measured with a ReleaseSafe build on one x86-64 Linux machine: on 1 MiB stress
inputs, the documents' arenas held up to about 155 MiB (many keys that are
collections or aliases). A flow sequence of 14 MiB with one short item per line
held about 1.1 GiB. Ordinary configuration files were not measured. As an
estimate from these ratios, a hostile input at the default 16 MiB limit could
need 2.5 GiB.

# CONCURRENCY AND ATOMICITY

The library has no global mutable state. Separate documents may be used from
separate threads, if their allocators allow it. A document must not be changed
while any other thread uses it; writing takes temporary memory from the
allocator the document was created with.

`write` checks the whole tree before writing, but a failing writer can leave
partial output. To replace a file safely, write elsewhere and rename.

# CAVEATS

**Copying a node copies its anchor.** `get` and `lookup` return the node
itself, even when reached through an alias. Storing it in a second place writes
`&name` twice. The output reads back with the same values, but the two are no
longer one shared node, and an alias written after the second one refers to the
second. To refer to a node, store an alias:
`.{ .alias = value.anchorOf().? }`. A copied mapping or sequence is also still
the same object in memory, so changing one changes both until written and read
again.

**Keys must not change in place.** A collection used as a key must not be
modified while it is in its mapping, and neither should an anchored node that a
key reaches through an alias. Lookups and duplicate checks depend on it.

**Removing an anchored node** that an alias still uses makes `write` fail with
`BrokenAlias`.

# LIMITATIONS

See **yaml-syntax**(5) for the YAML accepted and how output differs from input.
There is no streaming or event interface, no schema other than the core
schema, no merging of `<<` keys, and no conversion between YAML and Zig structs.

# COMPATIBILITY

Zig 0.17.1 or later 0.17. Tested on x86-64 Linux only. The API is not yet
stable: releases before 1.0 may change it, and the README lists the changes.

# SEE ALSO

**yaml-syntax**(5), `docs/architecture.md`, `ai/SPEC.md`

# AVAILABILITY

https://github.com/BearzRobotics/yaml-zig

# COPYRIGHT

See `LICENSE`.

# VERSION

This page describes yaml-zig 0.3.1.
