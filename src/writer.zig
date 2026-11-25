//! Serializes a `Document` back to YAML.
//!
//! The output is block style with the document's indentation step (learned
//! from the source, 2 by default). Comments are written next to the item they
//! were attached to; blank lines kept with them are written too. Scalars keep
//! their style where that is valid: plain text is written as it was (`7.20`),
//! quoted ones stay quoted, and a flow collection stays flow while it holds
//! only scalars and flow collections.
//!
//! Not kept: folded scalars (`>`) are written as literal (`|`) with the same
//! value, a sequence indented like its key moves in by one step, a comment
//! inside a flow collection is dropped, and spacing around `:` is normalized.

const std = @import("std");
const Writer = std.Io.Writer;
const model = @import("value.zig");
const Value = model.Value;
const Scalar = model.Scalar;
const Seq = model.Seq;
const Map = model.Map;
const Comments = model.Comments;

pub const Error = Writer.Error || error{InvalidUtf8};

pub const Doc = struct {
    root: Value,
    indent: u8,
    explicit_start: bool,
    header: []const []const u8,
    footer: []const []const u8,
    root_comments: Comments = .{},
    start_comment: ?[]const u8 = null,
};

pub fn write(w: *Writer, doc: Doc) Error!void {
    // Values and keys can be built by hand, so the whole tree is checked
    // before anything is written.
    try checkUtf8(doc.root);
    try checkComment(.{ .before = doc.header });
    try checkComment(.{ .before = doc.footer });
    try checkComment(doc.root_comments);
    try checkComment(.{ .after = doc.start_comment });
    var g: Gen = .{ .w = w, .step = @max(doc.indent, 1) };
    try g.lines(doc.header, 0);
    if (doc.explicit_start) {
        try w.writeAll("---");
        try g.tail(doc.start_comment);
    }
    try g.lines(doc.root_comments.before, 0);
    const after = doc.root_comments.after;
    if (isInline(doc.root)) try g.rootInline(doc.root, after) else {
        // A block collection has no line of its own for a trailing comment.
        if (after) |a| try g.lines(&.{a}, 0);
        switch (doc.root) {
            .map => |m| try g.map(m, 0, false),
            .seq => |q| try g.seq(q, 0),
            .scalar => unreachable,
        }
    }
    try g.lines(doc.footer, 0);
}

fn checkText(s: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
}

fn checkComment(c: Comments) error{InvalidUtf8}!void {
    for (c.before) |l| try checkText(l);
    if (c.after) |a| try checkText(a);
}

fn checkUtf8(v: Value) error{InvalidUtf8}!void {
    switch (v) {
        .scalar => |s| try checkText(s.text),
        .seq => |q| {
            for (q.items.items) |item| try checkUtf8(item);
            for (q.comments.items) |c| try checkComment(c);
        },
        .map => |m| {
            for (m.entries.keys(), m.entries.values()) |k, item| {
                try checkText(k);
                try checkUtf8(item);
            }
            for (m.comments.values()) |c| try checkComment(c);
        },
    }
}

/// Whether `v` is written on one line: a scalar, an empty collection, or a
/// flow collection that can still be written as one without loss. It cannot
/// if it holds a block collection or a comment.
fn isInline(v: Value) bool {
    switch (v) {
        .scalar => return true,
        .seq => |q| {
            if (q.items.items.len == 0) return true;
            if (!q.flow) return false;
            for (q.items.items) |item| if (!isInline(item)) return false;
            for (q.comments.items) |c| if (!c.isEmpty()) return false;
            return true;
        },
        .map => |m| {
            if (m.count() == 0) return true;
            if (!m.flow) return false;
            for (m.entries.values()) |item| if (!isInline(item)) return false;
            return m.comments.count() == 0;
        },
    }
}

const Gen = struct {
    w: *Writer,
    step: usize,
    /// Set after a block scalar with keep chomping: empty lines written now
    /// would become part of its value.
    after_keep: bool = false,

    /// Starts a line that is not empty.
    fn pad(self: *Gen, n: usize) Error!void {
        self.after_keep = false;
        try self.w.splatByteAll(' ', n);
    }

    fn lines(self: *Gen, ls: []const []const u8, indent: usize) Error!void {
        for (ls) |l| {
            if (l.len == 0 and self.after_keep) continue;
            if (l.len != 0) try self.pad(indent);
            try self.w.writeAll(l);
            try self.w.writeByte('\n');
        }
    }

    /// ` # comment` and the newline.
    fn tail(self: *Gen, after: ?[]const u8) Error!void {
        if (after) |a| {
            try self.w.writeByte(' ');
            try self.w.writeAll(a);
        }
        try self.w.writeByte('\n');
    }

    fn rootInline(self: *Gen, v: Value, after: ?[]const u8) Error!void {
        switch (v) {
            .scalar => |s| {
                if (isBlock(s) and blockOk(s.text)) return self.blockScalar(s, 0, after, true);
                if (s.kind == .null and s.text.len == 0)
                    try self.w.writeAll("null")
                else if (s.style == .plain and looksLikeMarker(s.text))
                    try self.double(s.text)
                else
                    try self.scalarInline(s, false);
            },
            else => try self.flow(v),
        }
        try self.tail(after);
    }

    // ---- block collections ----------------------------------------------------

    fn map(self: *Gen, m: *const Map, indent: usize, first_inline: bool) Error!void {
        for (m.entries.keys(), m.entries.values(), 0..) |k, v, idx| {
            const c = m.comments.get(k) orelse Comments{};
            if (!(first_inline and idx == 0)) {
                try self.lines(c.before, indent);
                try self.pad(indent);
            }
            try self.key(m, k, indent == 0, false);
            try self.w.writeByte(':');
            try self.entryValue(v, c.after, indent);
        }
    }

    fn seq(self: *Gen, q: *const Seq, indent: usize) Error!void {
        for (q.items.items, q.comments.items) |item, c| {
            try self.lines(c.before, indent);
            switch (item) {
                // A comment on the dash's line needs the dash on a line of
                // its own; the mapping then follows in block form below.
                .map => |m| if (!isInline(item) and c.after == null) {
                    // Comments above the first key sit above the dash.
                    const first = m.comments.get(m.entries.keys()[0]) orelse Comments{};
                    try self.lines(first.before, indent);
                    try self.pad(indent);
                    try self.w.writeAll("- ");
                    try self.map(m, indent + 2, true);
                    continue;
                },
                else => {},
            }
            try self.pad(indent);
            try self.w.writeByte('-');
            try self.itemValue(item, c.after, indent);
        }
    }

    /// The value after `key:`.
    fn entryValue(self: *Gen, v: Value, after: ?[]const u8, indent: usize) Error!void {
        switch (v) {
            .scalar => |s| {
                if (isBlock(s) and blockOk(s.text)) {
                    try self.w.writeByte(' ');
                    return self.blockScalar(s, indent, after, false);
                }
                if (s.kind == .null and s.text.len == 0 and s.style == .plain) return self.tail(after);
                try self.w.writeByte(' ');
                try self.scalarInline(s, false);
                try self.tail(after);
            },
            .seq, .map => {
                if (isInline(v)) {
                    try self.w.writeByte(' ');
                    try self.flow(v);
                    return self.tail(after);
                }
                try self.tail(after);
                switch (v) {
                    .seq => |q| try self.seq(q, indent + self.step),
                    .map => |m| try self.map(m, indent + self.step, false),
                    .scalar => unreachable,
                }
            },
        }
    }

    /// The value after `-` (a mapping that is written on the dash's line is handled by `seq`).
    fn itemValue(self: *Gen, v: Value, after: ?[]const u8, indent: usize) Error!void {
        switch (v) {
            .seq => |q| if (!isInline(v)) {
                try self.tail(after);
                return self.seq(q, indent + self.step);
            },
            else => {},
        }
        try self.entryValue(v, after, indent);
    }

    // ---- scalars ---------------------------------------------------------------

    /// Written at column 0, such text would be read as `---` or `...`.
    fn looksLikeMarker(s: []const u8) bool {
        if (!std.mem.startsWith(u8, s, "---") and !std.mem.startsWith(u8, s, "...")) return false;
        return s.len == 3 or s[3] == ' ' or s[3] == '\t';
    }

    fn isBlock(s: Scalar) bool {
        return s.style == .literal or s.style == .folded;
    }

    /// A block scalar holds text without control characters (apart from tab and newline).
    fn blockOk(text: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(text)) return false;
        var lines_of = std.mem.splitScalar(u8, text, '\n');
        while (lines_of.next()) |l| if (model.findNonPrintable(l) != null) return false;
        return true;
    }

    /// `|` header (after a space the caller wrote), the comment, and the body
    /// indented one step past `indent`.
    fn blockScalar(self: *Gen, s: Scalar, indent: usize, after: ?[]const u8, is_root: bool) Error!void {
        const text = s.text;
        var nl: usize = 0;
        while (nl < text.len and text[text.len - 1 - nl] == '\n') nl += 1;
        const body = text[0 .. text.len - nl];
        // Keep chomping: more than one final newline, or nothing but newlines.
        const keep = nl > 1 or (body.len == 0 and nl == 1);
        // The reader takes the indentation from the first line that is not
        // empty, so it must be spelled out if that line starts with a space.
        // An empty root block needs it too: otherwise a comment after it, at
        // column 0, would be read as its content.
        var first = body;
        while (first.len != 0 and first[0] == '\n') first = first[1..];
        const indicator = (first.len != 0 and first[0] == ' ') or (is_root and body.len == 0);
        // The indicator is a single digit.
        const step = if (indicator) @min(self.step, 9) else self.step;
        try self.w.writeByte('|');
        if (indicator) try self.w.writeByte('0' + @as(u8, @intCast(step)));
        // Clip (exactly one final newline) needs no marker.
        if (keep) try self.w.writeByte('+') else if (nl == 0) try self.w.writeByte('-');
        try self.tail(after);
        if (body.len != 0) {
            var it = std.mem.splitScalar(u8, body, '\n');
            while (it.next()) |l| {
                if (l.len != 0) try self.pad(indent + step);
                try self.w.writeAll(l);
                try self.w.writeByte('\n');
            }
        }
        // With keep chomping each further newline is an empty line.
        if (keep) try self.w.splatByteAll('\n', if (body.len != 0) nl - 1 else nl);
        self.after_keep = keep;
    }

    fn key(self: *Gen, m: *const Map, k: []const u8, at_column_0: bool, in_flow: bool) Error!void {
        const noted = m.key_styles.get(k);
        switch (noted orelse .plain) {
            .plain => {
                // A key added through the API is a string, so it is quoted if
                // a plain one would read as another type.
                const typed = model.resolve(k) != .string;
                // `: value`, an empty plain key.
                if (noted != null and k.len == 0) return;
                if ((noted != null or !typed) and keyOk(k, in_flow) and !(at_column_0 and looksLikeMarker(k)))
                    return self.w.writeAll(k);
                try self.double(k);
            },
            .single => try self.scalarInline(.{ .text = k, .style = .single }, in_flow),
            else => try self.double(k),
        }
    }

    fn keyOk(k: []const u8, in_flow: bool) bool {
        if (k.len == 0 or !indicatorOk(k) or !plainBody(k)) return false;
        return !in_flow or std.mem.findAny(u8, k, ",[]{}") == null;
    }

    /// A plain scalar cannot start with an indicator, except for `-`, `?` and
    /// `:` before a character that is not a blank (`-foo`).
    fn indicatorOk(s: []const u8) bool {
        if (std.mem.findScalar(u8, "-?:,[]{}#&*!|>'\"%@`", s[0]) == null) return true;
        return (s[0] == '-' or s[0] == '?' or s[0] == ':') and s.len > 1 and s[1] != ' ';
    }

    /// Characters and sequences that cannot appear in a plain scalar.
    fn plainBody(s: []const u8) bool {
        if (s[0] == ' ' or s[s.len - 1] == ' ' or s[s.len - 1] == ':') return false;
        if (model.findNonPrintable(s) != null) return false;
        for (s, 0..) |c, i| {
            if (c == '\t') return false;
            if (c == ':' and i + 1 < s.len and s[i + 1] == ' ') return false;
            if (c == '#' and i > 0 and s[i - 1] == ' ') return false;
        }
        return std.unicode.utf8ValidateSlice(s) and std.mem.indexOf(u8, s, "\u{85}") == null and
            std.mem.indexOf(u8, s, "\u{2028}") == null and std.mem.indexOf(u8, s, "\u{2029}") == null and
            std.mem.indexOf(u8, s, "\u{feff}") == null;
    }

    fn plainOk(s: Scalar, in_flow: bool) bool {
        if (s.text.len == 0) return false;
        if (model.resolve(s.text) != s.kind) return false;
        if (!indicatorOk(s.text)) return false;
        if (!plainBody(s.text)) return false;
        if (in_flow and std.mem.findAny(u8, s.text, ",[]{}") != null) return false;
        return true;
    }

    fn scalarInline(self: *Gen, s: Scalar, in_flow: bool) Error!void {
        switch (s.style) {
            .plain => {
                if (plainOk(s, in_flow)) return self.w.writeAll(s.text);
                if (s.kind == .null and s.text.len == 0) return self.w.writeAll("null");
                try self.double(s.text);
            },
            .single => {
                if (model.findNonPrintable(s.text) != null or std.mem.indexOfScalar(u8, s.text, '\t') != null) return self.double(s.text);
                try self.w.writeByte('\'');
                for (s.text) |c| {
                    if (c == '\'') try self.w.writeByte('\'');
                    try self.w.writeByte(c);
                }
                try self.w.writeByte('\'');
            },
            .double, .literal, .folded => try self.double(s.text),
        }
    }

    fn double(self: *Gen, t: []const u8) Error!void {
        const w = self.w;
        try w.writeByte('"');
        var i: usize = 0;
        while (i < t.len) {
            const c = t[i];
            const rest = t[i..];
            if (std.mem.startsWith(u8, rest, "\u{85}")) {
                try w.writeAll("\\N");
                i += 2;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "\u{2028}")) {
                try w.writeAll("\\L");
                i += 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "\u{2029}")) {
                try w.writeAll("\\P");
                i += 3;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "\u{feff}")) {
                try w.writeAll("\\uFEFF");
                i += 3;
                continue;
            }
            if (model.nonPrintableAt(t, i)) |np| {
                switch (c) {
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    else => if (np.codepoint <= 0xFF)
                        try w.print("\\x{X:0>2}", .{np.codepoint})
                    else
                        try w.print("\\u{X:0>4}", .{np.codepoint}),
                }
                i += np.len;
                continue;
            }
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            }
            i += 1;
        }
        try w.writeByte('"');
    }

    // ---- flow ------------------------------------------------------------------------

    fn flow(self: *Gen, v: Value) Error!void {
        switch (v) {
            .scalar => |s| {
                if (s.kind == .null and s.text.len == 0 and s.style == .plain) return self.w.writeAll("null");
                try self.scalarInline(s, true);
            },
            .seq => |q| {
                try self.w.writeByte('[');
                for (q.items.items, 0..) |item, i| {
                    if (i != 0) try self.w.writeAll(", ");
                    try self.flow(item);
                }
                try self.w.writeByte(']');
            },
            .map => |m| {
                try self.w.writeByte('{');
                for (m.entries.keys(), m.entries.values(), 0..) |k, item, i| {
                    if (i != 0) try self.w.writeAll(", ");
                    try self.key(m, k, false, true);
                    try self.w.writeAll(": ");
                    try self.flow(item);
                }
                try self.w.writeByte('}');
            },
        }
    }
};
