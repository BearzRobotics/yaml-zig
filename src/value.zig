//! The YAML data model: scalars, sequences, mappings and aliases, with the
//! comments attached to each item, and the rules the reader and writer share
//! (core schema types, tags, directives, equality of keys).
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
    /// The tag written on the node, in full (`tag:yaml.org,2002:str`,
    /// `!local`, or `!` for the non-specific tag), or null if it has none.
    tag: ?[]const u8 = null,
    /// The anchor on the node, which aliases refer to.
    anchor: ?*Anchor = null,

    pub fn asBool(self: Scalar) ?bool {
        // A tag can give the kind to text that is not a boolean.
        if (self.kind != .boolean or resolve(self.text) != .boolean) return null;
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

/// The prefix of the tags the specification defines, written `!!`.
pub const core_prefix = "tag:yaml.org,2002:";

/// What a scalar means, given its tag, style and text. A tag decides; a tag
/// this library does not interpret leaves the scalar a string.
pub fn kindOf(tag: ?[]const u8, style: Style, text: []const u8) Kind {
    const t = tag orelse return if (style == .plain) resolve(text) else .string;
    if (!std.mem.startsWith(u8, t, core_prefix)) return .string;
    const name = t[core_prefix.len..];
    if (std.mem.eql(u8, name, "null")) return .null;
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    if (std.mem.eql(u8, name, "int")) return .integer;
    if (std.mem.eql(u8, name, "float")) return .float;
    return .string;
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

/// `&name` on a node. The node carries a pointer to this, and so does every
/// alias of it.
pub const Anchor = struct {
    name: []const u8,
    /// The anchored node. Never an alias.
    value: Value,
    /// False only while the parser is still inside the node.
    complete: bool = true,
    /// The node's hash as a key.
    hash: ?u64 = null,
};

pub const Value = union(enum) {
    scalar: Scalar,
    seq: *Seq,
    map: *Map,
    /// `*name`: the anchored node once more. It is a reference and is never
    /// expanded, so a document is no larger in memory than its text suggests.
    /// A node can hold an alias of itself, so code that follows aliases must
    /// bound how far it goes.
    alias: *Anchor,

    /// The node an alias stands for; any other value as it is.
    pub fn deref(self: Value) Value {
        return switch (self) {
            .alias => |a| a.value,
            else => self,
        };
    }

    /// The anchor on this node (an alias has none of its own).
    pub fn anchorOf(self: Value) ?*Anchor {
        return switch (self) {
            .scalar => |s| s.anchor,
            .seq => |q| q.anchor,
            .map => |m| m.anchor,
            .alias => null,
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self.deref()) {
            .scalar => |s| @tagName(s.kind),
            .seq => "sequence",
            .map => "mapping",
            .alias => unreachable,
        };
    }
};

/// Puts `new` where `slot` was. An anchor stays with its place: aliases of the
/// old node become aliases of the new one.
pub fn replaceNode(slot: *Value, new: Value) void {
    const anchor = slot.anchorOf();
    slot.* = new;
    const a = anchor orelse return;
    switch (slot.*) {
        .scalar => |*s| if (s.anchor == null) {
            s.anchor = a;
        } else return,
        .seq => |q| if (q.anchor == null) {
            q.anchor = a;
        } else return,
        .map => |m| if (m.anchor == null) {
            m.anchor = a;
        } else return,
        // The anchored node is gone; writing will say so if it is still used.
        .alias => return,
    }
    sealAnchor(a, slot.*);
}

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

/// Made of `ns-anchor-char`: anything printable but blanks and `[]{},`.
pub fn isAnchorName(name: []const u8) bool {
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or findNonPrintable(name) != null) return false;
    if (std.mem.indexOf(u8, name, "\u{feff}") != null) return false;
    return std.mem.findAny(u8, name, " \t\r\n[]{},") == null;
}

/// What may stand between `!<` and `>`: a local tag (`!` and more) or a URI
/// with a scheme.
pub fn isVerbatimTag(uri: []const u8) bool {
    if (uri.len == 0 or !isUri(uri)) return false;
    if (uri[0] == '!') return uri.len > 1;
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
    for (uri[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    return true;
}

/// A character of a tag shorthand's suffix that needs no `%XX`.
fn isTagChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "-#;/?:@&=+$_.~*'()", c) != null;
}

/// `prefix` and the decoded `suffix` of a shorthand, or null if the suffix is
/// badly formed.
pub fn expandTag(arena: Allocator, prefix: []const u8, suffix: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, prefix);
    var i: usize = 0;
    while (i < suffix.len) : (i += 1) {
        if (suffix[i] == '%') {
            if (i + 2 >= suffix.len) return null;
            const byte = std.fmt.parseInt(u8, suffix[i + 1 .. i + 3], 16) catch return null;
            if (!std.ascii.isHex(suffix[i + 1]) or !std.ascii.isHex(suffix[i + 2])) return null;
            try out.append(arena, byte);
            i += 2;
        } else if (isTagChar(suffix[i])) {
            try out.append(arena, suffix[i]);
        } else return null;
    }
    if (!std.unicode.utf8ValidateSlice(out.items)) return null;
    return out.items;
}

/// How a tag is written: a handle and a suffix, or whole as `!<...>`.
pub const TagForm = union(enum) {
    non_specific,
    shorthand: struct { handle: []const u8, suffix: []const u8 },
    verbatim: []const u8,
};

/// The most `%TAG` directives one document may have. Real documents have a
/// few; the limit keeps the work done for each tag small.
pub const max_tag_directives = 64;

/// A document's tag handles, read from its directives once.
pub const TagTable = struct {
    primary: []const u8 = "!",
    secondary: []const u8 = core_prefix,
    named: [max_tag_directives]Handle = undefined,
    count: usize = 0,

    const Handle = struct { handle: []const u8, prefix: []const u8 };

    pub fn init(directives: []const []const u8) error{InvalidDirective}!TagTable {
        var table: TagTable = .{};
        var tags: usize = 0;
        for (directives) |line| {
            const d = try parseDirective(line);
            if (d != .tag) continue;
            tags += 1;
            if (tags > max_tag_directives) return error.InvalidDirective;
            if (std.mem.eql(u8, d.tag.handle, "!")) {
                table.primary = d.tag.prefix;
            } else if (std.mem.eql(u8, d.tag.handle, "!!")) {
                table.secondary = d.tag.prefix;
            } else {
                table.named[table.count] = .{ .handle = d.tag.handle, .prefix = d.tag.prefix };
                table.count += 1;
            }
        }
        return table;
    }

    /// Chooses a form that reads back as `tag`, or fails if there is none.
    pub fn form(self: *const TagTable, tag: []const u8) error{InvalidTag}!TagForm {
        if (tag.len == 0 or !std.unicode.utf8ValidateSlice(tag)) return error.InvalidTag;
        if (std.mem.eql(u8, tag, "!")) return .non_specific;
        var best: ?Handle = null;
        for (self.named[0..self.count]) |h| {
            if ((best == null or h.prefix.len > best.?.prefix.len) and h.prefix.len < tag.len and std.mem.startsWith(u8, tag, h.prefix))
                best = h;
        }
        if (best) |h| return .{ .shorthand = .{ .handle = h.handle, .suffix = tag[h.prefix.len..] } };
        for ([_]Handle{ .{ .handle = "!!", .prefix = self.secondary }, .{ .handle = "!", .prefix = self.primary } }) |h| {
            if (h.prefix.len < tag.len and std.mem.startsWith(u8, tag, h.prefix))
                return .{ .shorthand = .{ .handle = h.handle, .suffix = tag[h.prefix.len..] } };
        }
        if (isVerbatimTag(tag)) return .{ .verbatim = tag };
        return error.InvalidTag;
    }
};

/// Writes `form`, escaping what a suffix cannot hold as `%XX`.
pub fn writeTag(w: *std.Io.Writer, form: TagForm) std.Io.Writer.Error!void {
    switch (form) {
        .non_specific => try w.writeByte('!'),
        .verbatim => |uri| try w.print("!<{s}>", .{uri}),
        .shorthand => |s| {
            try w.writeAll(s.handle);
            for (s.suffix) |c| {
                if (isTagChar(c)) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
            }
        },
    }
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
    // A byte order mark may not stand inside a document.
    if (std.mem.indexOf(u8, l, "\u{feff}") != null) return error.InvalidComment;
}

pub const Seq = struct {
    items: std.ArrayList(Value) = .empty,
    /// One entry per item (same length as `items`, an empty `Comments` if none).
    comments: std.ArrayList(Comments) = .empty,
    /// Written as `[a, b]` (only if no item is a block collection).
    flow: bool = false,
    /// As `Scalar.tag` and `Scalar.anchor`.
    tag: ?[]const u8 = null,
    anchor: ?*Anchor = null,

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
        return @truncate(nodeHash(key, 0));
    }

    pub fn eql(_: KeyContext, a: Value, b: Value, _: usize) bool {
        // Keys that are too large to compare count as the same, so that no
        // more of them are compared. The parser reports it as what it is.
        return compareKeys(a, b) != .different;
    }
};

pub const Comparison = enum { same, different, too_large };

/// Compares two keys, following aliases as far as the limits allow.
pub fn compareKeys(a: Value, b: Value) Comparison {
    var work: Work = .{};
    return compare(a, b, &work);
}

/// What one comparison of keys may cost. Aliases let a small text stand for
/// an enormous tree, or for one that never ends, so every step of a comparison
/// draws on the same allowance.
const Work = struct {
    steps: usize = 1 << 16,
    depth: u32 = 0,
};

/// How deep hashing and comparing keys go, through aliases or not.
const max_key_depth = 128;

/// The tag that decides what a scalar is: its own, or the one the core schema
/// gives it.
fn effectiveTag(s: Scalar) []const u8 {
    if (s.tag) |t| {
        if (s.kind == .string and !std.mem.eql(u8, t, "!")) return t;
    }
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

/// Stands for what hashing does not go into.
const unhashed: u64 = 0x9e37_79b9_7f4a_7c15;

/// The hash of a node, or of the node an alias stands for. It does not depend
/// on whether the node has an anchor. An anchored node's is computed once,
/// when it is complete (`sealAnchor`): an alias then costs nothing to hash,
/// however much it stands for, and hashing does not follow chains of aliases.
fn nodeHash(v: Value, depth: u32) u64 {
    if (v == .alias) {
        const a = v.alias;
        // Inside the node it refers to.
        if (!a.complete) return unhashed;
        return a.hash orelse freshHash(a.value, depth);
    }
    if (v.anchorOf()) |a| {
        if (a.hash) |known| return known;
    }
    return freshHash(v, depth);
}

fn freshHash(v: Value, depth: u32) u64 {
    if (depth >= max_key_depth) return unhashed;
    var h = std.hash.Wyhash.init(2);
    hashNode(&h, v, depth);
    return h.final();
}

fn hashPart(h: *std.hash.Wyhash, v: Value, depth: u32) void {
    const part = nodeHash(v, depth + 1);
    h.update(std.mem.asBytes(&part));
}

/// Finishes an anchor whose node has been read whole. Anchors inside the node
/// are finished before it.
pub fn sealAnchor(a: *Anchor, node: Value) void {
    a.value = node;
    a.hash = null;
    a.complete = true;
    a.hash = freshHash(node, 0);
}

fn hashNode(h: *std.hash.Wyhash, v: Value, depth: u32) void {
    switch (v) {
        .alias => unreachable,
        .scalar => |s| {
            var buffer: [64]u8 = undefined;
            hashScalar(h, effectiveTag(s), canonical(s, &buffer));
        },
        .seq => |q| {
            h.update("[");
            for (q.items.items) |item| hashPart(h, item, depth);
        },
        .map => |m| {
            // The order of a mapping's keys is not part of its value.
            var sum: u64 = 0;
            for (m.entries.keys(), m.entries.values()) |k, e| {
                var one = std.hash.Wyhash.init(1);
                hashPart(&one, k, depth);
                hashPart(&one, e.value, depth);
                sum +%= one.final();
            }
            h.update("{");
            h.update(std.mem.asBytes(&sum));
        },
    }
}

fn compare(x: Value, y: Value, work: *Work) Comparison {
    if (x == .alias and y == .alias and x.alias == y.alias) return .same;
    if (work.steps == 0 or work.depth >= max_key_depth) return .too_large;
    work.steps -= 1;
    work.depth += 1;
    defer work.depth -= 1;
    const a = x.deref();
    const b = y.deref();
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return .different;
    switch (a) {
        .alias => unreachable,
        .scalar => |s| {
            if (!std.mem.eql(u8, effectiveTag(s), effectiveTag(b.scalar))) return .different;
            var first: [64]u8 = undefined;
            var second: [64]u8 = undefined;
            return if (std.mem.eql(u8, canonical(s, &first), canonical(b.scalar, &second))) .same else .different;
        },
        .seq => |q| {
            if (q == b.seq) return .same;
            if (!sameTag(q.tag, b.seq.tag) or q.items.items.len != b.seq.items.items.len) return .different;
            for (q.items.items, b.seq.items.items) |i, j| {
                const result = compare(i, j, work);
                if (result != .same) return result;
            }
            return .same;
        },
        .map => |m| {
            if (m == b.map) return .same;
            if (!sameTag(m.tag, b.map.tag) or m.count() != b.map.count()) return .different;
            // Not through the other map's index, whose lookups would each
            // start with a fresh allowance. Equal maps are mostly written in
            // one order, so each search starts at the same position.
            const keys = b.map.entries.keys();
            for (m.entries.keys(), m.entries.values(), 0..) |k, e, i| {
                var j = i;
                const found = for (0..keys.len) |_| {
                    switch (compare(k, keys[j], work)) {
                        .same => break j,
                        .too_large => return .too_large,
                        .different => j = if (j + 1 == keys.len) 0 else j + 1,
                    }
                } else return .different;
                const result = compare(e.value, b.map.entries.values()[found].value, work);
                if (result != .same) return result;
            }
            return .same;
        },
    }
}

/// Whether two collections' tags are the same: no tag and `!` say the same.
fn sameTag(a: ?[]const u8, b: ?[]const u8) bool {
    const x = if (a) |t| if (std.mem.eql(u8, t, "!")) null else t else null;
    const y = if (b) |t| if (std.mem.eql(u8, t, "!")) null else t else null;
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

/// Finds a scalar key written as `text` and typed `kind`.
const TextKey = struct {
    kind: Kind,

    // A key with a tag of its own is found by text only through `find`'s scan.
    pub fn hash(self: TextKey, text: []const u8) u32 {
        const s: Scalar = .{ .text = text, .kind = self.kind };
        return @truncate(freshHash(.{ .scalar = s }, 0));
    }

    pub fn eql(self: TextKey, text: []const u8, key: Value, _: usize) bool {
        const node = key.deref();
        return node == .scalar and node.scalar.kind == self.kind and std.mem.eql(u8, node.scalar.text, text);
    }
};

pub const Map = struct {
    /// Keys to values, in insertion order, so a document written back keeps its
    /// key order. A key is any value; most are scalars. A key that is a
    /// collection must not be changed while it is in the map.
    entries: Entries = .empty,
    /// Written as `{a: 1, b: 2}`.
    flow: bool = false,
    /// As `Scalar.tag` and `Scalar.anchor`.
    tag: ?[]const u8 = null,
    anchor: ?*Anchor = null,
    /// Some key has a tag, which can make it hash differently from its text, so
    /// lookups may need to look at each; `putValue` keeps this up to date.
    odd_keys: bool = false,

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
        if (kind != .string) {
            if (self.entries.getIndexAdapted(text, TextKey{ .kind = kind })) |i| return i;
        }
        // Some keys do not hash as their text suggests.
        if (self.odd_keys) {
            for (self.entries.keys(), 0..) |k, i| {
                const node = k.deref();
                if (node == .scalar and (node.scalar.tag != null or k == .alias) and std.mem.eql(u8, node.scalar.text, text)) return i;
            }
        }
        return null;
    }

    /// The value under `key`, following an alias. `entries` has it as written.
    /// It is the node itself, anchor and all: storing it in a second place
    /// writes the anchor twice. To refer to it there instead, store
    /// `.{ .alias = value.anchorOf().? }`.
    pub fn get(self: *const Map, key: []const u8) ?Value {
        return self.entries.values()[self.find(key) orelse return null].value.deref();
    }

    /// Where the value under `key` is stored, as written: it may be an alias.
    /// The pointer is good until the map next changes.
    pub fn getPtr(self: *Map, key: []const u8) ?*Value {
        return &self.entries.values()[self.find(key) orelse return null].value;
    }

    /// The value under a key of any kind, following an alias.
    pub fn getValue(self: *const Map, key: Value) ?Value {
        return (self.entries.get(key) orelse return null).value.deref();
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
            replaceNode(&self.entries.values()[i].value, v);
        } else try self.putValue(arena, .{ .scalar = .{ .text = key } }, v);
    }

    /// `put` for a key of any kind.
    pub fn putValue(self: *Map, arena: Allocator, key: Value, v: Value) Allocator.Error!void {
        const node = key.deref();
        // The text of an alias key can change after its hash was taken.
        if (node == .scalar and (node.scalar.tag != null or key == .alias)) self.odd_keys = true;
        const gop = try self.entries.getOrPut(arena, key);
        if (gop.found_existing) {
            replaceNode(&gop.value_ptr.value, v);
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
