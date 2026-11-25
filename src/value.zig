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

    /// An integer is accepted as a float too, including one too large for
    /// `asInt` (with the usual loss of precision).
    pub fn asFloat(self: Scalar) ?f64 {
        const t = self.text;
        switch (self.kind) {
            .integer => {
                if (parseInt(t)) |i| return @floatFromInt(i);
                // A large hexadecimal or octal number.
                if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'o')) {
                    const base: u8 = if (t[1] == 'x') 16 else 8;
                    var f: f64 = 0;
                    for (t[2..]) |c| {
                        const digit = std.fmt.charToDigit(c, base) catch return null;
                        f = f * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(digit));
                    }
                    return f;
                }
                return std.fmt.parseFloat(f64, t) catch null;
            },
            .float => {
                if (eqAny(t, &positive_infinity)) return std.math.inf(f64);
                if (eqAny(t, &negative_infinity)) return -std.math.inf(f64);
                if (eqAny(t, &not_a_number)) return std.math.nan(f64);
                return std.fmt.parseFloat(f64, t) catch null;
            },
            else => return null,
        }
    }

    pub fn isNull(self: Scalar) bool {
        return self.kind == .null;
    }
};

// The special floats of the core schema.
const positive_infinity = [_][]const u8{ ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF" };
const negative_infinity = [_][]const u8{ "-.inf", "-.Inf", "-.INF" };
const not_a_number = [_][]const u8{ ".nan", ".NaN", ".NAN" };

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
    if (eqAny(t, &positive_infinity) or eqAny(t, &negative_infinity) or eqAny(t, &not_a_number)) return true;
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

/// The offset of the first character outside YAML 1.2.2 `c-printable` (line
/// breaks count as outside it here), or null. `s` must be valid UTF-8.
pub fn findNonPrintable(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (nonPrintableAt(s, i) != null) return i;
        i += 1;
    }
    return null;
}

pub const NonPrintable = struct { codepoint: u21, len: usize };

/// The non-printable character that starts at byte `i` of valid UTF-8, if one does.
pub fn nonPrintableAt(s: []const u8, i: usize) ?NonPrintable {
    const c = s[i];
    if (c == '\t') return null;
    if (c < 0x20 or c == 0x7F) return .{ .codepoint = c, .len = 1 };
    // C1 controls except next line (U+0085): C2 80 .. C2 9F.
    if (c == 0xC2 and i + 1 < s.len and s[i + 1] >= 0x80 and s[i + 1] <= 0x9F and s[i + 1] != 0x85)
        return .{ .codepoint = s[i + 1], .len = 2 };
    // U+FFFE and U+FFFF: EF BF BE and EF BF BF.
    if (c == 0xEF and i + 2 < s.len and s[i + 1] == 0xBF and s[i + 2] >= 0xBE)
        return .{ .codepoint = if (s[i + 2] == 0xBE) 0xFFFE else 0xFFFF, .len = 3 };
    return null;
}

/// A directive line (YAML 1.2.2, 6.8).
pub const Directive = union(enum) {
    yaml,
    tag: struct { handle: []const u8, prefix: []const u8 },
    /// A directive the specification reserves; it is ignored.
    reserved,
};

/// Reads a whole directive line, which may end in a comment.
pub fn parseDirective(line: []const u8) error{InvalidDirective}!Directive {
    if (line.len < 2 or line[0] != '%') return error.InvalidDirective;
    if (!std.unicode.utf8ValidateSlice(line) or findNonPrintable(line) != null) return error.InvalidDirective;
    if (isBlankByte(line[1])) return error.InvalidDirective;
    var it = std.mem.tokenizeAny(u8, line[1..], " \t");
    const name = it.next() orelse return error.InvalidDirective;
    var params: [2][]const u8 = undefined;
    var count: usize = 0;
    while (it.next()) |word| {
        if (word[0] == '#') break;
        if (count < params.len) params[count] = word;
        count += 1;
    }
    if (std.mem.eql(u8, name, "YAML")) {
        // Any 1.x document is read by the 1.2 rules.
        if (count != 1) return error.InvalidDirective;
        const dot = std.mem.indexOfScalar(u8, params[0], '.') orelse return error.InvalidDirective;
        if (!std.mem.eql(u8, params[0][0..dot], "1")) return error.InvalidDirective;
        const minor = params[0][dot + 1 ..];
        if (minor.len == 0) return error.InvalidDirective;
        for (minor) |c| if (!std.ascii.isDigit(c)) return error.InvalidDirective;
        return .yaml;
    }
    if (std.mem.eql(u8, name, "TAG")) {
        if (count != 2 or !isTagHandle(params[0])) return error.InvalidDirective;
        const prefix = params[1];
        // `!local-prefix`, or a URI that does not start like a flow collection.
        if (std.mem.findScalar(u8, ",[]{}", prefix[0]) != null or !isUri(prefix)) return error.InvalidDirective;
        return .{ .tag = .{ .handle = params[0], .prefix = prefix } };
    }
    return .reserved;
}

fn isBlankByte(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// `!`, `!!` or `!name!`.
pub fn isTagHandle(h: []const u8) bool {
    if (h.len == 0 or h[0] != '!') return false;
    if (h.len == 1) return true;
    if (h[h.len - 1] != '!') return false;
    for (h[1 .. h.len - 1]) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

/// Made of `ns-uri-char`: URI characters, with others as `%XX`.
pub fn isUri(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') {
            if (i + 2 >= s.len or !std.ascii.isHex(s[i + 1]) or !std.ascii.isHex(s[i + 2])) return false;
            i += 2;
        } else if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "-#;/?:@&=+$,_.!~*'()[]", c) == null) return false;
    }
    return true;
}

/// A comment line must be empty or start with `#` (after blanks, which are
/// not written: comments take their item's indent); a trailing
/// comment must start with `#`; both must be valid UTF-8 without line breaks
/// or non-printable characters.
pub fn checkComments(c: Comments) error{InvalidComment}!void {
    for (c.before) |l| {
        if (l.len != 0) try checkLine(std.mem.trimStart(u8, l, " \t"));
    }
    if (c.after) |a| try checkLine(a);
}

fn checkLine(l: []const u8) error{InvalidComment}!void {
    if (l.len == 0 or l[0] != '#') return error.InvalidComment;
    if (!std.unicode.utf8ValidateSlice(l) or findNonPrintable(l) != null) return error.InvalidComment;
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

/// Compares map keys as YAML does (1.2.2, 3.2.1.3): the same tag and the same
/// canonical content. `1`, `0x1` and `"1"` are two keys: an integer and a
/// string.
pub const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Value) u32 {
        var h = std.hash.Wyhash.init(0);
        var budget: usize = compare_budget;
        hashValue(&h, key, &budget);
        return @truncate(h.final());
    }

    pub fn eql(_: KeyContext, a: Value, b: Value, _: usize) bool {
        var budget: usize = compare_budget;
        return sameKey(a, b, &budget);
    }
};

/// How many nodes comparing two keys may visit.
const compare_budget: usize = 1 << 16;

/// The tag that decides what a scalar is: its own, or the one the core schema
/// gives it.
fn effectiveTag(s: Scalar) []const u8 {
    return switch (s.kind) {
        .null => "tag:yaml.org,2002:null",
        .boolean => "tag:yaml.org,2002:bool",
        .integer => "tag:yaml.org,2002:int",
        .float => "tag:yaml.org,2002:float",
        .string => "tag:yaml.org,2002:str",
    };
}

/// A scalar's canonical content: every spelling of a null, a boolean or a
/// number that means the same gives the same bytes.
fn canonical(s: Scalar, buffer: *[64]u8) []const u8 {
    switch (s.kind) {
        .null => return "",
        .boolean => return if (s.asBool() orelse return s.text) "true" else "false",
        .integer => {
            const i = parseInt(s.text) orelse return s.text;
            return std.fmt.bufPrint(buffer, "{d}", .{i}) catch unreachable;
        },
        .float => {
            const f = s.asFloat() orelse return s.text;
            if (std.math.isNan(f)) return ".nan";
            // `-0.0` and `0.0` compare equal.
            return std.fmt.bufPrint(buffer, "{x}", .{@as(u64, @bitCast(if (f == 0) @as(f64, 0) else f))}) catch unreachable;
        },
        .string => return s.text,
    }
}

fn hashScalar(h: *std.hash.Wyhash, tag: []const u8, content: []const u8) void {
    h.update(tag);
    h.update("\x00");
    h.update(content);
}

fn hashValue(h: *std.hash.Wyhash, v: Value, budget: *usize) void {
    if (budget.* == 0) return;
    budget.* -= 1;
    switch (v) {
        .scalar => |s| {
            var buffer: [64]u8 = undefined;
            hashScalar(h, effectiveTag(s), canonical(s, &buffer));
        },
        .seq => |q| {
            h.update("[");
            for (q.items.items) |item| hashValue(h, item, budget);
        },
        .map => |m| {
            // The order of a mapping's keys is not part of its value.
            var sum: u64 = 0;
            for (m.entries.keys(), m.entries.values()) |k, e| {
                var one = std.hash.Wyhash.init(1);
                hashValue(&one, k, budget);
                hashValue(&one, e.value, budget);
                sum +%= one.final();
            }
            h.update("{");
            h.update(std.mem.asBytes(&sum));
        },
    }
}

fn sameKey(a: Value, b: Value, budget: *usize) bool {
    if (budget.* == 0) return false;
    budget.* -= 1;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .scalar => |s| {
            if (!std.mem.eql(u8, effectiveTag(s), effectiveTag(b.scalar))) return false;
            var x: [64]u8 = undefined;
            var y: [64]u8 = undefined;
            return std.mem.eql(u8, canonical(s, &x), canonical(b.scalar, &y));
        },
        .seq => |q| {
            if (q == b.seq) return true;
            if (q.items.items.len != b.seq.items.items.len) return false;
            for (q.items.items, b.seq.items.items) |i, j| if (!sameKey(i, j, budget)) return false;
            return true;
        },
        .map => |m| {
            if (m == b.map) return true;
            if (m.count() != b.map.count()) return false;
            for (m.entries.keys(), m.entries.values()) |k, e| {
                const other = b.map.entries.get(k) orelse return false;
                if (!sameKey(e.value, other.value, budget)) return false;
            }
            return true;
        },
    }
}

/// Finds a scalar key written as `text` and typed `kind`.
const TextKey = struct {
    kind: Kind,

    pub fn hash(self: TextKey, text: []const u8) u32 {
        const s: Scalar = .{ .text = text, .kind = self.kind };
        var buffer: [64]u8 = undefined;
        var h = std.hash.Wyhash.init(0);
        hashScalar(&h, effectiveTag(s), canonical(s, &buffer));
        return @truncate(h.final());
    }

    pub fn eql(self: TextKey, text: []const u8, key: Value, _: usize) bool {
        return key == .scalar and key.scalar.kind == self.kind and std.mem.eql(u8, key.scalar.text, text);
    }
};

pub const Map = struct {
    /// Keys to values, in insertion order, so a document written back keeps its
    /// key order. A key is any value; most are scalars. A key that is a
    /// collection must not be changed while it is in the map.
    entries: Entries = .empty,
    /// Written as `{a: 1, b: 2}`.
    flow: bool = false,

    pub const Entry = struct {
        value: Value,
        comments: Comments = .{},
    };
    pub const Entries = std.ArrayHashMapUnmanaged(Value, Entry, KeyContext, true);

    pub fn count(self: *const Map) usize {
        return self.entries.count();
    }

    /// The keys in order.
    pub fn keys(self: *const Map) []const Value {
        return self.entries.keys();
    }

    /// The position of the scalar key written as `text`. If there are several,
    /// such as `1` and `"1"`, the string wins.
    pub fn find(self: *const Map, text: []const u8) ?usize {
        if (self.entries.getIndexAdapted(text, TextKey{ .kind = .string })) |i| return i;
        const kind = resolve(text);
        if (kind == .string) return null;
        return self.entries.getIndexAdapted(text, TextKey{ .kind = kind });
    }

    pub fn get(self: *const Map, key: []const u8) ?Value {
        return self.entries.values()[self.find(key) orelse return null].value;
    }

    pub fn getPtr(self: *Map, key: []const u8) ?*Value {
        return &self.entries.values()[self.find(key) orelse return null].value;
    }

    /// The value under a key of any kind.
    pub fn getValue(self: *const Map, key: Value) ?Value {
        return (self.entries.get(key) orelse return null).value;
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

    /// Sets the value under the scalar key written as `key`, keeping that key
    /// and its comments, or adds `key` as a string. `key` and the value's
    /// storage must be arena-owned.
    pub fn put(self: *Map, arena: Allocator, key: []const u8, v: Value) Allocator.Error!void {
        if (self.find(key)) |i| {
            self.entries.values()[i].value = v;
        } else try self.putValue(arena, .{ .scalar = .{ .text = key } }, v);
    }

    /// `put` for a key of any kind.
    pub fn putValue(self: *Map, arena: Allocator, key: Value, v: Value) Allocator.Error!void {
        const gop = try self.entries.getOrPut(arena, key);
        if (gop.found_existing) {
            gop.value_ptr.value = v;
        } else gop.value_ptr.* = .{ .value = v };
    }

    /// Removes `key` and its comments, keeping the order of the rest.
    pub fn remove(self: *Map, key: []const u8) bool {
        self.entries.orderedRemoveAt(self.find(key) orelse return false);
        return true;
    }

    pub fn removeValue(self: *Map, key: Value) bool {
        return self.entries.orderedRemove(key);
    }

    pub fn commentsOf(self: *const Map, key: []const u8) ?Comments {
        const c = self.entries.values()[self.find(key) orelse return null].comments;
        return if (c.isEmpty()) null else c;
    }

    /// Sets or (with empty `c`) removes the comments of an existing key. The
    /// strings in `c` must be arena-owned.
    pub fn setComments(self: *Map, key: []const u8, c: Comments) error{ InvalidComment, NotFound }!void {
        try checkComments(c);
        self.entries.values()[self.find(key) orelse return error.NotFound].comments = c;
    }
};
