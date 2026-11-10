//! The YAML data model: scalars, sequences and mappings, with the comments
//! attached to each item.
//!
//! Ownership: everything reachable from a `Document` lives in its arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a scalar means, by the YAML 1.2 core schema. Only plain (unquoted)
/// scalars can be anything but a string.
pub const Kind = enum { null, boolean, integer, float, string };

/// How a scalar was written, kept so a document is written back the same way.
pub const Style = enum { plain, single, double, literal, folded };

pub const Scalar = struct {
    /// The value: for a plain scalar exactly as written (`7.20`, `0x1F`), for
    /// a quoted one or a block scalar after unescaping and folding.
    text: []const u8,
    style: Style = .plain,
    kind: Kind = .string,

    pub fn asBool(self: Scalar) ?bool {
        if (self.kind != .boolean) return null;
        return std.ascii.eqlIgnoreCase(self.text, "true");
    }

    pub fn asInt(self: Scalar) ?i64 {
        if (self.kind != .integer) return null;
        return parseInt(self.text);
    }

    /// An integer is accepted as a float too.
    pub fn asFloat(self: Scalar) ?f64 {
        switch (self.kind) {
            .integer => return @floatFromInt(parseInt(self.text) orelse return null),
            .float => {
                const t = self.text;
                if (std.mem.eql(u8, t, ".inf") or std.mem.eql(u8, t, ".Inf") or std.mem.eql(u8, t, ".INF") or std.mem.eql(u8, t, "+.inf")) return std.math.inf(f64);
                if (std.mem.eql(u8, t, "-.inf") or std.mem.eql(u8, t, "-.Inf") or std.mem.eql(u8, t, "-.INF")) return -std.math.inf(f64);
                if (std.mem.eql(u8, t, ".nan") or std.mem.eql(u8, t, ".NaN") or std.mem.eql(u8, t, ".NAN")) return std.math.nan(f64);
                return std.fmt.parseFloat(f64, t) catch null;
            },
            else => return null,
        }
    }

    pub fn isNull(self: Scalar) bool {
        return self.kind == .null;
    }
};

fn parseInt(t: []const u8) ?i64 {
    if (t.len > 2 and t[0] == '0' and t[1] == 'x') return std.fmt.parseInt(i64, t[2..], 16) catch null;
    if (t.len > 2 and t[0] == '0' and t[1] == 'o') return std.fmt.parseInt(i64, t[2..], 8) catch null;
    return std.fmt.parseInt(i64, t, 10) catch null;
}

/// The meaning of a plain scalar under the core schema (YAML 1.2.2, 10.3.2).
pub fn resolve(t: []const u8) Kind {
    if (t.len == 0) return .null;
    if (eqAny(t, &.{ "~", "null", "Null", "NULL" })) return .null;
    if (eqAny(t, &.{ "true", "True", "TRUE", "false", "False", "FALSE" })) return .boolean;
    if (isInt(t)) return .integer;
    if (isFloat(t)) return .float;
    return .string;
}

fn eqAny(t: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, t, s)) return true;
    return false;
}

fn allIn(s: []const u8, comptime pred: fn (u8) bool) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!pred(c)) return false;
    return true;
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isInt(t: []const u8) bool {
    if (t.len > 2 and t[0] == '0' and t[1] == 'x') return allIn(t[2..], std.ascii.isHex);
    if (t.len > 2 and t[0] == '0' and t[1] == 'o') return allIn(t[2..], isOct);
    const d = if (t[0] == '-' or t[0] == '+') t[1..] else t;
    return allIn(d, std.ascii.isDigit);
}

fn isFloat(t: []const u8) bool {
    if (eqAny(t, &.{ ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN" })) return true;
    // [-+]? ( \. [0-9]+ | [0-9]+ ( \. [0-9]* )? ) ( [eE] [-+]? [0-9]+ )?
    var i: usize = 0;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
    var int_digits: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) int_digits += 1;
    var frac_digits: usize = 0;
    var dot = false;
    if (i < t.len and t[i] == '.') {
        dot = true;
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) frac_digits += 1;
    }
    if (int_digits == 0 and frac_digits == 0) return false;
    if (int_digits == 0 and !dot) return false;
    var exp = false;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        exp = true;
        i += 1;
        if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
        var ed: usize = 0;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) ed += 1;
        if (ed == 0) return false;
    }
    if (i != t.len) return false;
    // A bare integer is an integer, not a float.
    return dot or exp;
}

pub const Value = union(enum) {
    scalar: Scalar,
    seq: *Seq,
    map: *Map,

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .scalar => |s| @tagName(s.kind),
            .seq => "sequence",
            .map => "mapping",
        };
    }
};

/// Comments on one item: the lines above it (each `#...`, or empty for a blank
/// line) and a comment after it on its line (`#...`).
pub const Comments = struct {
    before: []const []const u8 = &.{},
    after: ?[]const u8 = null,

    pub fn isEmpty(self: Comments) bool {
        return self.before.len == 0 and self.after == null;
    }
};

/// A comment line must be empty or start with `#` (after blanks); a trailing
/// comment must start with `#`; neither may contain a line break or control
/// character other than tab.
pub fn checkComments(c: Comments) error{InvalidComment}!void {
    for (c.before) |l| {
        if (l.len != 0) try checkLine(std.mem.trimStart(u8, l, " \t"));
    }
    if (c.after) |a| try checkLine(a);
}

fn checkLine(l: []const u8) error{InvalidComment}!void {
    if (l.len == 0 or l[0] != '#') return error.InvalidComment;
    for (l) |ch| {
        if (ch == '\t') continue;
        if (ch < 0x20 or ch == 0x7F) return error.InvalidComment;
    }
}

pub const Seq = struct {
    items: std.ArrayList(Value) = .empty,
    /// One entry per item (same length as `items`, an empty `Comments` if none).
    comments: std.ArrayList(Comments) = .empty,
    /// Written as `[a, b]` (only if no item is a block collection).
    flow: bool = false,

    pub fn append(self: *Seq, arena: Allocator, v: Value) Allocator.Error!void {
        try self.items.append(arena, v);
        try self.comments.append(arena, .{});
    }
};

pub const Map = struct {
    /// Insertion-ordered, so a document written back keeps its key order.
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    comments: std.StringArrayHashMapUnmanaged(Comments) = .empty,
    /// Written as `{a: 1, b: 2}`.
    flow: bool = false,

    pub fn count(self: *const Map) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Map, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getPtr(self: *Map, key: []const u8) ?*Value {
        return self.entries.getPtr(key);
    }

    /// The scalar text under `key` (any kind), or null.
    pub fn getString(self: *const Map, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .scalar => |s| s.text,
            else => null,
        };
    }

    pub fn getInt(self: *const Map, key: []const u8) ?i64 {
        return switch (self.get(key) orelse return null) {
            .scalar => |s| s.asInt(),
            else => null,
        };
    }

    pub fn getFloat(self: *const Map, key: []const u8) ?f64 {
        return switch (self.get(key) orelse return null) {
            .scalar => |s| s.asFloat(),
            else => null,
        };
    }

    pub fn getBool(self: *const Map, key: []const u8) ?bool {
        return switch (self.get(key) orelse return null) {
            .scalar => |s| s.asBool(),
            else => null,
        };
    }

    pub fn getMap(self: *const Map, key: []const u8) ?*Map {
        return switch (self.get(key) orelse return null) {
            .map => |m| m,
            else => null,
        };
    }

    pub fn getSeq(self: *const Map, key: []const u8) ?*Seq {
        return switch (self.get(key) orelse return null) {
            .seq => |s| s,
            else => null,
        };
    }

    /// Sets `key`, replacing any value (its comments stay). `key` and the
    /// value's storage must be arena-owned.
    pub fn put(self: *Map, arena: Allocator, key: []const u8, v: Value) Allocator.Error!void {
        const gop = try self.entries.getOrPut(arena, key);
        if (!gop.found_existing) gop.key_ptr.* = key;
        gop.value_ptr.* = v;
    }

    /// Removes `key` and its comments, keeping the order of the rest.
    pub fn remove(self: *Map, key: []const u8) bool {
        _ = self.comments.orderedRemove(key);
        return self.entries.orderedRemove(key);
    }

    pub fn commentsOf(self: *const Map, key: []const u8) ?Comments {
        return self.comments.get(key);
    }

    pub fn setComments(self: *Map, arena: Allocator, key: []const u8, c: Comments) (Allocator.Error || error{InvalidComment})!void {
        try checkComments(c);
        if (c.isEmpty()) {
            _ = self.comments.orderedRemove(key);
            return;
        }
        const k = self.entries.getKey(key) orelse key;
        try self.comments.put(arena, k, c);
    }
};
