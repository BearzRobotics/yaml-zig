//! Serializes a `Document` back to YAML.
//!
//! The output is block style with the document's indentation step (learned
//! from the source, 2 by default). Comments are written next to the item they
//! were attached to; blank lines kept with them are written too. Scalars and
//! keys keep their style where that is valid: plain text is written as it was
//! (`7.20`), quoted ones stay quoted, and a flow collection stays flow while
//! it holds no block collection and no comment.
//!
//! The output must read back to the same tree. What cannot (invalid UTF-8,
//! nesting beyond `max_depth`) is an error, found before anything is written.
//!
//! Not kept: folded scalars (`>`) are written as literal (`|`) with the same
//! value, a sequence indented like its key moves in by one step, spacing
//! around `:` is normalized, and `...` is not written.

const std = @import("std");
const Writer = std.Io.Writer;
const model = @import("value.zig");
const Value = model.Value;
const Scalar = model.Scalar;
const Seq = model.Seq;
const Map = model.Map;
const Comments = model.Comments;
const Anchor = model.Anchor;
const Allocator = std.mem.Allocator;

/// What is wrong with a document that cannot be written.
pub const CheckError = error{ InvalidUtf8, NestingTooDeep, InvalidDirective, InvalidTag, InvalidAnchor, BrokenAlias, OutOfMemory };

pub const Error = Writer.Error || CheckError;

pub const Doc = struct {
    root: Value,
    indent: u8,
    explicit_start: bool,
    header: []const []const u8,
    footer: []const []const u8,
    root_comments: Comments = .{},
    start_comment: ?[]const u8 = null,
    directives: []const []const u8 = &.{},
    explicit_end: bool = false,
    max_depth: u32,
    /// For the memory `check` needs while it runs.
    gpa: Allocator,
};

/// Writes one document on its own. Its end needs no marker.
pub fn write(w: *Writer, doc: Doc) Error!void {
    try check(doc);
    var g: Gen = .{ .w = w, .step = @max(doc.indent, 1), .tags = try model.TagTable.init(doc.directives) };
    try g.document(doc, doc.explicit_start or doc.directives.len != 0);
}

/// Checks everything about `doc` that can make writing it fail, other than
/// the output itself. Values and keys can be built by hand, so nothing is
/// written before the whole tree has passed.
pub fn check(doc: Doc) CheckError!void {
    for (doc.directives) |line| _ = model.parseDirective(line) catch return error.InvalidDirective;
    const tags = try model.TagTable.init(doc.directives);
    var checker: Checker = .{ .gpa = doc.gpa, .tags = &tags };
    defer checker.anchors.deinit(doc.gpa);
    try checker.tree(doc.root, doc.max_depth, false);
    try checkComment(.{ .before = doc.header });
    try checkComment(.{ .before = doc.footer });
    try checkComment(doc.root_comments);
    try checkComment(.{ .after = doc.start_comment });
}

/// Writes the next document of a stream; `check` it first. `previous_ended`
/// says whether the one before was closed with `...`, and `next` is the one
/// that follows. Returns whether this one was closed.
pub fn writeInStream(w: *Writer, doc: Doc, index: usize, previous_ended: bool, next: ?Doc) Error!bool {
    var g: Gen = .{ .w = w, .step = @max(doc.indent, 1), .tags = try model.TagTable.init(doc.directives), .drop_blank = index == 0 };
    // Only `---` or `...` keeps two documents apart.
    const start = doc.explicit_start or doc.directives.len != 0 or (index != 0 and !previous_ended);
    try g.document(doc, start);
    // Directives may only follow `...`.
    const end = if (next) |n| doc.explicit_end or n.directives.len != 0 else false;
    if (end) try w.writeAll("...\n");
    return end;
}

fn checkText(s: []const u8) error{InvalidUtf8}!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
}

fn checkComment(c: Comments) error{InvalidUtf8}!void {
    for (c.before) |l| try checkText(l);
    if (c.after) |a| try checkText(a);
}

/// Checks the text of every node, and that the collections nest no deeper
/// than `levels`. The limit also stops at a collection that contains itself.
/// Walks the tree in the order it is written.
const Checker = struct {
    gpa: Allocator,
    tags: *const model.TagTable,
    /// What each anchor name stands for at this point of the output.
    anchors: std.StringHashMapUnmanaged(Definition) = .empty,

    const Definition = struct {
        node: Value,
        /// The walk is still inside the node.
        open: bool,
    };

    fn tree(self: *Checker, v: Value, levels: u32, in_key: bool) CheckError!void {
        if (v == .alias) {
            // It must read back as an alias of the same node.
            const found = self.anchors.get(v.alias.name) orelse return error.BrokenAlias;
            if (!sameNode(found.node, v.alias.value) or (in_key and found.open)) return error.BrokenAlias;
            return;
        }
        if (tagOf(v)) |tag| _ = try self.tags.form(tag);
        const anchor = v.anchorOf();
        if (anchor) |a| {
            if (!model.isAnchorName(a.name)) return error.InvalidAnchor;
            try self.anchors.put(self.gpa, a.name, .{ .node = v, .open = true });
        }
        switch (v) {
            .alias => unreachable,
            .scalar => |s| try checkText(s.text),
            .seq => |q| {
                if (levels == 0) return error.NestingTooDeep;
                for (q.items.items) |item| try self.tree(item, levels - 1, in_key);
                for (q.comments.items) |c| try checkComment(c);
            },
            .map => |m| {
                if (levels == 0) return error.NestingTooDeep;
                for (m.entries.keys(), m.entries.values()) |k, e| {
                    try self.tree(k, levels - 1, true);
                    try self.tree(e.value, levels - 1, in_key);
                    try checkComment(e.comments);
                }
            },
        }
        if (anchor) |a| {
            // The name may have been given again inside the node.
            const found = self.anchors.getPtr(a.name).?;
            if (sameNode(found.node, v)) found.open = false;
        }
    }

    /// The same collection, or scalars that read the same.
    fn sameNode(a: Value, b: Value) bool {
        return switch (a) {
            .scalar => |s| b == .scalar and s.kind == b.scalar.kind and std.mem.eql(u8, s.text, b.scalar.text) and
                std.mem.eql(u8, s.tag orelse "", b.scalar.tag orelse ""),
            .seq => |q| b == .seq and q == b.seq,
            .map => |m| b == .map and m == b.map,
            .alias => false,
        };
    }
};

fn tagOf(v: Value) ?[]const u8 {
    return switch (v) {
        .scalar => |s| s.tag,
        .seq => |q| q.tag,
        .map => |m| m.tag,
        .alias => null,
    };
}

fn hasProps(v: Value) bool {
    return tagOf(v) != null or v.anchorOf() != null;
}

/// A key that cannot stand before a `:` on its line: a block collection, a
/// block scalar, or one longer than the 1024 characters YAML allows there.
fn needsExplicitKey(k: Value) bool {
    return switch (k) {
        .alias => false,
        .scalar => |s| s.style == .literal or s.style == .folded or s.text.len > 1000,
        .seq, .map => !isInline(k),
    };
}

/// A plain null written as nothing at all.
fn isBare(s: Scalar) bool {
    return s.style == .plain and s.text.len == 0 and (s.tag != null or s.kind == .null);
}

/// Whether `v` is written on one line: a scalar, an empty collection, or a
/// flow collection that can still be written as one without loss. It cannot
/// if it holds a block collection or a comment.
fn isInline(v: Value) bool {
    switch (v) {
        .scalar, .alias => return true,
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
            for (m.entries.keys(), m.entries.values()) |k, e| {
                if (!isInline(k) or !isInline(e.value) or !e.comments.isEmpty()) return false;
            }
            return true;
        },
    }
}

const Gen = struct {
    w: *Writer,
    step: usize,
    /// The document's tag handles, which tag shorthands depend on.
    tags: model.TagTable,
    /// Set where empty comment lines must be left out: at the start of the
    /// output (the reader drops them, so a second write would differ) and
    /// after a block scalar with keep chomping (they would join its value).
    drop_blank: bool = true,
    /// The last comment line written was empty. The reader keeps one of a run.
    blank_written: bool = false,

    fn document(self: *Gen, doc: Doc, start: bool) Error!void {
        try self.lines(doc.header, 0);
        for (doc.directives) |line| {
            try self.w.writeAll(line);
            try self.w.writeByte('\n');
        }
        const after = doc.root_comments.after;
        // A block collection's tag can share the `---` line, if no comment
        // has to come between.
        const props_on_marker = start and !isInline(doc.root) and hasProps(doc.root) and
            doc.start_comment == null and doc.root_comments.before.len == 0 and after == null;
        if (start) {
            try self.w.writeAll("---");
            if (props_on_marker) try self.spacedProps(doc.root);
            try self.tail(doc.start_comment);
        }
        try self.lines(doc.root_comments.before, 0);
        if (isInline(doc.root)) try self.rootInline(doc.root, after) else {
            // A block collection has no line of its own for a trailing comment.
            if (after) |a| try self.lines(&.{a}, 0);
            if (!props_on_marker and hasProps(doc.root)) {
                try self.pad(0);
                try self.props(doc.root);
                try self.w.writeByte('\n');
                // The reader drops empty lines above a document's first item.
                self.drop_blank = true;
            }
            switch (doc.root) {
                .map => |m| try self.map(m, 0, false),
                .seq => |q| try self.seq(q, 0),
                .scalar, .alias => unreachable,
            }
        }
        try self.lines(doc.footer, 0);
    }

    /// Starts a line that is not empty.
    fn pad(self: *Gen, n: usize) Error!void {
        self.drop_blank = false;
        self.blank_written = false;
        try self.w.splatByteAll(' ', n);
    }

    fn lines(self: *Gen, ls: []const []const u8, indent: usize) Error!void {
        for (ls) |line| {
            // The item's indent is the only one written. Leading blanks from
            // setComments could place the line inside a block scalar above, or
            // put a tab where an indent belongs.
            const l = std.mem.trimStart(u8, line, " \t");
            if (l.len == 0 and (self.drop_blank or self.blank_written)) continue;
            if (l.len != 0) try self.pad(indent) else self.blank_written = true;
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
                if (hasProps(v)) {
                    try self.props(v);
                    if (!isBare(s)) try self.w.writeByte(' ');
                }
                if (isBlock(s) and blockOk(s.text)) return self.blockScalar(s, 0, after, true);
                if (isBare(s)) {
                    // Spelled out, so that the document is not empty.
                    if (!hasProps(v)) try self.w.writeAll("null");
                } else if (s.style == .plain and !hasProps(v) and looksLikeMarker(s.text))
                    try self.double(s.text)
                else
                    try self.scalarText(s, false);
            },
            else => try self.flow(v),
        }
        try self.tail(after);
    }

    /// `&anchor !tag`, whichever of them the node has.
    fn props(self: *Gen, v: Value) Error!void {
        if (v.anchorOf()) |a| {
            try self.w.writeByte('&');
            try self.w.writeAll(a.name);
        }
        if (tagOf(v)) |tag| {
            if (v.anchorOf() != null) try self.w.writeByte(' ');
            // `check` has made sure there is a form.
            try model.writeTag(self.w, self.tags.form(tag) catch return error.InvalidTag);
        }
    }

    /// ` &anchor !tag` for a node that has either.
    fn spacedProps(self: *Gen, v: Value) Error!void {
        if (hasProps(v)) {
            try self.w.writeByte(' ');
            try self.props(v);
        }
    }

    fn aliasText(self: *Gen, a: *const Anchor) Error!void {
        try self.w.writeByte('*');
        try self.w.writeAll(a.name);
    }

    // ---- block collections ----------------------------------------------------

    fn map(self: *Gen, m: *const Map, indent: usize, first_inline: bool) Error!void {
        for (m.entries.keys(), m.entries.values(), 0..) |k, e, idx| {
            const c = e.comments;
            if (!(first_inline and idx == 0)) {
                try self.lines(c.before, indent);
                try self.pad(indent);
            }
            if (needsExplicitKey(k)) {
                try self.w.writeByte('?');
                try self.entryValue(k, null, indent);
                try self.pad(indent);
            } else try self.key(k, indent == 0, false);
            try self.w.writeByte(':');
            try self.entryValue(e.value, c.after, indent);
        }
    }

    fn seq(self: *Gen, q: *const Seq, indent: usize) Error!void {
        for (q.items.items, q.comments.items) |item, c| {
            try self.lines(c.before, indent);
            switch (item) {
                // A comment or tag on the dash's line needs the dash on a line
                // of its own; the mapping then follows in block form below.
                .map => if (!isInline(item) and c.after == null and !hasProps(item)) {
                    const m = item.map;
                    // Comments above the first key sit above the dash.
                    const first = m.entries.values()[0].comments;
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
            try self.entryValue(item, c.after, indent);
        }
    }

    /// The value after `key:`.
    fn entryValue(self: *Gen, v: Value, after: ?[]const u8, indent: usize) Error!void {
        switch (v) {
            .alias => |a| {
                try self.w.writeByte(' ');
                try self.aliasText(a);
                try self.tail(after);
            },
            .scalar => |s| {
                try self.spacedProps(v);
                if (isBlock(s) and blockOk(s.text)) {
                    try self.w.writeByte(' ');
                    return self.blockScalar(s, indent, after, false);
                }
                if (isBare(s)) return self.tail(after);
                try self.w.writeByte(' ');
                try self.scalarText(s, false);
                try self.tail(after);
            },
            .seq, .map => {
                if (isInline(v)) {
                    try self.w.writeByte(' ');
                    try self.flow(v);
                    return self.tail(after);
                }
                try self.spacedProps(v);
                try self.tail(after);
                switch (v) {
                    .seq => |q| try self.seq(q, indent + self.step),
                    .map => |m| try self.map(m, indent + self.step, false),
                    .scalar, .alias => unreachable,
                }
            },
        }
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
        self.drop_blank = keep;
    }

    /// A scalar key. A key added through the API is a string, so `plainOk`
    /// has it quoted if plain text would read as another type.
    fn key(self: *Gen, v: Value, at_column_0: bool, in_flow: bool) Error!void {
        const k = switch (v) {
            .alias => |a| {
                try self.aliasText(a);
                // A `:` may be part of a name, so it must not touch one.
                return self.w.writeByte(' ');
            },
            .scalar => |s| s,
            // Short enough for one line, or `needsExplicitKey` would say so.
            .seq, .map => return self.flow(v),
        };
        if (hasProps(v)) {
            try self.props(v);
            // A blank keeps a tag or anchor clear of the colon.
            if (isBare(k)) return self.w.writeByte(' ');
            try self.w.writeByte(' ');
        }
        // `: value`, an empty plain key.
        if (isBare(k)) return;
        if (at_column_0 and k.style == .plain and !hasProps(v) and looksLikeMarker(k.text)) return self.double(k.text);
        try self.scalarText(k, in_flow);
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
        if (model.kindOf(s.tag, .plain, s.text) != s.kind) return false;
        if (!indicatorOk(s.text)) return false;
        if (!plainBody(s.text)) return false;
        if (in_flow and std.mem.findAny(u8, s.text, ",[]{}") != null) return false;
        return true;
    }

    /// A scalar's content on one line, without its tag.
    fn scalarText(self: *Gen, s: Scalar, in_flow: bool) Error!void {
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
        if (v == .seq or v == .map) {
            if (hasProps(v)) {
                try self.props(v);
                try self.w.writeByte(' ');
            }
        }
        switch (v) {
            .alias => |a| try self.aliasText(a),
            .scalar => |s| {
                if (hasProps(v)) {
                    try self.props(v);
                    try self.w.writeByte(' ');
                    if (isBare(s)) return;
                } else if (isBare(s)) return self.w.writeAll("null");
                try self.scalarText(s, true);
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
                for (m.entries.keys(), m.entries.values(), 0..) |k, e, i| {
                    if (i != 0) try self.w.writeAll(", ");
                    try self.key(k, false, true);
                    try self.w.writeAll(": ");
                    try self.flow(e.value);
                }
                try self.w.writeByte('}');
            },
        }
    }
};
