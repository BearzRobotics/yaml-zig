//! Runs the official YAML test suite, https://github.com/yaml/yaml-test-suite,
//! which is not vendored:
//!
//!   scripts/fetch-conformance.sh
//!   zig build conformance -Dsuite=conformance-suite
//!
//! yaml-zig reads a documented subset of YAML, so each case lands in one of
//! these groups:
//!
//!   pass         read with the structure in the case's `test.event` (every
//!                node's kind, style and text) and the value in its
//!                `in.json`, and read the same again after being written; or
//!                an invalid input that is rejected
//!   unsupported  valid input refused with `error.Unsupported`
//!   FAIL         anything else: valid input rejected as malformed, a wrong
//!                value, output that does not read back, or invalid input
//!                that is accepted
//!   on purpose   one of `rejected_on_purpose`
//!
//! Every failing case is listed, and the step fails if there is one.

const std = @import("std");
const yaml = @import("yaml");
const Json = std.json.Value;

const max_file = 1 << 20;

/// Cases where refusing the input is deliberate. The suite checks syntax only;
/// the specification also requires a mapping's keys to be unique (YAML 1.2.2,
/// 3.2.1.1), and this library reports a repeat as malformed.
const rejected_on_purpose = [_]struct { case: []const u8, why: []const u8 }{
    .{ .case = "2JQS", .why = "two empty keys in one mapping" },
};

const Outcome = enum { pass, unsupported, on_purpose, rejected_valid, wrong_structure, wrong_value, bad_round_trip, accepted_invalid };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: conformance PATH/yaml-test-suite\n", .{});
        std.process.exit(2);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "in.yaml")) continue;
        const case = std.fs.path.dirname(entry.path) orelse continue;
        try names.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, case));
    }
    if (names.items.len == 0) {
        std.debug.print("no cases found in {s}\n", .{args[1]});
        std.process.exit(2);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var counts: std.EnumArray(Outcome, usize) = .initFill(0);
    for (names.items) |name| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var case = try dir.openDir(io, name, .{});
        defer case.close(io);
        var outcome = try runCase(gpa, arena.allocator(), io, case);
        if (outcome == .rejected_valid) {
            for (rejected_on_purpose) |known| {
                if (!std.mem.eql(u8, known.case, name)) continue;
                outcome = .on_purpose;
                std.debug.print("on purpose {s}: {s}\n", .{ name, known.why });
            }
        }
        counts.getPtr(outcome).* += 1;
        if (isFailure(outcome)) std.debug.print("FAIL {s}: {t}\n", .{ name, outcome });
    }

    std.debug.print("{d} cases:", .{names.items.len});
    var failed: usize = 0;
    for (std.enums.values(Outcome)) |o| {
        std.debug.print(" {t}={d}", .{ o, counts.get(o) });
        if (isFailure(o)) failed += counts.get(o);
    }
    std.debug.print("\n", .{});
    if (failed != 0) std.process.exit(1);
}

fn isFailure(o: Outcome) bool {
    return o != .pass and o != .unsupported and o != .on_purpose;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn runCase(gpa: std.mem.Allocator, a: std.mem.Allocator, io: std.Io, case: std.Io.Dir) !Outcome {
    const source = try case.readFileAlloc(io, "in.yaml", a, .limited(max_file));
    const must_fail = if (case.access(io, "error", .{})) |_| true else |_| false;

    var doc = yaml.Document.parse(gpa, source, .{}, null) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (must_fail) return .pass;
        return if (e == error.Unsupported) .unsupported else .rejected_valid;
    };
    defer doc.deinit();
    if (must_fail) return .accepted_invalid;

    const expected = try case.readFileAlloc(io, "test.event", a, .limited(max_file));
    if (!try sameStructure(a, &doc, expected)) return .wrong_structure;

    const json_text: ?[]const u8 = case.readFileAlloc(io, "in.json", a, .limited(max_file)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (json_text) |t| {
        // An empty file means no document. A stream of several documents is
        // not one JSON value, and must not have been read as one document.
        if (std.mem.trim(u8, t, " \r\n").len != 0) {
            const want = std.json.parseFromSliceLeaky(Json, a, t, .{}) catch return .wrong_value;
            if (!matches(doc.root, want)) return .wrong_value;
        }
    }

    const written = try doc.toOwnedString(a);
    var again = yaml.Document.parse(gpa, written, .{}, null) catch return .bad_round_trip;
    defer again.deinit();
    if (!same(doc.root, again.root)) return .bad_round_trip;
    return .pass;
}

/// Compares `doc` with the suite's event stream. Whether a document's start
/// and end markers were written is left out: it is not part of the tree.
fn sameStructure(a: std.mem.Allocator, doc: *const yaml.Document, expected: []const u8) !bool {
    var want: std.Io.Writer.Allocating = .init(a);
    var documents: usize = 0;
    var lines = std.mem.tokenizeAny(u8, expected, "\r\n");
    while (lines.next()) |raw| {
        // Leading blanks only show nesting; trailing ones are scalar text.
        var line = std.mem.trimStart(u8, raw, " ");
        if (std.mem.startsWith(u8, line, "+DOC")) {
            documents += 1;
            line = "+DOC";
        } else if (std.mem.startsWith(u8, line, "-DOC")) line = "-DOC";
        try want.writer.print("{s}\n", .{line});
    }
    if (documents > 1) return false;

    var got: std.Io.Writer.Allocating = .init(a);
    const w = &got.writer;
    try w.writeAll("+STR\n");
    // A stream without a document reads as an empty one.
    if (documents != 0) {
        try w.writeAll("+DOC\n");
        try events(w, doc.root);
        try w.writeAll("-DOC\n");
    } else if (doc.root != .scalar or doc.root.scalar.text.len != 0) return false;
    try w.writeAll("-STR\n");
    return std.mem.eql(u8, got.written(), want.written());
}

fn events(w: *std.Io.Writer, v: yaml.Value) !void {
    switch (v) {
        .scalar => |s| try scalarEvent(w, s.style, s.text),
        .seq => |q| {
            try w.print("+SEQ{s}\n", .{if (q.flow) " []" else ""});
            for (q.items.items) |item| try events(w, item);
            try w.writeAll("-SEQ\n");
        },
        .map => |m| {
            try w.print("+MAP{s}\n", .{if (m.flow) " {}" else ""});
            for (m.entries.keys(), m.entries.values()) |k, item| {
                try scalarEvent(w, m.key_styles.get(k) orelse .plain, k);
                try events(w, item);
            }
            try w.writeAll("-MAP\n");
        },
    }
}

fn scalarEvent(w: *std.Io.Writer, style: yaml.Style, text: []const u8) !void {
    const indicator: u8 = switch (style) {
        .plain => ':',
        .single => '\'',
        .double => '"',
        .literal => '|',
        .folded => '>',
    };
    try w.print("=VAL {c}", .{indicator});
    for (text) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        8 => try w.writeAll("\\b"),
        else => try w.writeByte(c),
    };
    try w.writeByte('\n');
}

fn matches(v: yaml.Value, want: Json) bool {
    switch (want) {
        .null => return v == .scalar and v.scalar.kind == .null,
        .bool => |b| return v == .scalar and v.scalar.asBool() == b,
        .integer => |i| return v == .scalar and v.scalar.asInt() == i,
        .float => |f| return v == .scalar and v.scalar.asFloat() == f,
        .number_string => |s| return v == .scalar and std.mem.eql(u8, v.scalar.text, s),
        .string => |s| return v == .scalar and v.scalar.kind == .string and std.mem.eql(u8, v.scalar.text, s),
        .array => |list| {
            if (v != .seq or v.seq.items.items.len != list.items.len) return false;
            for (v.seq.items.items, list.items) |x, y| if (!matches(x, y)) return false;
            return true;
        },
        .object => |object| {
            if (v != .map or v.map.count() != object.count()) return false;
            for (object.keys(), object.values()) |k, y| if (!matches(v.map.get(k) orelse return false, y)) return false;
            return true;
        },
    }
}

/// Equal values, kinds and key order (every spelling of null is the same).
fn same(a: yaml.Value, b: yaml.Value) bool {
    switch (a) {
        .scalar => |s| return b == .scalar and s.kind == b.scalar.kind and
            (s.kind == .null or std.mem.eql(u8, s.text, b.scalar.text)),
        .seq => |q| {
            if (b != .seq or q.items.items.len != b.seq.items.items.len) return false;
            for (q.items.items, b.seq.items.items) |x, y| if (!same(x, y)) return false;
            return true;
        },
        .map => |m| {
            if (b != .map or m.count() != b.map.count()) return false;
            for (m.entries.keys(), m.entries.values(), b.map.entries.keys(), b.map.entries.values()) |k, x, k2, y| {
                if (!std.mem.eql(u8, k, k2) or !same(x, y)) return false;
            }
            return true;
        },
    }
}
