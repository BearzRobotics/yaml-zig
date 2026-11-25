# yaml-zig

A YAML 1.2 reader and writer for Zig 0.17 that **keeps comments** through parse → edit → write, with no dependencies. Written for importing Solus `package.yml` recipes (see `dkbuilder`) and for editing YAML configuration without losing the author's notes.

```zig
var diag: yaml.Diagnostic = .{};
var doc = try yaml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();

const name = doc.root.map.getString("name");           // "nano"
const release = doc.root.map.getInt("release");        // 100
try doc.set(&.{"release"}, try doc.integer(101));
try doc.setComments(&.{"release"}, .{ .before = &.{"# bumped"}, .after = "# was 100" });
const out = try doc.toOwnedString(gpa);                // comments are still there
```

A file with several documents is read with `Stream`; `Document.parse` accepts exactly one.

```zig
var stream = try yaml.Stream.parse(gpa, text, .{}, &diag);
defer stream.deinit();
for (stream.documents) |*document| _ = document.root;
const all = try stream.toOwnedString(gpa);
```

Reference: the YAML 1.2.2 specification, https://yaml.org/spec/1.2.2/ (source: https://github.com/yaml/yaml-spec). See `ai/SPEC.md` for requirements and the exact subset.

- **Read:** all the YAML 1.2.2 syntax: block and flow collections, every scalar style, several documents, `%YAML` and `%TAG`, tags, anchors and aliases, and keys of any kind. UTF-8, UTF-16 or UTF-32. Plain scalars are typed by the core schema (`null`, bool, int, float, string) but keep their text (`7.20` stays `7.20`).
- **Comments:** lines above an item, a trailing comment on its line, blank lines between items, comments on the `---` line and on a root scalar, and a footer survive. `Map.Entry.comments`, `Seq.comments`, `Document.header`/`footer`/`root_comments`/`start_comment`; set item comments with `Document.setComments`.
- **Keys** are values: `1:` and `"1":` are two keys, `true:` and `True:` are one. `get`, `getString`, `getInt` and the rest find a scalar key by its text; `getValue` takes a key of any kind.
- **Aliases** are references (`Value.alias`) and are never expanded. `get` and `lookup` follow them; `Map.entries` and `Seq.items` show them, and `Value.deref` gives the node. A node can contain itself, so bound any walk of your own that follows aliases. `Document.anchorNode` makes new anchors.
- **Tags** are kept in full (`tag:yaml.org,2002:str`, `!local`) on `Scalar.tag`, `Seq.tag` and `Map.tag`. The core schema tags set a scalar's type.
- **Write:** UTF-8, block style with the source's indentation step; scalars and keys keep their style; strings and keys added through the API are quoted when they would otherwise read as something else. Folded scalars are written as literal (same value). Comments inside flow collections are dropped, except that the last moves after the closing bracket. `write` refuses what could not be read back.
- **Untrusted input:** nesting, size, tag expansion and key comparison are limited (`Options`, `error.LimitExceeded`).

`zig build test` runs the tests. To run the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite), which is not part of this repository:

```sh
scripts/fetch-conformance.sh                    # once; into conformance-suite/, ignored by git
zig build conformance -Dsuite=conformance-suite
```

At `data-2022-01-17`, 400 of its 402 cases pass; the other 2 repeat a mapping key and are rejected on purpose. That does not prove full conformance. `ai/SPEC.md` lists the known deviations and limits.

## Changes in 0.3.1

- **Security fix, also affecting earlier releases:** text assigned directly to a comment field (`Document.header`, `footer`, `root_comments`, `start_comment`, `Seq.comments`, a `Map.Entry`'s comments, `Stream.comments`) was written unchecked, so it could add keys and values to the output. `setComments` was not affected. Writing now fails with `error.InvalidComment` unless every such line is a comment. An exhaustive `switch` over write errors needs the new case.
- Documentation: manual pages for the API ([yaml-zig(3)](docs/manpages/yaml-zig.3.md)) and the format ([yaml-syntax(5)](docs/manpages/yaml-syntax.5.md)), and [docs/architecture.md](docs/architecture.md). Stale API comments corrected.

## Changes in 0.3.0

Adds what 0.2.0 refused as `error.Unsupported`: several documents, directives, tags, anchors, aliases and complex keys; and UTF-16 and UTF-32 input. `error.Unsupported` now means only a key that holds an alias leading back into it, or, from `Document.parse`, more than one document.

**API changes that can break code:**

- `Value` has a new case, `.alias`.
- Keys are `Value`s. `Map.entries` maps a key to `Map.Entry` (`value`, `comments`); `Map.comments` is gone; `Map.setComments` takes no allocator. Lookups by text work as before.
- `Map.get`, `getValue` and `Document.lookup` return the node an alias stands for.
- `write` and `toOwnedString` can also return `error.InvalidDirective`, `InvalidTag`, `InvalidAnchor`, `BrokenAlias` and `OutOfMemory`.

**Input that reads differently:** `1:` with `"1":` is no longer a duplicate, and `true:` with `True:` now is. A block key can no longer start with `,`, `]` or `}`. A `|` or `>` block that the end of the file cuts off no longer gains a line break. A byte order mark inside a document is rejected. Two empty comment lines in a row are written as one.

## Changes in 0.2.0

A bug-fix release. Input that is not valid YAML and had been accepted, such as `a: b: c` or `[,]`, became an error; values that had been read wrongly (blank lines in `|` blocks, `rock 'n roll # note`) were fixed; and `string`, `set`, `setComments` and the write functions gained error cases.
