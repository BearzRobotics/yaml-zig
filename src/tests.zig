const std = @import("std");
const yaml = @import("root.zig");
const testing = std.testing;

fn parse(src: []const u8) !yaml.Document {
    var diag: yaml.Diagnostic = .{};
    return yaml.Document.parse(testing.allocator, src, .{}, &diag) catch |e| {
        std.debug.print("unexpected failure on:\n{s}\n-> {f}\n", .{ src, diag });
        return e;
    };
}

/// Parse, write, and require the same text back.
fn roundTrips(src: []const u8) !void {
    var doc = try parse(src);
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

fn rejects(src: []const u8, want: anyerror) !void {
    try testing.expectError(want, yaml.Document.parse(testing.allocator, src, .{}, null));
}

test "a recipe in the style of Solus package.yml" {
    const src =
        \\# Recipe for nano
        \\name: nano
        \\version: 7.2
        \\release: 100 # bump me
        \\source:
        \\    - https://example.org/nano-7.2.tar.xz: 86d3d8a3
        \\license: GPL-3.0-or-later
        \\builddeps:
        \\    - pkgconfig(ncurses)
        \\    - gettext
        \\
        \\# how to build
        \\setup: |
        \\    %configure --disable-nls
        \\build: |
        \\    %make
        \\
    ;
    var doc = try parse(src);
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("nano", m.getString("name").?);
    try testing.expectEqualStrings("7.2", m.getString("version").?);
    try testing.expectEqual(@as(i64, 100), m.getInt("release").?);
    try testing.expectEqual(@as(usize, 2), m.getSeq("builddeps").?.items.items.len);
    try testing.expectEqualStrings("%configure --disable-nls\n", m.getString("setup").?);
    try testing.expectEqual(@as(u8, 4), doc.indent);
    try roundTrips(src);
}

test "scalar kinds follow the core schema and keep their text" {
    var doc = try parse("a: 7.20\nb: 0x1F\nc: true\nd: ~\ne:\nf: \"12\"\ng: 'x'\nh: -3\ni: 1e3\nj: yes\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqual(yaml.Kind.float, m.get("a").?.scalar.kind);
    try testing.expectEqualStrings("7.20", m.getString("a").?);
    try testing.expectEqual(@as(i64, 31), m.getInt("b").?);
    try testing.expectEqual(true, m.getBool("c").?);
    try testing.expect(m.get("d").?.scalar.isNull());
    try testing.expect(m.get("e").?.scalar.isNull());
    try testing.expectEqual(yaml.Kind.string, m.get("f").?.scalar.kind);
    try testing.expectEqual(@as(i64, -3), m.getInt("h").?);
    try testing.expectEqual(@as(f64, 1000), m.getFloat("i").?);
    try testing.expectEqual(yaml.Kind.string, m.get("j").?.scalar.kind); // YAML 1.2: not a boolean
}

test "comments survive a round trip" {
    try roundTrips(
        \\# header
        \\
        \\# first
        \\a: 1 # one
        \\b:
        \\  # about c
        \\  c: x
        \\  d: y # why
        \\
        \\list:
        \\  # the first
        \\  - one # uno
        \\  - two
        \\  - k: v
        \\# the end
        \\
    );
}

test "block and flow collections, quoting" {
    try roundTrips("a: [1, 2, three]\nb: {x: 1, y: [a, b]}\nc: []\nd: {}\ne: 'it''s'\nf: \"tab\\there\"\n");
    var doc = try parse("a: [1,\n  2, # note\n  3]\nb: {x: 1,\n  y: 2}\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.root.map.getSeq("a").?.items.items.len);
    try testing.expectEqual(@as(i64, 2), doc.root.map.getMap("b").?.getInt("y").?);
}

test "block scalars: literal, folded, chomping" {
    var doc = try parse(
        \\a: |
        \\  one
        \\  two
        \\b: |-
        \\  no newline
        \\c: |+
        \\  keep
        \\
        \\d: >
        \\  folded
        \\  text
        \\
        \\  new paragraph
        \\e: |2
        \\    indented first
        \\f: x
        \\
    );
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("one\ntwo\n", m.getString("a").?);
    try testing.expectEqualStrings("no newline", m.getString("b").?);
    try testing.expectEqualStrings("keep\n\n", m.getString("c").?);
    try testing.expectEqualStrings("folded text\nnew paragraph\n", m.getString("d").?);
    try testing.expectEqualStrings("  indented first\n", m.getString("e").?);
    try testing.expectEqualStrings("x", m.getString("f").?);
    // Written back, the values are the same.
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    var doc2 = try parse(out);
    defer doc2.deinit();
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |k| try testing.expectEqualStrings(m.getString(k).?, doc2.root.map.getString(k).?);
}

test "multi-line scalars" {
    var doc = try parse("a: plain text\n  continues here\nb: \"quoted\n  over lines\"\nc: 'x\n\n  y'\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("plain text continues here", m.getString("a").?);
    try testing.expectEqualStrings("quoted over lines", m.getString("b").?);
    try testing.expectEqualStrings("x\ny", m.getString("c").?);
}

test "a sequence may sit at its key's column" {
    var doc = try parse("a:\n- 1\n- 2\nb: x\n");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.map.getSeq("a").?.items.items.len);
    try testing.expectEqualStrings("x", doc.root.map.getString("b").?);
}

test "nested sequences and mappings in sequences" {
    var doc = try parse("- a: 1\n  b: 2\n- - x\n  - y\n- plain\n");
    defer doc.deinit();
    const q = doc.root.seq;
    try testing.expectEqual(@as(usize, 3), q.items.items.len);
    try testing.expectEqual(@as(i64, 2), q.items.items[0].map.getInt("b").?);
    try testing.expectEqual(@as(usize, 2), q.items.items[1].seq.items.items.len);
}

test "explicit document markers" {
    try roundTrips("# note\n---\na: 1\n");
    var doc = try parse("---\na: 1\n...\n");
    defer doc.deinit();
    try testing.expect(doc.explicit_start);
}

test "editing keeps comments and writes safe scalars" {
    var doc = try parse("# keep\nname: old # me\nn: 1\n");
    defer doc.deinit();
    try doc.set(&.{"name"}, try doc.string("true"));
    try doc.set(&.{ "deep", "er" }, try doc.string("a: b"));
    try doc.set(&.{"n"}, try doc.integer(7));
    try testing.expect(doc.root.map.remove("zz") == false);
    try doc.setComments(&.{"n"}, .{ .before = &.{"# count"}, .after = "# seven" });
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"n"}, .{ .after = "x" }));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# keep\nname: \"true\" # me\n# count\nn: 7 # seven\ndeep:\n  er: \"a: b\"\n", out);
}

test "strings that need quoting are quoted" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    const cases = [_][]const u8{ "", "true", "12", "null", "~", " lead", "trail ", "a: b", "a #b", "- x", "[x]", "{x}", "#x", "&a", "*a", "!t", "%x", "@x", "x:", "line\nbreak\n", "tab\there", "quote\"s", "'", "é ü" };
    for (cases, 0..) |c, i| {
        var kb: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        try doc.set(&.{k}, try doc.string(c));
    }
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    var back = try parse(out);
    defer back.deinit();
    for (cases, 0..) |c, i| {
        var kb: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&kb, "k{d}", .{i});
        const got = back.root.map.get(k).?.scalar;
        try testing.expectEqualStrings(c, got.text);
        try testing.expectEqual(yaml.Kind.string, got.kind);
    }
}

test "unsupported and invalid input is rejected" {
    try rejects("a: &x 1\n", error.Unsupported);
    try rejects("a: *x\n", error.Unsupported);
    try rejects("a: !!str 1\n", error.Unsupported);
    try rejects("? a\n: b\n", error.Unsupported);
    try rejects("a: 1\n---\nb: 2\n", error.Unsupported);
    try rejects("a: 1\na: 2\n", error.Syntax);
    try rejects("a: 1\n  b: 2\n", error.Syntax);
    try rejects("a:\n\tb: 1\n", error.Syntax);
    try rejects("a: [1, 2\n", error.Syntax);
    try rejects("a: \"x\n", error.Syntax);
    try rejects("a: 1\n b: 2\nc: 3\n", error.Syntax);
    try rejects("a: \xff\n", error.InvalidUtf8);
}

test "limits and diagnostics" {
    var diag: yaml.Diagnostic = .{};
    try testing.expectError(error.Syntax, yaml.Document.parse(testing.allocator, "a: 1\nb: 2\nb: 3\n", .{}, &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, "abcdef", .{ .max_bytes = 3 }, null));
    // Deep nesting does not overflow the stack.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..500) |i| {
        try buf.appendNTimes(testing.allocator, ' ', i);
        try buf.appendSlice(testing.allocator, "a:\n");
    }
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, buf.items, .{}, null));
}

test "reading from a reader" {
    var r: std.Io.Reader = .fixed("a: 1\n");
    var doc = try yaml.Document.parseReader(testing.allocator, &r, .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1), doc.root.map.getInt("a").?);
}

test "no leaks on allocation failure" {
    const src = "# c\na: 1 # x\nb:\n  - [1, 2]\n  - k: |\n      text\nc: \"q\"\n";
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var fa = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (yaml.Document.parse(fa.allocator(), src, .{}, null)) |*d| {
            var dd = d.*;
            const out = dd.toOwnedString(fa.allocator()) catch null;
            if (out) |o| fa.allocator().free(o);
            dd.deinit();
        } else |_| {}
    }
}

test "random garbage never crashes" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rnd = prng.random();
    const alphabet = "ab: -#\n\t\"'[]{}|>&*!%,.0123\\";
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        if (yaml.Document.parse(testing.allocator, buf[0..len], .{}, null)) |*d| {
            var dd = d.*;
            if (dd.toOwnedString(testing.allocator)) |o| testing.allocator.free(o) else |_| {}
            dd.deinit();
        } else |_| {}
    }
}

test "a long multi-line quoted scalar uses linear memory" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "a: \"\n");
    for (0..20_000) |_| try src.appendSlice(testing.allocator, " x\n");
    try src.appendSlice(testing.allocator, " \"\n");
    var doc = try yaml.Document.parse(testing.allocator, src.items, .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 40_001), doc.root.map.getString("a").?.len);
    // The quadratic version held hundreds of megabytes here.
    try testing.expect(doc.arena.queryCapacity() < 16 * src.items.len);
}

test "continuation lines of a quoted scalar are checked" {
    try rejects("a: \"b\nc\"\n", error.Syntax);
    try rejects("a: \"bar\n\tbaz\"\n", error.Syntax);
    try rejects("---\n\"\n---\n\"\n", error.Syntax);
    try rejects("---\n'\n...\n'\n", error.Syntax);
    var doc = try parse("a: \"b\n\n  --- c\"\nd: 'e\\\n f'\n");
    defer doc.deinit();
    try testing.expectEqualStrings("b\n--- c", doc.root.map.getString("a").?);
    try testing.expectEqualStrings("e\\ f", doc.root.map.getString("d").?);
}

/// Parses `src` and returns the string under the top-level key `a`.
fn expectString(src: []const u8, want: []const u8) !void {
    var doc = try parse(src);
    defer doc.deinit();
    try testing.expectEqualStrings(want, doc.root.map.getString("a").?);
}

/// Parses `src` and requires the writer to produce `want`.
fn expectWritten(src: []const u8, want: []const u8) !void {
    var doc = try parse(src);
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(want, out);
}

test "quotes and line breaks inside flow collections" {
    try expectWritten("a: [don't, it's]\nb: 2\n", "a: [don't, it's]\nb: 2\n");
    try expectWritten("a: [\"x\n  # y\"]\n", "a: [\"x # y\"]\n");
    try expectWritten("a: [\"x\n\n  y\"]\n", "a: [\"x\\ny\"]\n");
    try expectWritten("a: [one\n  two\n\n  three, 4]\n", "a: [\"one two\\nthree\", 4]\n");
}

test "flow pairs, comments and a trailing comma" {
    try expectWritten("a: [k: v, \"q\":w, : x]\n", "a: [{k: v}, {\"q\": w}, {: x}]\n");
    try expectWritten("a: [1, # inner\n  2, ] # outer\n", "a: [1, 2] # outer\n");
    try expectWritten("a: {x:\n  1,\n  y\n  : 2}\n", "a: {x: 1, y: 2}\n");
}

test "invalid flow collections are rejected" {
    try rejects("a: [,]\n", error.Syntax);
    try rejects("a: [x,,y]\n", error.Syntax);
    try rejects("a: [-]\n", error.Syntax);
    try rejects("a: [a,\nb]\n", error.Syntax);
    try rejects("a: [a, b,#c\n  ]\n", error.Syntax);
    try rejects("a: [a]#c\n", error.Syntax);
    try rejects("[\n--- ,\n...\n]\n", error.Syntax);
    try rejects("a: [x\n  y: z]\n", error.Syntax);
    try rejects("a: {x: 1, x: 2}\n", error.Syntax);
    try rejects("a: {? x: 1}\n", error.Unsupported);
    try rejects("a: [&x 1]\n", error.Unsupported);
    try rejects("a: {[b]: c}\n", error.Unsupported);
    try rejects("[b]: c\n", error.Unsupported);
}

test "max_depth counts block and flow nesting together" {
    const opts: yaml.Options = .{ .max_depth = 3 };
    var ok = try yaml.Document.parse(testing.allocator, "a:\n  b: [1]\n", opts, null);
    ok.deinit();
    var ok_flow = try yaml.Document.parse(testing.allocator, "[[[x]]]\n", opts, null);
    ok_flow.deinit();
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, "a:\n  b: [[1]]\n", opts, null));
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, "[[[[]]]]\n", opts, null));
}

test "document markers end scalars" {
    var a = try parse("foo\n...\n");
    defer a.deinit();
    try testing.expectEqualStrings("foo", a.root.scalar.text);
    var b = try parse("|\nx\n...\n");
    defer b.deinit();
    try testing.expectEqualStrings("x\n", b.root.scalar.text);
    try rejects("foo\n---\nbar\n", error.Unsupported);
    try rejects("---\nscalar\n...\nkey: value\n", error.Unsupported);
    try rejects("|\nx\n...\ny\n", error.Unsupported);
    try rejects("  ---\na: 1\n", error.Syntax);
    try rejects("a: 1\n... x\n", error.Syntax);
    var c = try parse("a: 1\n...\n# c\n...\n");
    c.deinit();
    // Only a marker followed by a blank or nothing is a marker.
    try expectString("a: x\n  ---y\n", "x ---y");
}

test "content on the '---' line" {
    const cases = [_][2][]const u8{
        .{ "--- foo\n", "foo" },
        .{ "---\tscalar\n", "scalar" },
        .{ "--- |\n  text\n", "text\n" },
        .{ "--- \"q\"\n", "q" },
    };
    for (cases) |case| {
        var doc = try parse(case[0]);
        defer doc.deinit();
        try testing.expect(doc.explicit_start);
        try testing.expectEqualStrings(case[1], doc.root.scalar.text);
    }
    try rejects("--- a: 1\n", error.Syntax);
    try rejects("--- - a\n", error.Syntax);
}

test "anchors, tags and aliases on keys are refused, not read as text" {
    try rejects("&a key: v\n", error.Unsupported);
    try rejects("!!str a: 1\n", error.Unsupported);
    try rejects("*a : 1\n", error.Unsupported);
    try rejects("- &a x: 1\n", error.Unsupported);
    try rejects("a: 1\n&b c: 2\n", error.Unsupported);
    try rejects("?\ta\n", error.Unsupported);
    try rejects("@a: 1\n", error.Syntax);
    try rejects("`a: 1\n", error.Syntax);
    try rejects("%a: 1\nb: 2\n", error.Unsupported); // a directive line
    try rejects("b: 2\n%a: 1\n", error.Syntax);
}

test "empty keys, and tabs around the colon" {
    var doc = try parse(": a\nb:\tc\n\"d\":\te\n\"f\"\t: g\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("a", m.getString("").?);
    try testing.expectEqualStrings("c", m.getString("b").?);
    try testing.expectEqualStrings("e", m.getString("d").?);
    try testing.expectEqualStrings("g", m.getString("f").?);
}

test "a quote inside a plain scalar does not hide a comment" {
    try expectWritten("a: rock 'n roll # note\n", "a: rock 'n roll # note\n");
    try expectString("a: rock 'n roll # note\n", "rock 'n roll");
    try expectString("a: x 'y # z' # c\n", "x 'y");
    try expectString("a: 5\" pipe # c\n", "5\" pipe");
    try expectString("a: \"# not a comment\" # c\n", "# not a comment");
    try expectString("\"a\": '# kept'\n", "# kept");
    var doc = try parse("- 'k # 1': v # c\n- it's: x # y\n");
    defer doc.deinit();
    try testing.expectEqualStrings("v", doc.root.seq.items.items[0].map.getString("k # 1").?);
    try testing.expectEqualStrings("x", doc.root.seq.items.items[1].map.getString("it's").?);
    try rejects("a: \"value\"# c\n", error.Syntax);
}

test "text that is not a valid plain scalar is rejected" {
    for ([_][]const u8{ "a: b: c\n", "a: b: c: d\n", "a: x:\n", "a: - x\n", "a: -\n", "a: ? x\n", "a: : x\n", "a: ,x\n", "a: ]x\n", "a: }x\n", "- b: c: d\n", "a: x\n  y: z\n" }) |src| {
        try rejects(src, error.Syntax);
    }
    var doc = try parse("a: -x\nb: ?y\nc: :z\nd: http://h:1/#f\n");
    defer doc.deinit();
    try testing.expectEqualStrings("-x", doc.root.map.getString("a").?);
    try testing.expectEqualStrings("http://h:1/#f", doc.root.map.getString("d").?);
}

test "indicators on a continuation line are plain text" {
    try expectString("a: x\n  - y\n", "x - y");
    try expectString("a: say\n  \"hi\" [now] | > {x}\n", "say \"hi\" [now] | > {x}");
    var doc = try parse("- single multiline\n - sequence entry\n");
    defer doc.deinit();
    try testing.expectEqualStrings("single multiline - sequence entry", doc.root.seq.items.items[0].scalar.text);
}

test "line breaks are LF, CR LF or CR" {
    for ([_][]const u8{ "a: 1\r\nb: |\r\n  x\r\n  y\r\n", "a: 1\rb: |\r  x\r  y\r" }) |src| {
        var doc = try parse(src);
        defer doc.deinit();
        try testing.expectEqual(@as(i64, 1), doc.root.map.getInt("a").?);
        try testing.expectEqualStrings("x\ny\n", doc.root.map.getString("b").?);
    }
    // NEL and the Unicode separators are ordinary characters in YAML 1.2.
    try expectString("a: x\u{2028}y\n", "x\u{2028}y");
}

test "a byte order mark is skipped" {
    try expectString("\xEF\xBB\xBFa: x\n", "x");
}

test "non-printable characters" {
    for ([_][]const u8{ "a: x\x00y\n", "a: \"\x01\"\n", "# \x07\na: 1\n", "a: x\x7Fy\n", "a: 1 # \u{80}\n", "x\x7F: 1\n", "a: [x\u{9f}]\n", "a: |\n  \u{fffe}\n" }) |src| {
        try rejects(src, error.Syntax);
    }
    // Quoted scalars may hold anything but C0 controls; it is written escaped.
    try expectWritten("a: \"\x7F\u{80}\u{ffff}\"\n", "a: \"\\x7F\\x80\\uFFFF\"\n");
    try expectWritten("a: '\x7F'\n", "a: \"\\x7F\"\n");
    try expectWritten("a: \"\\x01\\r\\0\"\n", "a: \"\\x01\\r\\x00\"\n");
    var doc = try parse("a: 1\n");
    defer doc.deinit();
    for ([_][]const u8{ "# \x00", "# \n", "# \r", "# \x7F", "# \u{80}", "# \xff" }) |bad| {
        try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .after = bad }));
        try testing.expectError(error.InvalidComment, doc.setComments(&.{"a"}, .{ .before = &.{bad} }));
    }
}

test "tabs separate but do not indent" {
    var doc = try parse("a:\t b\n\t# comment\nc:\n \td\ne:\n-\t-1\n-\t[x]\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("b", m.getString("a").?);
    try testing.expectEqualStrings("d", m.getString("c").?);
    try testing.expectEqual(@as(i64, -1), m.getSeq("e").?.items.items[0].scalar.asInt().?);
    var flow = try parse("\t[\n\t]\n");
    flow.deinit();
    for ([_][]const u8{ "a:\n\tb: 1\n", "a:\n \tb: 1\n", "a:\n\tb\n", "-\t-\n", "- \t- x\n", "-\tk: v\n", "a: 1\n\tb: 2\n", "- a\n\t- b\n" }) |src| {
        try rejects(src, error.Syntax);
    }
}

test "whitespace-only lines in a block scalar keep what is past the indent" {
    try expectString("a: |\n  x\n     \n  y\n", "x\n   \ny\n");
    try expectString("a: |\n  x\n  \t\n  y\n", "x\n\t\ny\n");
    try expectString("a: |\n  x\n   \n", "x\n \n");
    try expectString("a: |\n \n\n  x\n", "\n\nx\n");
    try expectString("a: |\n    \nb: 1\n", "");
    try expectString("a: >\n \t\n x\n", "\t\nx\n");
}

test "bad block scalars are rejected" {
    for ([_][]const u8{ "a: |-+\n  x\n", "a: |++\n  x\n", "a: |12\n   x\n", "a: |0\n  x\n", "a: |#c\n  x\n", "a: |x\n  x\n", "a: >\n    \n  x\n", "a: |\n\t\nb: 1\n", "a: |\n  x\n\t\nb: 1\n" }) |src| {
        try rejects(src, error.Syntax);
    }
    try expectString("a: |2-\n  x\n", "x");
    try expectString("a: |-2 # c\n  x\n", "x");
}

test "double-quoted escapes" {
    try expectString("a: \"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\ \\\"\\/\\\\\"\n", "\x00\x07\x08\t\n\x0b\x0c\r\x1b \"/\\");
    try expectString("a: \"\\N\\_\\L\\P\"\n", "\u{85}\u{a0}\u{2028}\u{2029}");
    try expectString("a: \"\\x41\\u00e9\\U0001F600\"\n", "A\u{e9}\u{1F600}");
    for ([_][]const u8{ "a: \"\\x+1\"\n", "a: \"\\u1_00\"\n", "a: \"\\x4\"\n", "a: \"\\uD800\"\n", "a: \"\\U00110000\"\n", "a: \"\\q\"\n" }) |src| {
        try rejects(src, error.Syntax);
    }
}

test "escaped line breaks" {
    try expectString("a: \"foo \\\n  bar\"\n", "foo bar");
    try expectString("a: \"foo \\\n  \n  bar\"\n", "foo \nbar");
    try expectString("a: \"x\\t\\\n\n\n  y\"\n", "x\t\n\ny");
}

/// Writes `doc`, reads the result and returns it.
fn writeAndRead(doc: *const yaml.Document) !yaml.Document {
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    return parse(out);
}

test "text that looks like a document marker is quoted at column 0" {
    for ([_][]const u8{ "---", "...", "--- x", "... x" }) |text| {
        var doc = try yaml.Document.init(testing.allocator);
        defer doc.deinit();
        doc.root = try doc.string(text);
        var root_back = try writeAndRead(&doc);
        defer root_back.deinit();
        try testing.expectEqualStrings(text, root_back.root.scalar.text);

        var keyed = try yaml.Document.init(testing.allocator);
        defer keyed.deinit();
        try keyed.set(&.{text}, try keyed.string(text));
        var key_back = try writeAndRead(&keyed);
        defer key_back.deinit();
        try testing.expectEqualStrings(text, key_back.root.map.getString(text).?);
    }
    // Away from column 0 it stays as it was written.
    try roundTrips("a: ...\n");
}

test "invalid UTF-8 is refused, not written" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    try testing.expectError(error.InvalidUtf8, doc.string("a\xffb"));
    try testing.expectError(error.InvalidUtf8, doc.set(&.{"a\xffb"}, doc.boolean(true)));
    try testing.expectEqual(@as(usize, 0), doc.root.map.count());
    // Values and comments built by hand are caught when writing.
    try doc.set(&.{"a"}, .{ .scalar = .{ .text = "\xff" } });
    try testing.expectError(error.InvalidUtf8, doc.toOwnedString(testing.allocator));
    try doc.set(&.{"a"}, doc.boolean(true));
    doc.footer = &.{"# \xff"};
    try testing.expectError(error.InvalidUtf8, doc.toOwnedString(testing.allocator));
}

test "block scalars survive writing, whatever their shape" {
    const texts = [_][]const u8{ "\n", "\n\n", "\n\n\n", "  \nfoo\n", "x\n   \ny\n", "x\n\t\ny\n", " lead\nx", "\tlead\nx\n", "\n  x\n\n\n", "a\n\nb", "---\n...\n", "# not a comment\n" };
    for ([_]u8{ 1, 2, 4, 9, 12 }) |step| {
        for (texts) |text| {
            var doc = try yaml.Document.init(testing.allocator);
            defer doc.deinit();
            doc.indent = step;
            try doc.set(&.{"k"}, try doc.string(text));
            var seq = try doc.newSeq();
            try seq.seq.append(doc.allocator(), try doc.string(text));
            try doc.set(&.{"s"}, seq);
            try doc.set(&.{"z"}, doc.boolean(true));
            var back = try writeAndRead(&doc);
            defer back.deinit();
            try testing.expectEqualStrings(text, back.root.map.getString("k").?);
            try testing.expectEqualStrings(text, back.root.map.getSeq("s").?.items.items[0].scalar.text);

            doc.root = try doc.string(text);
            var root_back = try writeAndRead(&doc);
            defer root_back.deinit();
            try testing.expectEqualStrings(text, root_back.root.scalar.text);
        }
    }
}

test "empty block scalars from a file" {
    for ([_][]const u8{ "a: >-\n\nb: >\n\nc: |+\n\n", "- |+\n   \n", "# c\n|-\n" }) |src| {
        var doc = try parse(src);
        defer doc.deinit();
        const out = try doc.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        var back = try parse(out);
        defer back.deinit();
        const again = try back.toOwnedString(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(out, again);
        if (doc.root == .scalar) try testing.expectEqualStrings(doc.root.scalar.text, back.root.scalar.text);
    }
}

test "a '|+' value does not absorb the blank lines after it" {
    var doc = try parse("a: x\n\nb: 1\n\n# end\n");
    defer doc.deinit();
    for ([_][]const u8{ "t\n\n", "\n", "t\n\n\n" }) |text| {
        // Before another item, and before the footer.
        try doc.set(&.{"a"}, try doc.string(text));
        try doc.set(&.{"b"}, try doc.string(text));
        var back = try writeAndRead(&doc);
        defer back.deinit();
        try testing.expectEqualStrings(text, back.root.map.getString("a").?);
        try testing.expectEqualStrings(text, back.root.map.getString("b").?);
        try testing.expectEqualStrings("# end", back.footer[back.footer.len - 1]);
    }
}

test "keys keep their quotes and their YAML type" {
    try roundTrips("\"true\": 1\n'123': 2\n\"null\": 3\nTrue: 4\n34: 5\n-1: 6\n-x: 7\n'it''s': 8\n\"a\": 9\n");
    try roundTrips("a: {\"true\": 1, '2': 3, True: 4, \"x,y\": 5}\n");
    try roundTrips(": empty\n");
}

test "keys added through the API read as strings" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    for ([_][]const u8{ "true", "12", "null", "", "plain", "a: b", "-", "x,y", "#", "{z}" }) |k| try doc.set(&.{k}, doc.boolean(true));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"true\": true\n\"12\": true\n\"null\": true\n\"\": true\nplain: true\n\"a: b\": true\n\"-\": true\nx,y: true\n\"#\": true\n\"{z}\": true\n", out);
    var back = try parse(out);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 10), back.root.map.count());
}

test "a flow collection turns into a block one rather than lose anything" {
    var doc = try parse("cfg: {}\nl: [1, 2]\n");
    defer doc.deinit();
    var inner = try doc.newMap();
    try inner.map.put(doc.allocator(), "deep", doc.boolean(true));
    try inner.map.setComments(doc.allocator(), "deep", .{ .before = &.{"# keep me"}, .after = "# me too" });
    doc.root.map.getMap("cfg").?.flow = true;
    try doc.set(&.{ "cfg", "x" }, inner);
    try doc.setComments(&.{ "l", "0" }, .{ .before = &.{"# first"} });
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cfg:\n  x:\n    # keep me\n    deep: true # me too\nl:\n  # first\n  - 1\n  - 2\n", out);

    var root = try parse("[1, 2]\n");
    defer root.deinit();
    try root.setComments(&.{"1"}, .{ .after = "# two" });
    const root_out = try root.toOwnedString(testing.allocator);
    defer testing.allocator.free(root_out);
    try testing.expectEqualStrings("- 1\n- 2 # two\n", root_out);
}

/// Parses `src`, requires `want` as output, and requires `want` to be stable.
fn expectStable(src: []const u8, want: []const u8) !void {
    try expectWritten(src, want);
    try roundTrips(want);
}

test "comments around a value on its own line stay with its item" {
    try expectStable("a:\n  b # keep me\nc: 1\n", "a: b # keep me\nc: 1\n");
    try expectStable("a: # key\n  b # value\nc: 1\n", "# key\na: b # value\nc: 1\n");
    try expectStable("a:\n  # about a\n\n  foo\nb: 1\n", "# about a\na: foo\nb: 1\n");
    try expectStable("- \n  # about\n  foo\n- x\n", "# about\n- foo\n- x\n");
    try expectStable("a:\n  [1, 2] # list\nb:\n  | # head\n    text\n", "a: [1, 2] # list\nb: | # head\n  text\n");
    try expectStable("- k:\n    v # mine\n- x\n", "- k: v # mine\n- x\n");
    // After an empty value, the comments belong to the next item.
    try expectStable("a:\n# next\nb: 1\n", "a:\n# next\nb: 1\n");
}

test "comments on a root scalar or flow collection" {
    try expectStable("foo # c\n", "foo # c\n");
    try expectStable("# above\nv\n# end\n", "# above\nv\n# end\n");
    try expectStable("# above\n[1] # c\n", "# above\n[1] # c\n");
    try expectStable("# above\n|- # c\n  v\n", "# above\n|- # c\n  v\n");
    try expectStable("# above\n--- v # c\n", "# above\n---\nv # c\n");
    try expectStable("# only\n", "null\n# only\n");
}

test "the comment on the dash of a mapping entry is written" {
    try expectStable("- # hello\n  a: 1\n  b: 2\n- x\n", "- # hello\n  a: 1\n  b: 2\n- x\n");
    try expectStable("k:\n  - # c\n    a:\n      b: 1\n", "k:\n  - # c\n    a:\n      b: 1\n");
    var doc = try parse("- a: 1\n- b: 2\n");
    defer doc.deinit();
    try doc.setComments(&.{"0"}, .{ .before = &.{"# above"}, .after = "# important" });
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("# above\n- # important\n  a: 1\n- b: 2\n", out);
}

test "comments on the document marker lines survive" {
    try expectStable("--- # c1\na: 1\n... # c2\n# c3\n", "--- # c1\na: 1\n# c2\n# c3\n");
}

test "leading blanks in a comment cannot change the document" {
    var doc = try parse("a: |\n  t\nb: 1\n");
    defer doc.deinit();
    for ([_][]const u8{ "    # note", "\t# note", " \t # note" }) |comment| {
        try doc.setComments(&.{"b"}, .{ .before = &.{comment} });
        const out = try doc.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a: |\n  t\n# note\nb: 1\n", out);
    }
}

test "Map.setComments needs an existing key and does not keep the caller's" {
    var doc = try parse("a: 1\n");
    defer doc.deinit();
    const map = doc.root.map;
    try testing.expectError(error.NotFound, map.setComments(doc.allocator(), "later", .{ .after = "# orphan" }));
    var key = [_]u8{'a'};
    try map.setComments(doc.allocator(), &key, .{ .after = "# c" });
    key[0] = 'z';
    try testing.expectEqualStrings("# c", map.commentsOf("a").?.after.?);
    try map.setComments(doc.allocator(), "a", .{});
    try testing.expectEqual(@as(?yaml.Comments, null), map.commentsOf("a"));
}

test "output is stable from the first write" {
    for ([_][]const u8{ "- \n\n k: \n", "-  # c  \n\n  x\n", "- \n  \n  k: \n" }) |src| {
        var doc = try parse(src);
        defer doc.deinit();
        const out = try doc.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        try roundTrips(out);
    }
}

test "what is written respects max_depth, so it can be read again" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    const path: [65][]const u8 = @splat("a");
    try doc.set(path[0..64], doc.boolean(true));
    var back = try writeAndRead(&doc);
    back.deinit();
    var deeper = path;
    deeper[0] = "b";
    try doc.set(&deeper, doc.boolean(true));
    try testing.expectError(error.NestingTooDeep, doc.toOwnedString(testing.allocator));

    var cycle = try yaml.Document.init(testing.allocator);
    defer cycle.deinit();
    try cycle.set(&.{"self"}, cycle.root);
    try testing.expectError(error.NestingTooDeep, cycle.toOwnedString(testing.allocator));

    // A single pair in a flow sequence is a level of its own.
    const opts: yaml.Options = .{ .max_depth = 2 };
    var pair = try yaml.Document.parse(testing.allocator, "[k: v]\n", opts, null);
    pair.deinit();
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, "[[k: v]]\n", opts, null));
    try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, "[k: [[v]]]\n", opts, null));
}

test "diagnostics give the line and column of the error" {
    const Case = struct { src: []const u8, line: usize, column: usize };
    for ([_]Case{
        .{ .src = "a: \"\\q\"\nb: 1\nc: 2\n", .line = 1, .column = 5 },
        .{ .src = "a: \"x\n  \\q\n  y\"\nb: 1\n", .line = 2, .column = 3 },
        .{ .src = "a: [1] x\nb: 1\nc: 2\n", .line = 1, .column = 1 },
        .{ .src = "a: \"x\" y\nb: 1\n", .line = 1, .column = 8 },
        .{ .src = "a: [1, , 2]\n", .line = 1, .column = 8 },
        .{ .src = "a: b: c\nd: 1\n", .line = 1, .column = 4 },
        .{ .src = "a: 1\nb: \"open\n  more\n", .line = 2, .column = 4 },
        .{ .src = "a: x\n  y\x7f\nb: 1\n", .line = 2, .column = 3 },
        .{ .src = "a: |\n  x\x7f\n  y\nb: 1\n", .line = 2, .column = 3 },
        .{ .src = "k:\n  a: 1\n  a: 2\n", .line = 3, .column = 3 },
    }) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.src});
        var diag: yaml.Diagnostic = .{};
        try testing.expectError(error.Syntax, yaml.Document.parse(testing.allocator, case.src, .{}, &diag));
        try testing.expectEqual(case.line, diag.line);
        try testing.expectEqual(case.column, diag.column);
        try testing.expect(diag.message.len != 0);
    }
    var r: std.Io.Reader = .fixed("a: 12345\n");
    var diag: yaml.Diagnostic = .{};
    try testing.expectError(error.LimitExceeded, yaml.Document.parseReader(testing.allocator, &r, .{ .max_bytes = 3 }, &diag));
    try testing.expectEqualStrings("input too large", diag.message);
}

test "every spelling of the special floats, and large integers" {
    const inf = std.math.inf(f64);
    const Case = struct { text: []const u8, want: f64 };
    for ([_]Case{
        .{ .text = ".inf", .want = inf },                                   .{ .text = ".Inf", .want = inf },
        .{ .text = ".INF", .want = inf },                                   .{ .text = "+.inf", .want = inf },
        .{ .text = "+.Inf", .want = inf },                                  .{ .text = "+.INF", .want = inf },
        .{ .text = "-.inf", .want = -inf },                                 .{ .text = "-.Inf", .want = -inf },
        .{ .text = "-.INF", .want = -inf },                                 .{ .text = "0o17", .want = 15 },
        .{ .text = "+12", .want = 12 },                                     .{ .text = "-1.5e2", .want = -150 },
        .{ .text = ".5", .want = 0.5 },                                     .{ .text = "99999999999999999999", .want = 1e20 },
        .{ .text = "0x10000000000000000", .want = 18446744073709551616.0 },
    }) |case| {
        const scalar: yaml.Scalar = .{ .text = case.text, .kind = @import("value.zig").resolve(case.text) };
        try testing.expectEqual(@as(?f64, case.want), scalar.asFloat());
    }
    for ([_][]const u8{ ".nan", ".NaN", ".NAN" }) |text| {
        const scalar: yaml.Scalar = .{ .text = text, .kind = @import("value.zig").resolve(text) };
        try testing.expect(std.math.isNan(scalar.asFloat().?));
    }
    var doc = try parse("a: 0o17\nb: 99999999999999999999\n");
    defer doc.deinit();
    try testing.expectEqual(@as(?i64, 15), doc.root.map.getInt("a"));
    try testing.expectEqual(@as(?i64, null), doc.root.map.getInt("b"));
}
