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
