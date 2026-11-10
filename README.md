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
- **Comments:** lines above an item, a trailing comment on its line, blank lines between items, and a footer survive. `Map.comments`, `Seq.comments`, `Document.header`/`footer`; set them with `Document.setComments`.
- **Not read** (reported as `error.Unsupported`, never misread): anchors, aliases, tags, directives, complex keys (`? `), several documents in one stream.
- **Write:** block style with the source's indentation step; scalars keep their style; strings built with `Document.string` are quoted when they would otherwise read as something else. Folded scalars are written as literal (same value); comments inside flow collections are dropped.

`zig build test` runs the tests.
