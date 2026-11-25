# yaml-zig

A YAML reader and writer for Zig 0.17 that **keeps comments** through parse → edit → write, with no dependencies. Written for importing Solus `package.yml` recipes (see `dkbuilder`) and for editing YAML configuration without losing the author's notes.

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

Reference: the YAML 1.2.2 specification, https://yaml.org/spec/1.2.2/ (source: https://github.com/yaml/yaml-spec). See `ai/SPEC.md` for requirements and the exact subset.

- **Read:** block mappings and sequences, plain / quoted / multi-line scalars, literal and folded block scalars (`|`, `>`, chomping and indentation indicators), flow `[...]` and `{...}`, `---` / `...`, `#` comments. Plain scalars are typed by the core schema (`null`, bool, int, float, string) but keep their text (`7.20` stays `7.20`).
- **Comments:** lines above an item, a trailing comment on its line, blank lines between items, comments on the `---` line and on a root scalar, and a footer survive. `Map.comments`, `Seq.comments`, `Document.header`/`footer`/`root_comments`/`start_comment`; set item comments with `Document.setComments`.
- **Not read** (reported as `error.Unsupported`): anchors, aliases, tags, directives, complex keys (`? ` or a collection as a key), several documents in one stream.
- **Write:** block style with the source's indentation step; scalars and keys keep their style; strings and keys added through the API are quoted when they would otherwise read as something else. Folded scalars are written as literal (same value). Comments inside flow collections are dropped, except that the last moves after the closing bracket. `write` refuses what could not be read back (`error.InvalidUtf8`, `error.NestingTooDeep`).

`zig build test` runs the tests. `zig build conformance -Dsuite=PATH` runs the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite): at `data-2022-01-17` there are no failures, with 109 of its 402 cases using features that are not read. See `ai/SPEC.md` for the details and the one deliberate departure from YAML 1.2.2.

## Changes in 0.2.0

A bug-fix release. Valid YAML that 0.1.0 read correctly reads the same way, but:

- **Newly rejected:** input that is not valid YAML and was accepted before (some of it also accepted by libyaml-based readers), such as `a: b: c`, `a: - x`, `[,]`, an under-indented line in a multi-line flow collection or quoted scalar, or a control character. Anchors and tags on keys are now `error.Unsupported`.
- **Read differently:** these were read wrongly before. Examples: spaces on blank lines inside `|` blocks are kept; `rock 'n roll # note` no longer includes the comment; a lone CR ends a line.
- **API:** `string`, `set`, `setComments`, `write` and `toOwnedString` can return `error.InvalidUtf8`; `write` and `toOwnedString` can return `error.NestingTooDeep`; `Map.setComments` returns `error.NotFound` for a missing key. New fields: `Map.key_styles`, `Document.root_comments`, `Document.start_comment`, `Document.max_depth`. Exhaustive `switch`es over these error sets need the new cases.
