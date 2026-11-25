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
    try testing.expectEqualStrings("12", m.getString("f").?);
    try testing.expectEqual(@as(?i64, null), m.getInt("f"));
    try testing.expectEqualStrings("x", m.getString("g").?);
    try testing.expectEqual(yaml.Style.single, m.get("g").?.scalar.style);
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
    const items = doc.root.map.getSeq("a").?.items.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(?i64, 1), items[0].scalar.asInt());
    try testing.expectEqual(@as(?i64, 2), items[1].scalar.asInt());
    try testing.expectEqualStrings("x", doc.root.map.getString("b").?);
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a:\n  - 1\n  - 2\nb: x\n", out);
}

test "nested sequences and mappings in sequences" {
    var doc = try parse("- a: 1\n  b: 2\n- - x\n  - y\n- plain\n");
    defer doc.deinit();
    const q = doc.root.seq;
    try testing.expectEqual(@as(usize, 3), q.items.items.len);
    try testing.expectEqual(@as(i64, 2), q.items.items[0].map.getInt("b").?);
    try testing.expectEqual(@as(usize, 2), q.items.items[1].seq.items.items.len);
    try testing.expectEqual(@as(?i64, 1), q.items.items[0].map.getInt("a"));
    try testing.expectEqualStrings("x", q.items.items[1].seq.items.items[0].scalar.text);
    try testing.expectEqualStrings("y", q.items.items[1].seq.items.items[1].scalar.text);
    try testing.expectEqualStrings("plain", q.items.items[2].scalar.text);
    var back = try writeAndRead(&doc);
    defer back.deinit();
    try expectSame(doc.root, back.root);
}

test "explicit document markers" {
    try roundTrips("# note\n---\na: 1\n");
    var doc = try parse("---\na: 1\n...\n");
    defer doc.deinit();
    try testing.expect(doc.explicit_start);
    try testing.expectEqual(@as(?i64, 1), doc.root.map.getInt("a"));
    // The optional end marker is not written back.
    try expectWritten("---\na: 1\n...\n", "---\na: 1\n");
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
    try rejects("a: *x\n", error.Syntax);
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

fn parseAndWrite(gpa: std.mem.Allocator, src: []const u8) !void {
    var doc = try yaml.Document.parse(gpa, src, .{}, null);
    defer doc.deinit();
    const out = try doc.toOwnedString(gpa);
    gpa.free(out);
}

fn streamAndWrite(gpa: std.mem.Allocator, src: []const u8) !void {
    var stream = try yaml.Stream.parse(gpa, src, .{}, null);
    defer stream.deinit();
    const out = try stream.toOwnedString(gpa);
    gpa.free(out);
}

fn buildAndEdit(gpa: std.mem.Allocator) !void {
    var doc = try yaml.Document.init(gpa);
    defer doc.deinit();
    try doc.set(&.{ "a", "b" }, try doc.string("x\ny\n"));
    var seq = try doc.newSeq();
    try seq.seq.append(doc.allocator(), try doc.integer(1));
    try doc.set(&.{"s"}, seq);
    try doc.set(&.{ "s", "0" }, doc.nullValue());
    try doc.setComments(&.{ "a", "b" }, .{ .before = &.{"# b"}, .after = "# c" });
    try doc.setComments(&.{ "s", "0" }, .{ .after = "# d" });
    try doc.root.map.putValue(doc.allocator(), try doc.integer(5), doc.boolean(true));
    const out = try doc.toOwnedString(gpa);
    gpa.free(out);
}

fn readAll(gpa: std.mem.Allocator) !void {
    var r: std.Io.Reader = .fixed("a: [1, two]\n");
    var doc = try yaml.Document.parseReader(gpa, &r, .{}, null);
    doc.deinit();
}

// Every allocation is made to fail in turn. Each failure must come back as
// error.OutOfMemory and leave nothing allocated.
test "no leaks or swallowed errors on allocation failure" {
    const sources = [_][]const u8{
        "# c\na: 1 # x\nb:\n  - [1, 2]\n  - k: |\n      text\nc: \"q\"\n",
        "--- # s\n'k': [a b\n  c, {\"d\": e}, f: g]\ntrue:\n  # m\n  folded\n  plain # n\nq: >\n  one\n  two\n\nr:\n- - x\n- y: \"multi\n    line\"\n... # o\n",
        "# root\n[1] # c\n",
    };
    for (sources) |src| try testing.checkAllAllocationFailures(testing.allocator, parseAndWrite, .{src});
    try testing.checkAllAllocationFailures(testing.allocator, streamAndWrite, .{@as([]const u8, "%YAML 1.2\n---\na: [1]\n# c\n...\n# d\n---\nb\n---\n")});
    try testing.checkAllAllocationFailures(testing.allocator, streamAndWrite, .{@as([]const u8, "# nothing\n")});
    try testing.checkAllAllocationFailures(testing.allocator, streamAndWrite, .{@as([]const u8, "%TAG !e! x:\n--- !e!a\n!!str k: !<a:b> [!c v]\nl:\n  !t\n  # c\n  - !!int 1\n")});
    try testing.checkAllAllocationFailures(testing.allocator, parseAndWrite, .{@as([]const u8, "a: &a [1, *a, &b x]\nb: *b\n&c key: &d\n  *c : *d\n")});
    try testing.checkAllAllocationFailures(testing.allocator, parseAndWrite, .{@as([]const u8, "? [a, {b: c}]\n# x\n: - d\n? |\n  e\n: f\n{g: h}: i\n")});
    try testing.checkAllAllocationFailures(testing.allocator, buildAndEdit, .{});
    try testing.checkAllAllocationFailures(testing.allocator, readAll, .{});
}

test "random bytes never crash the parser" {
    var prng = std.Random.DefaultPrng.init(12345);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..4000) |_| {
        const len = rnd.uintLessThan(usize, buf.len);
        rnd.bytes(buf[0..len]);
        if (yaml.Document.parse(testing.allocator, buf[0..len], .{}, null)) |*d| {
            var doc = d.*;
            defer doc.deinit();
            var back = try writeAndRead(&doc);
            back.deinit();
        } else |_| {}
    }
}

// YAML-6: whatever is accepted is written so that it reads back to the same
// tree, and writing that again gives the same text. The input is random
// strings of YAML's own tokens, so that much of it parses.
test "every accepted input survives writing" {
    const tokens = [_][]const u8{ "? ", "\n? ", "\n: ", "[a]: ", "&a ", "*a", "*a ", "&b", "&a", "!", "!!str ", "!!int", "!t ", "!<a:b> ", "!e!x ", "! ", "a", "b", ":", " ", " ", " ", "  ", "\n", "\n", "\n", "- ", "-", "#", " # c", "\"", "'", "[", "]", "{", "}", ",", "|", ">", "+", "2", ".", "...", "---", "\\", "\t", "k: ", "x", "\r", "?", "&", "true", "null", "\\n", "|2", ">-", "\n  ", "\n- ", ": ", "\u{85}", "\u{7f}" };
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var accepted: usize = 0;
    for (0..40_000) |_| {
        buf.clearRetainingCapacity();
        for (0..rnd.uintLessThan(usize, 18)) |_| try buf.appendSlice(testing.allocator, tokens[rnd.uintLessThan(usize, tokens.len)]);
        var doc = yaml.Document.parse(testing.allocator, buf.items, .{}, null) catch continue;
        defer doc.deinit();
        accepted += 1;
        errdefer std.debug.print("input: \"{f}\"\n", .{std.zig.fmtString(buf.items)});
        const out = try doc.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        var back = try parse(out);
        defer back.deinit();
        try expectSame(doc.root, back.root);
        const again = try back.toOwnedString(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(out, again);
    }
    // The same for whole streams, which have more ways to join documents.
    const stream_tokens = tokens ++ [_][]const u8{ "---\n", "...\n", "%YAML 1.2\n", "%TAG !e! x:\n", "%TAG !! y:\n", "%TAG ! !z-\n", "\n---\n", "\n...\n" };
    for (0..40_000) |_| {
        buf.clearRetainingCapacity();
        for (0..rnd.uintLessThan(usize, 18)) |_| try buf.appendSlice(testing.allocator, stream_tokens[rnd.uintLessThan(usize, stream_tokens.len)]);
        var stream = yaml.Stream.parse(testing.allocator, buf.items, .{}, null) catch continue;
        defer stream.deinit();
        errdefer std.debug.print("stream input: \"{f}\"\n", .{std.zig.fmtString(buf.items)});
        const out = try stream.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        var back = try parseStream(out);
        defer back.deinit();
        try testing.expectEqual(stream.documents.len, back.documents.len);
        for (stream.documents, back.documents) |x, y| {
            try expectSame(x.root, y.root);
            try testing.expectEqual(x.directives.len, y.directives.len);
        }
        const again = try back.toOwnedString(testing.allocator);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(out, again);
    }

    // Guards the test itself: it means nothing if little parses.
    try testing.expect(accepted > 5_000);
}

/// Equal values, kinds and key order. Every spelling of null is the same.
fn expectSame(a: yaml.Value, b: yaml.Value) !void {
    try testing.expectEqual(std.meta.activeTag(a), std.meta.activeTag(b));
    try testing.expectEqualStrings(if (a.anchorOf()) |x| x.name else "", if (b.anchorOf()) |y| y.name else "");
    switch (a) {
        .alias => |x| try testing.expectEqualStrings(x.name, b.alias.name),
        .scalar => |s| {
            try testing.expectEqualDeep(s.tag, b.scalar.tag);
            try testing.expectEqual(s.kind, b.scalar.kind);
            if (s.kind != .null) try testing.expectEqualStrings(s.text, b.scalar.text);
        },
        .seq => |q| {
            try testing.expectEqualDeep(q.tag, b.seq.tag);
            try testing.expectEqual(q.items.items.len, b.seq.items.items.len);
            for (q.items.items, b.seq.items.items) |x, y| try expectSame(x, y);
        },
        .map => |m| {
            try testing.expectEqualDeep(m.tag, b.map.tag);
            try testing.expectEqual(m.count(), b.map.count());
            for (m.entries.keys(), m.entries.values(), b.map.entries.keys(), b.map.entries.values()) |k, x, k2, y| {
                try expectSame(k, k2);
                try expectSame(x.value, y.value);
            }
        },
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
    // With nothing after the bracket, the last comment inside moves there.
    try expectStable("a: [1, # first\n  # last\n  2]\n", "a: [1, 2] # last\n");
    try rejects("a: [1, # \x7f\n  2]\n", error.Syntax);
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

test "properties and reserved indicators on keys are not read as text" {
    var doc = try parse("&a key: v\n!!str other: *a\nx: &b more\n*b : again\n");
    defer doc.deinit();
    try testing.expectEqualStrings("v", doc.root.map.getString("key").?);
    try testing.expectEqualStrings("key", doc.root.map.getString("other").?);
    try rejects("*a : 1\n", error.Syntax);
    try rejects("@a: 1\n", error.Syntax);
    try rejects("`a: 1\n", error.Syntax);
    try rejects("%a: 1\nb: 2\n", error.Syntax); // a directive without its `---`
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
    try inner.map.setComments("deep", .{ .before = &.{"# keep me"}, .after = "# me too" });
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
    try testing.expectError(error.NotFound, map.setComments("later", .{ .after = "# orphan" }));
    var key = [_]u8{'a'};
    try map.setComments(&key, .{ .after = "# c" });
    key[0] = 'z';
    try testing.expectEqualStrings("# c", map.commentsOf("a").?.after.?);
    try map.setComments("a", .{});
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
        .{ .src = "a: [1] x\nb: 1\nc: 2\n", .line = 1, .column = 8 },
        // Items that share a line with their dash.
        .{ .src = "- a: 1\n- - [1] x\n", .line = 2, .column = 9 },
        .{ .src = "- k: 1\n  k: 2\n", .line = 2, .column = 3 },
        .{ .src = "- k: 1\n- \"a\": 1\n  'a': 2\n", .line = 3, .column = 3 },
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

test "an empty entry leaves the following comments where they are" {
    try roundTrips("-\n# about the second\n- b\n");
    try roundTrips("-\n-\n# end\n");
    try roundTrips("- # one\n# two\n- # three\n# end\n");
    try roundTrips("a:\n# about b\nb:\n# end\n");
}

test "the indentation step comes from nested collections only" {
    try expectStable("a:\n |\n  x\n", "a: |\n  x\n");
    var doc = try parse("a:\n   v\nb:\n    c: 1\n");
    defer doc.deinit();
    try testing.expectEqual(@as(u8, 4), doc.indent);
}

test "remove, lookup and set on mappings and sequences" {
    var doc = try parse("# a\na: 1 # one\nb: 2\n\"c\": 3\nlist:\n  - x\n  - k: v\n");
    defer doc.deinit();
    try testing.expectEqualStrings("v", doc.lookup(&.{ "list", "1", "k" }).?.scalar.text);
    try testing.expectEqualStrings("x", doc.lookup(&.{ "list", "0" }).?.scalar.text);
    try testing.expect(doc.lookup(&.{ "list", "2" }) == null);
    try testing.expect(doc.lookup(&.{ "list", "k" }) == null);
    try testing.expect(doc.lookup(&.{ "a", "b" }) == null);
    try testing.expect(doc.lookup(&.{"zz"}) == null);

    try doc.set(&.{ "list", "0" }, try doc.string("y"));
    try doc.set(&.{ "list", "1", "k" }, try doc.string("w"));
    try testing.expectError(error.NotFound, doc.set(&.{ "list", "2" }, doc.nullValue()));
    try testing.expectError(error.NotFound, doc.set(&.{ "list", "z" }, doc.nullValue()));
    try testing.expectError(error.NotACollection, doc.set(&.{ "a", "b" }, doc.nullValue()));
    try testing.expectError(error.NotACollection, doc.set(&.{ "a", "b", "c" }, doc.nullValue()));
    try testing.expectError(error.NotFound, doc.setComments(&.{"zz"}, .{}));
    try testing.expectError(error.NotFound, doc.setComments(&.{ "zz", "a" }, .{}));
    try testing.expectError(error.NotACollection, doc.setComments(&.{ "a", "b" }, .{}));
    try doc.setComments(&.{ "list", "1", "k" }, .{ .after = "# deep" });

    try testing.expect(doc.root.map.remove("a"));
    try testing.expect(doc.root.map.remove("c"));
    try testing.expect(!doc.root.map.remove("a"));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("b: 2\nlist:\n  - y\n  - k: w # deep\n", out);
    // A removed key leaves no comments or key style behind.
    try doc.set(&.{"a"}, try doc.integer(5));
    try doc.set(&.{"c"}, try doc.integer(6));
    try testing.expect(doc.root.map.commentsOf("a") == null);
    try testing.expectEqual(yaml.Style.plain, doc.root.map.keys()[doc.root.map.find("c").?].scalar.style);
}

test "typed accessors return null for other types" {
    var doc = try parse("s: x\nm: {a: 1}\nq: [1]\nb: False\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqual(@as(?bool, false), m.getBool("b"));
    try testing.expectEqual(@as(?bool, null), m.getBool("s"));
    try testing.expectEqual(@as(?i64, null), m.getInt("m"));
    try testing.expectEqual(@as(?f64, null), m.getFloat("q"));
    try testing.expect(m.getString("m") == null);
    try testing.expect(m.getMap("q") == null);
    try testing.expect(m.getSeq("m") == null);
    try testing.expect(m.getMap("m") != null);
    try testing.expectEqualStrings("mapping", m.get("m").?.typeName());
    try testing.expectEqualStrings("sequence", m.get("q").?.typeName());
    try testing.expectEqualStrings("boolean", m.get("b").?.typeName());
}

test "reader limits and failures" {
    var exact: std.Io.Reader = .fixed("a: 1\n");
    var doc = try yaml.Document.parseReader(testing.allocator, &exact, .{ .max_bytes = 5 }, null);
    doc.deinit();
    var failing: std.Io.Reader = .failing;
    try testing.expectError(error.ReadFailed, yaml.Document.parseReader(testing.allocator, &failing, .{}, null));
}

test "a large multi-line flow collection" {
    // Took quadratic time before; at this size that is plainly slow.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "a: [\n");
    for (0..100_000) |_| try src.appendSlice(testing.allocator, " 1,\n");
    try src.appendSlice(testing.allocator, " ]\n");
    var doc = try yaml.Document.parse(testing.allocator, src.items, .{}, null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 100_000), doc.root.map.getSeq("a").?.items.items.len);
}

// A deliberate departure from the spec (see ai/SPEC.md).
test "a closing bracket may stand in the parent's column" {
    try expectWritten("a:\n  os: [\n    x, # c\n  ]\n  b: 1\n", "a:\n  os: [x] # c\n  b: 1\n");
    try expectWritten("a:\n  r: ['e', {\n    b: 1\n  }]\n", "a:\n  r: ['e', {b: 1}]\n");
    try expectWritten("- [\n  x\n]\n", "- [x]\n");
    // Only the bracket, and only in that column.
    try rejects("a:\n  os: [\n    x,\n  y]\n", error.Syntax);
    try rejects("a:\n  os: [\n    x\n  , y]\n", error.Syntax);
    try rejects("a:\n  os: [\n    x\n ]\n", error.Syntax);
    try rejects("a:\n  os: [\n    x\n\t]\n", error.Syntax);
}

// The old line-classifying parser accepted these as plain keys.
test "a block key cannot start with a flow indicator" {
    for ([_][]const u8{ "}x: y\n", "]x: y\n", ",x: y\n", "- }x: y\n", "a: 1\n,b: 2\n" }) |src| {
        try rejects(src, error.Syntax);
    }
}

fn parseStream(src: []const u8) !yaml.Stream {
    var diag: yaml.Diagnostic = .{};
    return yaml.Stream.parse(testing.allocator, src, .{}, &diag) catch |e| {
        std.debug.print("unexpected failure on:\n{s}\n-> {f}\n", .{ src, diag });
        return e;
    };
}

/// Parses `src` as a stream and requires `want` as output, which must then be
/// written the same again.
fn expectStream(src: []const u8, documents: usize, want: []const u8) !void {
    for ([_][]const u8{ src, want }) |text| {
        var stream = try parseStream(text);
        defer stream.deinit();
        try testing.expectEqual(documents, stream.documents.len);
        const out = try stream.toOwnedString(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(want, out);
    }
}

fn rejectsStream(src: []const u8, want: anyerror) !void {
    try testing.expectError(want, yaml.Stream.parse(testing.allocator, src, .{}, null));
}

test "a stream of several documents" {
    try expectStream("a: 1\n---\nb: 2\n", 2, "a: 1\n---\nb: 2\n");
    try expectStream("---\n---\n---\n", 3, "---\nnull\n---\nnull\n---\nnull\n");
    try expectStream("a\n...\nb\n...\n", 2, "a\n...\nb\n");
    try expectStream("a: 1\n...\n---\nb: |+\n  x\n\n--- c\n", 3, "a: 1\n...\n---\nb: |+\n  x\n\n---\nc\n");
    try expectStream("", 0, "");
    try expectStream("# only\n\n# comments\n", 0, "# only\n\n# comments\n");
    try expectStream("...\n...\n", 0, "");

    var stream = try parseStream("--- 1\n--- [two]\n--- |\n  3\n---\nk: 4\n");
    defer stream.deinit();
    try testing.expectEqual(@as(usize, 4), stream.documents.len);
    try testing.expectEqual(@as(?i64, 1), stream.documents[0].root.scalar.asInt());
    try testing.expectEqualStrings("3\n", stream.documents[2].root.scalar.text);
    try testing.expectEqual(@as(?i64, 4), stream.documents[3].root.map.getInt("k"));
}

test "comments stay with their document" {
    const src = "# one\na: 1 # x\n# end of one\n...\n# two\n--- # start\nb: 2\n# before three\n---\nc: 3\n# last\n";
    try expectStream(src, 3, "# one\na: 1 # x\n# end of one\n...\n# two\n--- # start\nb: 2\n# before three\n---\nc: 3\n# last\n");
    var stream = try parseStream(src);
    defer stream.deinit();
    try testing.expectEqualStrings("# end of one", stream.documents[0].footer[0]);
    try testing.expectEqualStrings("# two", stream.documents[1].header[0]);
    try testing.expectEqualStrings("# before three", stream.documents[2].header[0]);
    try testing.expectEqualStrings("# last", stream.documents[2].footer[0]);
}

test "each document stands alone, with its own indentation" {
    var stream = try parseStream("a:\n    b: 1\n---\nc:\n  d: 2\n");
    defer stream.deinit();
    try testing.expectEqual(@as(u8, 4), stream.documents[0].indent);
    try testing.expectEqual(@as(u8, 2), stream.documents[1].indent);
    // One document can be edited and written by itself.
    try stream.documents[1].set(&.{ "c", "d" }, try stream.documents[1].integer(3));
    const one = try stream.documents[1].toOwnedString(testing.allocator);
    defer testing.allocator.free(one);
    try testing.expectEqualStrings("---\nc:\n  d: 3\n", one);
}

test "Document.parse still takes one document" {
    try rejects("a: 1\n---\nb: 2\n", error.Unsupported);
    try rejects("a\n...\nb\n", error.Unsupported);
    try rejects("---\n---\n", error.Unsupported);
}

test "directives" {
    try expectStream("%YAML 1.2\n%TAG !e! tag:example.com,2000: # why\n---\na: 1\n", 1, "%YAML 1.2\n%TAG !e! tag:example.com,2000: # why\n---\na: 1\n");
    try expectStream("a\n...\n%YAML 1.1\n---\nb\n", 2, "a\n...\n%YAML 1.1\n---\nb\n");
    try expectStream("%FOO bar baz\n--- x\n", 1, "%FOO bar baz\n---\nx\n");
    // Without '...', a line starting with '%' belongs to the scalar above.
    try expectStream("---\nscalar\n%YAML 1.2\n", 1, "---\nscalar %YAML 1.2\n");

    var doc = try parse("%YAML 1.2\n---\na: 1\n");
    defer doc.deinit();
    try testing.expectEqualStrings("%YAML 1.2", doc.directives[0]);
    // A document with directives is always written with its '---'.
    doc.explicit_start = false;
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("%YAML 1.2\n---\na: 1\n", out);
    doc.directives = &.{"%YAML 2.0"};
    try testing.expectError(error.InvalidDirective, doc.toOwnedString(testing.allocator));
    doc.directives = &.{"%FOO\nb: 2"};
    try testing.expectError(error.InvalidDirective, doc.toOwnedString(testing.allocator));
}

test "invalid directives and streams" {
    for ([_][]const u8{
        "%YAML 1.2\n",                 "%YAML 1.2\na: 1\n",      "%YAML 1.2\n...\n",
        "%YAML 1.2\n%YAML 1.2\n---\n", "%YAML 2.0\n---\n",       "%YAML 1.2 x\n---\n",
        "%YAML 1.2#c\n---\n",          "%YAML\n---\n",           "%TAG !a! x\n%TAG !a! x\n---\n",
        "%TAG a x\n---\n",             "%TAG !a_b! x\n---\n",    "%TAG ! {x\n---\n",
        "%\n---\n",                    "a: 1\n%YAML 1.2\n---\n", "a: 1\n... x\n",
        "a: 1\n---\nb: [\n",
    }) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        try rejectsStream(src, error.Syntax);
    }
}

test "keys are equal when YAML says they are" {
    // Different types are different keys.
    try roundTrips("1: int\n\"1\": string\ntrue: bool\n'true': text\nnull: n\n'null': s\n1.0: float\n");
    // Different spellings of one value are the same key.
    for ([_][]const u8{ "1: a\n0x1: b\n", "10: a\n+10: b\n", "true: a\nTrue: b\n", "~: a\nnull: b\n", "1.5: a\n15e-1: b\n", "a: 1\n\"a\": 2\n", "{.nan: 1, .NaN: 2}\n" }) |src| {
        try rejects(src, error.Syntax);
    }
    var doc = try parse("\"1\": string\n1: int\n2: two\n0x1F: hex\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("string", m.getString("1").?);
    try testing.expectEqualStrings("two", m.getString("2").?);
    try testing.expectEqualStrings("hex", m.getString("0x1F").?);
    // A text lookup does not read numbers.
    try testing.expect(m.getString("31") == null);
    try testing.expectEqualStrings("int", m.getValue(try doc.integer(1)).?.scalar.text);
    // Putting by text keeps the key that is there; a new one is a string.
    try m.put(doc.allocator(), "2", try doc.string("zwei"));
    try m.put(doc.allocator(), "3", try doc.string("drei"));
    try testing.expect(m.removeValue(try doc.integer(1)));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"1\": string\n2: zwei\n0x1F: hex\n\"3\": drei\n", out);
}

test "standard tags decide a value's type" {
    var doc = try parse("a: !!str 12\nb: !!int \"12\"\nc: ! true\nd: !!null x\ne: !!bool abc\nf: !!float 1\ng: !custom 12\nh: !!str\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqual(@as(?i64, null), m.getInt("a"));
    try testing.expectEqualStrings("tag:yaml.org,2002:str", m.get("a").?.scalar.tag.?);
    try testing.expectEqual(@as(?i64, 12), m.getInt("b"));
    try testing.expectEqual(yaml.Kind.string, m.get("c").?.scalar.kind);
    try testing.expectEqualStrings("!", m.get("c").?.scalar.tag.?);
    try testing.expect(m.get("d").?.scalar.isNull());
    // A tag can name a type the text does not spell.
    try testing.expectEqual(@as(?bool, null), m.getBool("e"));
    try testing.expectEqual(@as(?f64, 1), m.getFloat("f"));
    try testing.expectEqual(yaml.Kind.string, m.get("g").?.scalar.kind);
    try testing.expectEqualStrings("!custom", m.get("g").?.scalar.tag.?);
    try testing.expectEqualStrings("", m.getString("h").?);
    try testing.expectEqual(yaml.Kind.string, m.get("h").?.scalar.kind);
}

test "tags are written back, wherever they stand" {
    try roundTrips("a: !!str 12\nb: !local\n  c: !<tag:example.com,2000:x> y\nd: !s\n  - !!int 1\n  - !m\n    k: v\n  - !e\n  - !f # why\n    k: v\n");
    try roundTrips("!!str a: !t\n!u : empty key\nf: !!seq [!a x, !b , !!map {!c k: !d }]\ng: !p |\n  text\nh: ! 12\n");
    try roundTrips("--- !root\na: 1\n");
    try roundTrips("!r\n- 1\n");
    try roundTrips("!just-a-tag\n");
    try roundTrips("- !t k: v\n  !u l: w\n");
    try expectStable("a: !!map\n  !!str b: 1\n", "a: !!map\n  !!str b: 1\n");
    // Properties may be on a line of their own, even for a sequence in its
    // key's column.
    try expectStable("a: !t # c\n- 1\nb:\n  !u\n  x: 1\n", "a: !t # c\n  - 1\nb: !u\n  x: 1\n");
}

test "tag handles come from the document's directives" {
    const src = "%TAG !e! tag:example.com,2000:app/\n%TAG !! tag:other.org:\n%TAG ! !pre-\n---\n- !e!foo%21 a\n- !!str b\n- !bar c\n- !<!bar> d\n- !<tag:yaml.org,2002:str> e\n";
    var doc = try parse(src);
    defer doc.deinit();
    const items = doc.root.seq.items.items;
    try testing.expectEqualStrings("tag:example.com,2000:app/foo!", items[0].scalar.tag.?);
    try testing.expectEqualStrings("tag:other.org:str", items[1].scalar.tag.?);
    try testing.expectEqualStrings("!pre-bar", items[2].scalar.tag.?);
    try testing.expectEqualStrings("!bar", items[3].scalar.tag.?);
    try testing.expectEqualStrings("tag:yaml.org,2002:str", items[4].scalar.tag.?);
    var back = try writeAndRead(&doc);
    defer back.deinit();
    try expectSame(doc.root, back.root);
}

test "tags set through the API are written in a form that reads back" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    const tags = [_][]const u8{ "tag:yaml.org,2002:str", "!local", "!with space", "!a!b", "!x,y", "tag:example.com,2000:t", "!", "!caf\u{e9}", "!100%" };
    for (tags, 0..) |tag, i| {
        var v = try doc.string("v");
        v.scalar.tag = tag;
        var name: [8]u8 = undefined;
        try doc.set(&.{try std.fmt.bufPrint(&name, "k{d}", .{i})}, v);
    }
    var back = try writeAndRead(&doc);
    defer back.deinit();
    try expectSame(doc.root, back.root);
    // Neither a handle nor '!<...>' can hold this.
    var bad = try doc.string("v");
    bad.scalar.tag = "not a uri";
    try doc.set(&.{"bad"}, bad);
    try testing.expectError(error.InvalidTag, doc.toOwnedString(testing.allocator));
}

test "bad tags are rejected" {
    for ([_][]const u8{
        "a: !<> x\n",   "a: !<!> x\n",    "a: !<$:?> x\n", "a: !e!foo x\n",  "a: !!\n",
        "a: !x{y} 1\n", "a: !t%zz 1\n",   "a: !a !b 1\n",  "- !a\n  !b x\n", "a: !t - x\n",
        "!t - a\n",     "a: !<tag:x y\n", "[!a !b x]\n",   "a: !t%ff x\n",
    }) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        try rejects(src, error.Syntax);
    }
    // A handle is known only to the document that declares it.
    try rejectsStream("%TAG !e! x:\n--- !e!a\n--- !e!b\n", error.Syntax);
}

test "keys with tags" {
    try rejects("!!str a: 1\na: 2\n", error.Syntax);
    var doc = try parse("!!int \"1\": a\n!x name: b\nname: c\n!y other: d\n");
    defer doc.deinit();
    const m = doc.root.map;
    try testing.expectEqualStrings("a", m.getString("1").?);
    // The untagged string wins; a tagged key is found when it is alone.
    try testing.expectEqualStrings("c", m.getString("name").?);
    try testing.expectEqualStrings("d", m.getString("other").?);
}

test "an empty tagged value does not take the comments after it" {
    for ([_][]const u8{ "!!int\n# after\n", "a: !t\n# before b\nb: 1\n", "- !t\n# before x\n- x\n" }) |src| {
        try roundTrips(src);
    }
    try expectStable("a:\n  # above\n  !t\n# before b\nb: 1\n", "# above\na: !t\n# before b\nb: 1\n");
    try expectStable("# top\n!t\n# end\n", "# top\n!t\n# end\n");
}

test "anchors and aliases" {
    var doc = try parse("base: &base\n  host: a\n  port: 80\nlist: [&x 1, *x]\nother: *base\ns: &s text\nt: *s\n");
    defer doc.deinit();
    const m = doc.root.map;
    // Lookups follow aliases; the entries show them.
    try testing.expectEqual(@as(?i64, 80), m.getMap("other").?.getInt("port"));
    try testing.expectEqual(m.getMap("base").?, m.getMap("other").?);
    try testing.expectEqualStrings("text", m.getString("t").?);
    try testing.expect(m.entries.values()[m.find("other").?].value == .alias);
    try testing.expectEqualStrings("base", m.entries.values()[m.find("other").?].value.alias.name);
    try testing.expectEqualStrings("mapping", m.entries.values()[m.find("other").?].value.typeName());
    try testing.expectEqual(@as(?i64, 1), doc.lookup(&.{ "list", "1" }).?.scalar.asInt());
    try testing.expectEqualStrings("a", doc.lookup(&.{ "other", "host" }).?.scalar.text);
    var back = try writeAndRead(&doc);
    defer back.deinit();
    try expectSame(doc.root, back.root);
}

test "anchors and aliases are written back" {
    try roundTrips("a: &a 1\nb: *a\n");
    try roundTrips("a: &a\n  b: 1\nc: *a\nd: &d !t\n  - *a\n  - &e\n    k: *d\n  - *e\n");
    try roundTrips("&k key: &v value\nr: &r ref\n*r : *v\ns: *k\nf: [&x a, *x, &y [*x], *y, &z {*x : *y}, *z]\n");
    try roundTrips("--- &r\n- 1\n- *r\n");
    try roundTrips("- &a\n- *a\n- &b # why\n  k: v\n- *b # also\n");
    try roundTrips("a: &a: x\nb: *a:\n");
    // A name may be given again; an alias means the latest one above it.
    var doc = try parse("a: &x 1\nb: *x\nc: &x 2\nd: *x\n");
    defer doc.deinit();
    try testing.expectEqual(@as(?i64, 1), doc.root.map.getInt("b"));
    try testing.expectEqual(@as(?i64, 2), doc.root.map.getInt("d"));
}

test "a node may hold an alias of itself" {
    var doc = try parse("a: &a [1, *a]\nm: &m\n  self: *m\n");
    defer doc.deinit();
    const q = doc.root.map.getSeq("a").?;
    try testing.expectEqual(q, q.items.items[1].deref().seq);
    const m = doc.root.map.getMap("m").?;
    try testing.expectEqual(m, m.getMap("self").?);
    try testing.expectEqual(m, doc.lookup(&.{ "m", "self", "self", "self" }).?.map);
    var back = try writeAndRead(&doc);
    back.deinit();
    // But a key cannot be the node it is in: its hash would not be known.
    try rejects("&a\n*a : 1\n", error.Unsupported);
    try rejects("&a { *a : 1 }\n", error.Unsupported);
}

test "aliases are never expanded" {
    // 'Billion laughs': each level aliases the one before it ten times.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "l0: &l0 [x,x,x,x,x,x,x,x,x,x]\n");
    for (1..30) |i| {
        try src.print(testing.allocator, "l{d}: &l{d} [", .{ i, i });
        for (0..10) |_| try src.print(testing.allocator, "*l{d},", .{i - 1});
        try src.appendSlice(testing.allocator, "]\n");
    }
    // Used as keys too, where they are hashed and compared.
    try src.appendSlice(testing.allocator, "*l29 : a\n*l28 : b\n");
    var doc = try yaml.Document.parse(testing.allocator, src.items, .{}, null);
    defer doc.deinit();
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(out.len < 2 * src.items.len);
    // Expanded, the last level alone would hold 10^30 items.
    try testing.expect(doc.arena.queryCapacity() < 1 << 20);
}

test "many keys that alias one large node stay cheap" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "big: &big [");
    for (0..20_000) |_| try src.appendSlice(testing.allocator, "x,");
    try src.appendSlice(testing.allocator, "]\n");
    for (0..5_000) |i| try src.print(testing.allocator, "m{d}: {{*big : 1}}\n", .{i});
    var doc = try yaml.Document.parse(testing.allocator, src.items, .{}, null);
    doc.deinit();
}

test "keys that alias are compared by what they stand for" {
    try rejects("a: &a k\n*a : 1\nk: 2\n", error.Syntax);
    try rejects("a: &a k\nm: {k: 1, *a : 2}\n", error.Syntax);
    try rejects("&k k: 1\nk: 2\n", error.Syntax);
    var doc = try parse("a: &a name\n*a : found\n");
    defer doc.deinit();
    try testing.expectEqualStrings("found", doc.root.map.getString("name").?);
}

test "bad anchors and aliases are rejected" {
    for ([_][]const u8{
        "a: *x\n",            "a: *x\nb: &x 1\n",    "a: &\n",               "a: *\n",      "a: &x &y 1\n",
        "a: &x *y\n",         "a: &x 1\nb: &y *x\n", "a: &x 1\nb: !t *x\n",  "a: &x[1]\n",  "a: &x - y\n",
        "- &x\n  &y z\n",     "a: &x 1\nb: *x y\n",  "a: &x 1\nb: [*x y]\n", "[&x &y 1]\n", "&x - a\n",
        "a: &x 1\nb: *x#c\n",
    }) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        try rejects(src, error.Syntax);
    }
    // Anchors belong to one document.
    try rejectsStream("a: &x 1\n---\nb: *x\n", error.Syntax);
}

test "editing keeps aliases pointing at their place" {
    var doc = try parse("a: &a 1\nb: *a\nc: &c\n  k: v\nd: *c\n");
    defer doc.deinit();
    // Replacing an anchored value: its aliases stand for the new one.
    try doc.set(&.{"a"}, try doc.integer(2));
    try testing.expectEqual(@as(?i64, 2), doc.root.map.getInt("b"));
    // Editing through an alias edits the shared node.
    try doc.set(&.{ "d", "k" }, try doc.string("w"));
    try testing.expectEqualStrings("w", doc.root.map.getMap("c").?.getString("k").?);
    // Replacing the alias itself leaves the original alone.
    try doc.set(&.{"d"}, try doc.string("plain"));
    try testing.expectEqualStrings("w", doc.root.map.getMap("c").?.getString("k").?);
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a: &a 2\nb: *a\nc: &c\n  k: w\nd: plain\n", out);
}

test "an alias that would not read back is not written" {
    var doc = try parse("a: &a 1\nb: *a\n");
    defer doc.deinit();
    // The anchored node is gone.
    try testing.expect(doc.root.map.remove("a"));
    try testing.expectError(error.BrokenAlias, doc.toOwnedString(testing.allocator));
    // It now comes after its alias.
    var moved = try parse("a: &a 1\nb: *a\n");
    defer moved.deinit();
    const first = moved.root.map.entries.values()[0].value;
    try testing.expect(moved.root.map.remove("a"));
    try moved.root.map.put(moved.allocator(), "a", first);
    try testing.expectError(error.BrokenAlias, moved.toOwnedString(testing.allocator));
    // Another node took the name in between.
    var shadowed = try parse("a: &a 1\nm: 0\nb: *a\n");
    defer shadowed.deinit();
    var other = try shadowed.integer(5);
    _ = try shadowed.anchorNode(&other, "a");
    try shadowed.set(&.{"m"}, other);
    try testing.expectError(error.BrokenAlias, shadowed.toOwnedString(testing.allocator));
}

test "anchors and aliases made through the API" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    var shared = try doc.newMap();
    try shared.map.put(doc.allocator(), "k", try doc.integer(1));
    const anchor = try doc.anchorNode(&shared, "s");
    try doc.set(&.{"first"}, shared);
    try doc.set(&.{"second"}, .{ .alias = anchor });
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("first: &s\n  k: 1\nsecond: *s\n", out);
    anchor.name = "not a name";
    try testing.expectError(error.InvalidAnchor, doc.toOwnedString(testing.allocator));
}

test "explicit keys" {
    try expectStable("? a\n: 1\n? b\nc: 2\n", "a: 1\nb:\nc: 2\n");
    try expectStable("? - a\n  - b\n: - c\n", "?\n  - a\n  - b\n:\n  - c\n");
    try expectStable("?\n- a\n:\n- b\n", "?\n  - a\n:\n  - b\n");
    try expectStable("- ? k: v\n  : w\n", "- ?\n    k: v\n  : w\n");
    try roundTrips("? |\n  block\n  key\n: value\n");
    try roundTrips("? !t\n  - &a x\n: *a\n");
    try roundTrips("- ?\n    a: 1\n  : 2\n");
    var doc = try parse("? [x, y]\n: pair\n? {a: 1}\n: map\n");
    defer doc.deinit();
    try testing.expectEqualStrings("x", doc.root.map.keys()[0].seq.items.items[0].scalar.text);
    try testing.expectEqualStrings("pair", doc.root.map.entries.values()[0].value.scalar.text);
}

test "collections as keys" {
    try roundTrips("[a, b]: c\n{d: e}: f\n[]: g\n&k [h]: *k\n!t {i: j}: l\n");
    try roundTrips("a: {[b]: c, {d: [e]}: f}\n");
    try expectStable("[ [a]: b, \"c\":d, {e: f}:g ]\n", "[{[a]: b}, {\"c\": d}, {{e: f}: g}]\n");
    // A key is found again by its value, however it is written.
    try rejects("[a, b]: 1\n? - a\n  - b\n: 2\n", error.Syntax);
    try rejects("{a: 1, b: 2}: x\n{b: 2, a: 0x1}: y\n", error.Syntax);
    var different = try parse("{a: 1}: x\n{a: \"1\"}: y\n[1]: z\n!t [1]: w\n");
    defer different.deinit();
    try testing.expectEqual(@as(usize, 4), different.root.map.count());
    try testing.expectEqualStrings("y", different.root.map.getValue(different.root.map.keys()[1]).?.scalar.text);
}

test "explicit entries in flow collections" {
    try expectStable("{? a: b, ? c, d: e}\n", "{a: b, c: null, d: e}\n");
    try expectStable("[? a\n  b : c]\n", "[{a b: c}]\n");
    try expectStable("[? d]\n", "[{d: null}]\n");
}

test "comments around an explicit entry are kept" {
    try expectStable("# above\n? a # key\n# between\n: b # value\nz: 1\n", "# above\n# key\n# between\na: b # value\nz: 1\n");
    try expectStable("? a # key\nz: 1\n", "a: # key\nz: 1\n");
    try expectStable("? - a\n  # inside\n  - b\n: c\n", "?\n  - a\n  # inside\n  - b\n: c\n");
}

test "bad complex keys are rejected" {
    for ([_][]const u8{
        "? a\n : b\n",         "[a,\n b]: c\n", "a: [b]: c\n",   "a: ? b\n", "--- ? a\n",
        "&x ? a\n",            "?\t- a\n",      "? a\n:\t- b\n", "[a]:b\n",  "a: 1\n[b]\n",
        "[? a\n: b, : : c]\n",
    }) |src| {
        errdefer std.debug.print("source: {s}\n", .{src});
        try rejects(src, error.Syntax);
    }
}

test "a long key is written in the '?' form" {
    var doc = try yaml.Document.init(testing.allocator);
    defer doc.deinit();
    const long: [1100]u8 = @splat('k');
    try doc.set(&.{&long}, try doc.integer(1));
    const out = try doc.toOwnedString(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "? kkk"));
    var back = try parse(out);
    defer back.deinit();
    try testing.expectEqual(@as(?i64, 1), back.root.map.getInt(&long));
}

test "collection keys count towards max_depth" {
    const opts: yaml.Options = .{ .max_depth = 2 };
    for ([_][]const u8{ "[a]: 1\n", "? - a\n: 1\n", "{[a]: 1}\n" }) |src| {
        var doc = try yaml.Document.parse(testing.allocator, src, opts, null);
        defer doc.deinit();
        const out = try doc.toOwnedString(testing.allocator);
        testing.allocator.free(out);
    }
    for ([_][]const u8{ "[[a]]: 1\n", "x: 0\n[[a]]: 1\n", "? - - a\n: 1\n", "{[[a]]: 1}\n", "[[a]: 1]\n" }) |src| {
        try testing.expectError(error.LimitExceeded, yaml.Document.parse(testing.allocator, src, opts, null));
    }
}
