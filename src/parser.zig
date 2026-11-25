//! YAML reader: the block and flow styles of YAML 1.2 that configuration and
//! recipe files use, with comments kept.
//!
//! Supported: block mappings and sequences (any indentation, a sequence may
//! sit at its key's column), plain / single-quoted / double-quoted scalars
//! (also over several lines), literal and folded block scalars with chomping
//! and indentation indicators, flow sequences and mappings, an optional
//! leading `---` and trailing `...`, and `#` comments. Plain scalars are
//! typed by the core schema (`Scalar.kind`) but keep their text.
//!
//! Not supported, and reported as `error.Unsupported` rather than misread:
//! anchors, aliases, tags, directives, complex keys (`? `), several documents
//! in one stream.
//!
//! The input is split into lines, which are walked by indentation. Comment
//! and blank lines collect in `pending` and become the `before` of the next
//! item; a comment after an item on its line becomes its `after`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("value.zig");
const Value = model.Value;
const Scalar = model.Scalar;
const Seq = model.Seq;
const Map = model.Map;
const Comments = model.Comments;

pub const Error = error{
    /// Malformed YAML, or a construct YAML forbids (duplicate key, bad indentation).
    Syntax,
    /// Valid YAML this library does not read: anchors, aliases, tags, complex keys, several documents.
    Unsupported,
    InvalidUtf8,
    /// Nesting, line count or input size exceeded `Options` limits.
    LimitExceeded,
    OutOfMemory,
};

pub const Options = struct {
    /// Maximum nesting of collections. Bounds recursion depth.
    max_depth: u32 = 64,
    /// Maximum input size in bytes.
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    /// Static string; valid for the program's lifetime.
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
    }
};

/// What `parse` fills in besides the root value.
pub const Result = struct {
    root: Value,
    indent: u8,
    explicit_start: bool,
    header: []const []const u8,
    footer: []const []const u8,
};

const null_scalar: Value = .{ .scalar = .{ .text = "", .style = .plain, .kind = .null } };

pub fn parse(gpa: Allocator, arena: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) Error!Result {
    if (source.len > options.max_bytes) return failAt(diag, 1, 1, "input too large", error.LimitExceeded);
    if (!std.unicode.utf8ValidateSlice(source)) return failAt(diag, 1, 1, "invalid UTF-8", error.InvalidUtf8);
    var text = source;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        try lines.append(gpa, std.mem.trimEnd(u8, l, "\r"));
    }

    var p: Parser = .{ .a = arena, .gpa = gpa, .lines = lines.items, .options = options, .diag = diag };
    defer p.pending.deinit(gpa);
    return p.document();
}

fn failAt(diag: ?*Diagnostic, line: usize, col: usize, msg: []const u8, err: Error) Error {
    if (diag) |d| d.* = .{ .line = line, .column = col, .message = msg };
    return err;
}

const Cur = struct {
    indent: usize,
    /// The line after its indent, without a trailing comment, right-trimmed.
    content: []const u8,
};

const Parser = struct {
    a: Allocator,
    gpa: Allocator,
    lines: [][]const u8,
    pos: usize = 0,
    options: Options,
    diag: ?*Diagnostic,
    pending: std.ArrayList([]const u8) = .empty,
    trailing: ?[]const u8 = null,
    seen_item: bool = false,
    depth: u32 = 0,
    step: u8 = 0,

    fn err(self: *Parser, msg: []const u8) Error {
        const line = @min(self.pos + 1, self.lines.len);
        return failAt(self.diag, line, 1, msg, error.Syntax);
    }

    fn unsupported(self: *Parser, msg: []const u8) Error {
        return failAt(self.diag, @min(self.pos + 1, self.lines.len), 1, msg, error.Unsupported);
    }

    // ---- lines ---------------------------------------------------------------

    fn isWhite(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isBlank(l: []const u8) bool {
        return std.mem.trim(u8, l, " \t").len == 0;
    }

    fn indentOf(l: []const u8) usize {
        var i: usize = 0;
        while (i < l.len and l[i] == ' ') i += 1;
        return i;
    }

    /// Advances over blank and comment lines, collecting them in `pending`.
    /// Runs of blank lines collapse to one; blank lines before the first item are dropped.
    fn skipBlank(self: *Parser) Error!void {
        while (self.pos < self.lines.len) : (self.pos += 1) {
            const l = self.lines[self.pos];
            if (isBlank(l)) {
                const n = self.pending.items.len;
                if (n == 0 and !self.seen_item) continue;
                if (n != 0 and self.pending.items[n - 1].len == 0) continue;
                try self.pending.append(self.gpa, "");
            } else if (l[indentOf(l)] == '#') {
                try self.pending.append(self.gpa, try self.a.dupe(u8, std.mem.trimEnd(u8, l[indentOf(l)..], " \t")));
            } else break;
        }
    }

    /// The current (non-blank, non-comment) line; call `skipBlank` first.
    fn cur(self: *Parser) Error!?Cur {
        if (self.pos >= self.lines.len) return null;
        const l = self.lines[self.pos];
        const ind = indentOf(l);
        if (ind < l.len and l[ind] == '\t') return self.err("a tab cannot indent a line");
        const sc = splitComment(l[ind..]);
        return .{ .indent = ind, .content = std.mem.trimEnd(u8, sc.content, " \t") };
    }

    fn takeBefore(self: *Parser) Error![]const []const u8 {
        defer {
            self.pending.clearRetainingCapacity();
            self.seen_item = true;
        }
        if (self.pending.items.len == 0) return &.{};
        return self.a.dupe([]const u8, self.pending.items);
    }

    fn takeTrailing(self: *Parser) ?[]const u8 {
        defer self.trailing = null;
        return self.trailing;
    }

    // ---- document ----------------------------------------------------------------

    fn document(self: *Parser) Error!Result {
        var res: Result = .{ .root = null_scalar, .indent = 2, .explicit_start = false, .header = &.{}, .footer = &.{} };
        try self.skipBlank();
        // Content that shares its line with `---`.
        var inline_root: ?[]const u8 = null;
        if (try self.cur()) |c| {
            if (isDocMarker(c) and c.content[0] == '-') {
                res.explicit_start = true;
                if (self.pending.items.len != 0) res.header = try self.a.dupe([]const u8, self.pending.items);
                self.pending.clearRetainingCapacity();
                const rest = std.mem.trimStart(u8, self.lines[self.pos][3..], " \t");
                if (rest.len == 0 or rest[0] == '#') self.pos += 1 else inline_root = rest;
            } else if (c.indent == 0 and c.content[0] == '%') return self.unsupported("directives are not supported");
        }
        if (inline_root) |rest| {
            const content = std.mem.trimEnd(u8, splitComment(rest).content, " \t");
            if (isSeqEntry(content) or try self.splitKey(content) != null)
                return self.err("a block collection cannot start on the '---' line");
            res.root = try self.scalarAt(rest, -1);
        } else res.root = try self.block(-1);
        try self.skipBlank();
        if (try self.cur()) |c| {
            if (!isDocMarker(c)) return self.err("unexpected content or bad indentation");
            if (c.content[0] == '-') return self.unsupported("several documents are not supported");
            // `...` ends the document. It may be repeated.
            while (try self.cur()) |end| {
                if (!isDocMarker(end) or end.content[0] != '.') return self.unsupported("several documents are not supported");
                if (end.content.len != 3) return self.err("unexpected content after '...'");
                self.pos += 1;
                try self.skipBlank();
            }
        }
        var n = self.pending.items.len;
        while (n > 0 and self.pending.items[n - 1].len == 0) n -= 1;
        if (n != 0) res.footer = try self.a.dupe([]const u8, self.pending.items[0..n]);
        if (self.step != 0) res.indent = self.step;
        return res;
    }

    fn enter(self: *Parser) Error!void {
        if (self.depth >= self.options.max_depth) return self.fail("nesting too deep", error.LimitExceeded);
        self.depth += 1;
    }

    fn fail(self: *Parser, msg: []const u8, e: Error) Error {
        return failAt(self.diag, @min(self.pos + 1, self.lines.len), 1, msg, e);
    }

    /// A node nested deeper than `parent` (an indent, or -1 at the top).
    fn block(self: *Parser, parent: i64) Error!Value {
        try self.skipBlank();
        const c = (try self.cur()) orelse return null_scalar;
        if (@as(i64, @intCast(c.indent)) <= parent) return null_scalar;
        if (isDocMarker(c)) return null_scalar;
        const is_seq = isSeqEntry(c.content);
        if (is_seq or try self.splitKey(c.content) != null) {
            try self.enter();
            defer self.depth -= 1;
            return if (is_seq) self.sequence(c.indent) else self.mapping(c.indent);
        }
        return self.scalarAt(self.lines[self.pos][c.indent..], parent);
    }

    // ---- sequences -----------------------------------------------------------------

    /// `---` or `...` at the start of a line ends or starts a document.
    fn isDocMarker(c: Cur) bool {
        return c.indent == 0 and isForbidden(c.content);
    }

    fn isSeqEntry(content: []const u8) bool {
        return content.len != 0 and content[0] == '-' and (content.len == 1 or content[1] == ' ');
    }

    fn sequence(self: *Parser, indent: usize) Error!Value {
        const seq = try self.a.create(Seq);
        seq.* = .{};
        while (true) {
            try self.skipBlank();
            const c = (try self.cur()) orelse break;
            if (c.indent < indent or isDocMarker(c)) break;
            if (c.indent > indent) return self.err("bad indentation of a sequence entry");
            if (!isSeqEntry(c.content)) break;
            const before = try self.takeBefore();
            const raw = self.lines[self.pos];
            var j = indent + 1;
            while (j < raw.len and raw[j] == ' ') j += 1;
            const rest = raw[j..];
            var item: Value = undefined;
            var after: ?[]const u8 = null;
            const sc = splitComment(rest);
            if (std.mem.trim(u8, sc.content, " \t").len == 0) {
                after = if (sc.comment) |t| try self.a.dupe(u8, t) else null;
                self.pos += 1;
                try self.skipBlank();
                if (try self.cur()) |nx| {
                    if (self.step == 0 and nx.indent > indent and nx.indent - indent <= 8) self.step = @intCast(nx.indent - indent);
                }
                item = try self.block(@intCast(indent));
            } else {
                // The entry's content starts on the dash's line: parse it as a
                // line of its own, indented to where it starts.
                const synth = try self.a.alloc(u8, j + rest.len);
                @memset(synth[0..j], ' ');
                @memcpy(synth[j..], rest);
                self.lines[self.pos] = synth;
                item = try self.block(@intCast(indent));
                after = self.takeTrailing();
            }
            try seq.items.append(self.a, item);
            try seq.comments.append(self.a, .{ .before = before, .after = after });
        }
        return .{ .seq = seq };
    }

    // ---- mappings --------------------------------------------------------------------

    const KeyInfo = struct { key: []const u8, rest: usize };

    /// If `content` (a line without its indent or comment) starts `key:`, the
    /// decoded key and the offset just after the colon.
    fn splitKey(self: *Parser, content: []const u8) Error!?KeyInfo {
        if (content.len == 0) return null;
        const c0 = content[0];
        switch (c0) {
            // Not simple keys: `scalarAt` deals with them.
            '[', '{', '|', '>' => return null,
            // A line that starts like this is refused whether or not it has a key.
            '&', '*', '!' => return self.unsupported("anchors, aliases and tags are not supported"),
            '@', '`' => return self.err("a reserved indicator cannot start a scalar"),
            '%' => return self.err("a '%' cannot start a plain scalar"),
            '?' => if (content.len == 1 or isWhite(content[1])) return self.unsupported("complex keys are not supported"),
            else => {},
        }
        if (c0 == '"' or c0 == '\'') {
            const end = scanQuoted(content) orelse return null;
            var k = end;
            while (k < content.len and isWhite(content[k])) k += 1;
            if (k < content.len and content[k] == ':' and (k + 1 == content.len or isWhite(content[k + 1]))) {
                return .{ .key = try self.decodeQuoted(content[0..end]), .rest = k + 1 };
            }
            return null;
        }
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == ':' and (i + 1 == content.len or isWhite(content[i + 1]))) {
                // The key may be empty (`: value`).
                const key = std.mem.trimEnd(u8, content[0..i], " \t");
                return .{ .key = try self.a.dupe(u8, key), .rest = i + 1 };
            }
        }
        return null;
    }

    fn mapping(self: *Parser, indent: usize) Error!Value {
        const map = try self.a.create(Map);
        map.* = .{};
        while (true) {
            try self.skipBlank();
            const c = (try self.cur()) orelse break;
            if (c.indent < indent or isDocMarker(c)) break;
            if (c.indent > indent) return self.err("bad indentation of a mapping entry");
            if (isSeqEntry(c.content)) break;
            const ki = (try self.splitKey(c.content)) orelse return self.err("expected 'key:'");
            if (map.entries.contains(ki.key)) return self.err("duplicate key");
            const before = try self.takeBefore();
            const raw = self.lines[self.pos][indent..];
            const rest = std.mem.trimStart(u8, raw[ki.rest..], " \t");
            const sc = splitComment(rest);
            var v: Value = undefined;
            var after: ?[]const u8 = null;
            if (std.mem.trim(u8, sc.content, " \t").len == 0) {
                after = if (sc.comment) |t| try self.a.dupe(u8, t) else null;
                self.pos += 1;
                try self.skipBlank();
                const next = try self.cur();
                if (next != null and next.?.indent > indent) {
                    if (self.step == 0 and next.?.indent - indent <= 8) self.step = @intCast(next.?.indent - indent);
                    v = try self.block(@intCast(indent));
                } else if (next != null and next.?.indent == indent and isSeqEntry(next.?.content)) {
                    try self.enter();
                    defer self.depth -= 1;
                    v = try self.sequence(indent);
                } else v = null_scalar;
            } else {
                v = try self.scalarAt(rest, @intCast(indent));
                after = self.takeTrailing();
            }
            try map.entries.put(self.a, ki.key, v);
            if (before.len != 0 or after != null) try map.comments.put(self.a, ki.key, .{ .before = before, .after = after });
        }
        return .{ .map = map };
    }

    // ---- scalars and flow collections ---------------------------------------------------

    /// The value whose text is `rest` (it may end in a comment) on line `pos`.
    /// Consumes the lines it spans, sets `trailing`.
    fn scalarAt(self: *Parser, rest_in: []const u8, parent: i64) Error!Value {
        const rest = std.mem.trimStart(u8, rest_in, " \t");
        const c = rest[0];
        switch (c) {
            '&', '*', '!' => return self.unsupported("anchors, aliases and tags are not supported"),
            '@', '`' => return self.err("a reserved indicator cannot start a scalar"),
            '%' => return self.err("a '%' cannot start a plain scalar"),
            '"', '\'' => return self.quotedScalar(rest, parent),
            '|', '>' => return self.blockScalar(rest, parent),
            '[', '{' => return self.flowValue(rest, parent),
            else => return self.plainScalar(rest, parent),
        }
    }

    const Gathered = struct {
        /// The quoted scalar, quotes included, line breaks as `\n`.
        quoted: []const u8,
        /// What follows the closing quote on its line.
        tail: []const u8,
    };

    /// Reads the quoted scalar that starts `first`, a suffix of the current
    /// line, leaving `pos` on the line that closes it. The lines are gathered
    /// in one growable buffer and the search for the closing quote resumes
    /// where it stopped, so the cost stays linear in the size of the scalar.
    fn gatherQuoted(self: *Parser, first: []const u8, parent: i64) Error!Gathered {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try buf.appendSlice(self.gpa, first);
        var scan: QuoteScan = .{ .quote = first[0] };
        var line = first;
        const end = while (true) {
            if (scan.find(buf.items)) |e| break e;
            self.pos += 1;
            if (self.pos >= self.lines.len) return self.err("unterminated quoted scalar");
            line = self.lines[self.pos];
            try self.checkContinuation(line, parent);
            try buf.append(self.gpa, '\n');
            try buf.appendSlice(self.gpa, line);
        };
        return .{
            .quoted = try self.a.dupe(u8, buf.items[0..end]),
            .tail = line[line.len - (buf.items.len - end) ..],
        };
    }

    fn quotedScalar(self: *Parser, first: []const u8, parent: i64) Error!Value {
        const g = try self.gatherQuoted(first, parent);
        const tail = splitComment(g.tail);
        if (std.mem.trim(u8, tail.content, " \t").len != 0) return self.err("unexpected text after a quoted scalar");
        self.trailing = if (tail.comment) |t| try self.a.dupe(u8, t) else null;
        const s = try self.decodeQuoted(g.quoted);
        self.pos += 1;
        return .{ .scalar = .{ .text = s, .style = if (g.quoted[0] == '"') .double else .single, .kind = .string } };
    }

    /// A further line of a flow scalar or flow collection must be indented
    /// past the parent (YAML 1.2.2 `s-flow-line-prefix`) and must not be a
    /// document marker (`c-forbidden`). Blank lines are exempt.
    fn checkContinuation(self: *Parser, line: []const u8, parent: i64) Error!void {
        if (isBlank(line)) return;
        if (isForbidden(line)) return self.err("a document marker cannot appear here");
        if (@as(i64, @intCast(indentOf(line))) <= parent) return self.err("a continuation line is not indented enough");
    }

    fn plainScalar(self: *Parser, first: []const u8, parent: i64) Error!Value {
        const sc = splitComment(first);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.a, std.mem.trimEnd(u8, sc.content, " \t"));
        var comment = sc.comment;
        self.pos += 1;
        // Continuation lines: more indented than the parent, until a comment.
        while (comment == null) {
            var j = self.pos;
            var blanks: usize = 0;
            while (j < self.lines.len and isBlank(self.lines[j])) : (j += 1) blanks += 1;
            if (j >= self.lines.len) break;
            const l = self.lines[j];
            const ind = indentOf(l);
            if (@as(i64, @intCast(ind)) <= parent or l[ind] == '#' or isForbidden(l)) break;
            const part = splitComment(l[ind..]);
            const t = std.mem.trim(u8, part.content, " \t");
            if (std.mem.indexOf(u8, t, ": ") != null or std.mem.endsWith(u8, t, ":") or isSeqEntry(t) or (t.len > 0 and (t[0] == '"' or t[0] == '\'' or t[0] == '[' or t[0] == '{' or t[0] == '|' or t[0] == '>')))
                return self.err("unexpected content after a plain scalar (bad indentation?)");
            if (blanks == 0) try out.append(self.a, ' ') else try out.appendNTimes(self.a, '\n', blanks);
            try out.appendSlice(self.a, t);
            comment = part.comment;
            self.pos = j + 1;
        }
        self.trailing = if (comment) |t| try self.a.dupe(u8, t) else null;
        const text = out.items;
        return .{ .scalar = .{ .text = text, .style = .plain, .kind = model.resolve(text) } };
    }

    fn blockScalar(self: *Parser, header: []const u8, parent: i64) Error!Value {
        const sc = splitComment(header);
        const h = std.mem.trim(u8, sc.content, " \t");
        const literal = h[0] == '|';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: usize = 0;
        for (h[1..]) |c| switch (c) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '1'...'9' => explicit = c - '0',
            else => return self.err("bad block scalar header"),
        };
        self.trailing = if (sc.comment) |t| try self.a.dupe(u8, t) else null;
        self.pos += 1;

        // The body is indented past the parent; its first non-blank line sets
        // how far, unless an indicator says.
        const floor: usize = if (parent < 0) 0 else @intCast(parent + 1);
        var content_indent: ?usize = null;
        if (explicit != 0) content_indent = (if (parent < 0) 0 else @as(usize, @intCast(parent))) + explicit;
        var end = self.pos;
        var last_content = self.pos; // one past the last non-blank line
        while (end < self.lines.len) : (end += 1) {
            const l = self.lines[end];
            if (isBlank(l)) continue;
            if (isForbidden(l)) break;
            const ind = indentOf(l);
            if (content_indent == null) {
                if (ind < floor) break;
                content_indent = ind;
            }
            if (ind < content_indent.?) break;
            last_content = end + 1;
        }
        const ci = content_indent orelse 0;
        const body_end = if (chomp == .keep) end else last_content;
        var lines: std.ArrayList([]const u8) = .empty;
        var i = self.pos;
        while (i < body_end) : (i += 1) {
            const l = self.lines[i];
            try lines.append(self.a, if (isBlank(l) or l.len <= ci) "" else l[ci..]);
        }
        self.pos = body_end;
        // Blank lines after the body that were not taken stay for the next item.
        var out: std.ArrayList(u8) = .empty;
        var trailing_blank: usize = 0;
        var nlines = lines.items.len;
        while (nlines > 0 and lines.items[nlines - 1].len == 0) : (nlines -= 1) trailing_blank += 1;
        if (literal) {
            for (lines.items[0..nlines], 0..) |l, k| {
                if (k != 0) try out.append(self.a, '\n');
                try out.appendSlice(self.a, l);
            }
        } else {
            var blanks: usize = 0;
            var prev_more = false;
            var started = false;
            for (lines.items[0..nlines]) |l| {
                if (l.len == 0) {
                    blanks += 1;
                    continue;
                }
                const more = l[0] == ' ' or l[0] == '\t';
                if (started) {
                    if (!prev_more and !more) {
                        if (blanks == 0) try out.append(self.a, ' ') else try out.appendNTimes(self.a, '\n', blanks);
                    } else try out.appendNTimes(self.a, '\n', blanks + 1);
                } else try out.appendNTimes(self.a, '\n', blanks);
                try out.appendSlice(self.a, l);
                blanks = 0;
                prev_more = more;
                started = true;
            }
        }
        if (nlines > 0) switch (chomp) {
            .strip => {},
            .clip => try out.append(self.a, '\n'),
            .keep => try out.appendNTimes(self.a, '\n', 1 + trailing_blank),
        } else if (chomp == .keep) try out.appendNTimes(self.a, '\n', trailing_blank);
        return .{ .scalar = .{ .text = out.items, .style = if (literal) .literal else .folded, .kind = .string } };
    }

    // ---- flow collections ---------------------------------------------------------------

    /// The flow collection that starts `first`, a suffix of the current line.
    fn flowValue(self: *Parser, first: []const u8, parent: i64) Error!Value {
        const line = self.lines[self.pos];
        var flow: Flow = .{ .p = self, .line = line, .i = line.len - first.len, .parent = parent };
        const v = try flow.node();
        const tail = flow.line[flow.i..];
        const rest = std.mem.trimStart(u8, tail, " \t");
        self.trailing = null;
        if (rest.len != 0) {
            if (rest[0] == ':') return self.unsupported("a collection as a key is not supported");
            if (rest[0] != '#' or rest.len == tail.len) return self.err("unexpected text after a flow collection");
            self.trailing = try self.a.dupe(u8, std.mem.trimEnd(u8, rest, " \t"));
        }
        self.pos += 1;
        return v;
    }

    // ---- quoted text ---------------------------------------------------------------------

    /// Decodes a whole quoted scalar including its quotes. Line breaks (`\n`
    /// bytes in `q`) are folded as YAML does.
    fn decodeQuoted(self: *Parser, q: []const u8) Error![]const u8 {
        const double = q[0] == '"';
        const body = q[1 .. q.len - 1];
        var out: std.ArrayList(u8) = .empty;
        var keep: usize = 0; // output length that trailing blanks must not cut below
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            if (c == '\n') {
                out.items.len = @max(keep, trimWs(out.items));
                var blanks: usize = 0;
                i += 1;
                while (i < body.len) : (i += 1) {
                    if (body[i] == ' ' or body[i] == '\t') continue;
                    if (body[i] == '\n') {
                        blanks += 1;
                        continue;
                    }
                    break;
                }
                i -= 1;
                if (blanks == 0) try out.append(self.a, ' ') else try out.appendNTimes(self.a, '\n', blanks);
                continue;
            }
            if (!double) {
                if (c == '\'' and i + 1 < body.len and body[i + 1] == '\'') i += 1;
                try out.append(self.a, c);
                continue;
            }
            if (c != '\\') {
                try out.append(self.a, c);
                continue;
            }
            i += 1;
            if (i >= body.len) return self.err("bad escape in a double-quoted scalar");
            switch (body[i]) {
                '0' => try out.append(self.a, 0),
                'a' => try out.append(self.a, 7),
                'b' => try out.append(self.a, 8),
                't', '\t' => try out.append(self.a, '\t'),
                'n' => try out.append(self.a, '\n'),
                'v' => try out.append(self.a, 11),
                'f' => try out.append(self.a, 12),
                'r' => try out.append(self.a, '\r'),
                'e' => try out.append(self.a, 27),
                ' ' => try out.append(self.a, ' '),
                '"' => try out.append(self.a, '"'),
                '/' => try out.append(self.a, '/'),
                '\\' => try out.append(self.a, '\\'),
                'N' => try out.appendSlice(self.a, "\u{85}"),
                '_' => try out.appendSlice(self.a, "\u{a0}"),
                'L' => try out.appendSlice(self.a, "\u{2028}"),
                'P' => try out.appendSlice(self.a, "\u{2029}"),
                'x', 'u', 'U' => {
                    const n: usize = if (body[i] == 'x') 2 else if (body[i] == 'u') 4 else 8;
                    if (i + 1 + n > body.len) return self.err("bad escape in a double-quoted scalar");
                    const cp = std.fmt.parseInt(u21, body[i + 1 .. i + 1 + n], 16) catch return self.err("bad escape in a double-quoted scalar");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return self.err("bad escape in a double-quoted scalar");
                    try out.appendSlice(self.a, buf[0..len]);
                    i += n;
                },
                '\n' => {
                    // An escaped line break joins the lines without a space.
                    while (i + 1 < body.len and (body[i + 1] == ' ' or body[i + 1] == '\t')) i += 1;
                    continue;
                },
                else => return self.err("unknown escape in a double-quoted scalar"),
            }
            keep = out.items.len;
        }
        return out.items;
    }

    /// Length of `s` without trailing blanks.
    fn trimWs(s: []const u8) usize {
        var n = s.len;
        while (n > 0 and (s[n - 1] == ' ' or s[n - 1] == '\t')) n -= 1;
        return n;
    }
};

/// Reads a flow collection straight from the source lines: `line` is line
/// `p.pos` and `i` the next byte in it. Comments inside the collection are
/// dropped.
const Flow = struct {
    p: *Parser,
    line: []const u8,
    i: usize,
    /// Indent of the enclosing block node; further lines must go past it.
    parent: i64,

    fn peek(self: *const Flow) ?u8 {
        return if (self.i < self.line.len) self.line[self.i] else null;
    }

    fn skipInLine(self: *Flow) void {
        while (self.i < self.line.len and (self.line[self.i] == ' ' or self.line[self.i] == '\t')) self.i += 1;
    }

    /// Skips blanks, comments and line breaks up to the next token.
    fn skip(self: *Flow) Error!void {
        while (true) {
            self.skipInLine();
            if (self.i < self.line.len) {
                // A `#` is a comment only after a blank or at a line's start.
                const comment = self.line[self.i] == '#' and
                    (self.i == 0 or self.line[self.i - 1] == ' ' or self.line[self.i - 1] == '\t');
                if (!comment) return;
            }
            self.p.pos += 1;
            if (self.p.pos >= self.p.lines.len) return self.p.err("unterminated flow collection");
            self.line = self.p.lines[self.p.pos];
            self.i = 0;
            const body = std.mem.trimStart(u8, self.line, " \t");
            // Comment lines may be indented any amount.
            if (body.len != 0 and body[0] != '#') try self.p.checkContinuation(self.line, self.parent);
        }
    }

    /// True if the byte after the current one cannot continue a plain scalar.
    fn separatorFollows(self: *const Flow) bool {
        if (self.i + 1 >= self.line.len) return true;
        return switch (self.line[self.i + 1]) {
            ' ', '\t', ',', '[', ']', '{', '}' => true,
            else => false,
        };
    }

    fn node(self: *Flow) Error!Value {
        const c = self.peek() orelse return self.p.err("expected a value in a flow collection");
        switch (c) {
            '[' => return self.seq(),
            '{' => return self.map(),
            '"', '\'' => {
                const g = try self.p.gatherQuoted(self.line[self.i..], self.parent);
                self.line = self.p.lines[self.p.pos];
                self.i = self.line.len - g.tail.len;
                const t = try self.p.decodeQuoted(g.quoted);
                return .{ .scalar = .{ .text = t, .style = if (c == '"') .double else .single, .kind = .string } };
            },
            '&', '*', '!' => return self.p.unsupported("anchors, aliases and tags are not supported"),
            ',', ']', '}' => return self.p.err("a flow collection entry cannot be empty"),
            '|', '>', '%', '@', '`', '#' => return self.p.err("this character cannot start a value in a flow collection"),
            '?', ':', '-' => {
                if (self.separatorFollows()) {
                    if (c == '?') return self.p.unsupported("complex keys are not supported");
                    return self.p.err("this indicator cannot start a value in a flow collection");
                }
                return self.plain();
            },
            else => return self.plain(),
        }
    }

    /// Consumes the part of a plain scalar that is on the current line, and
    /// returns it without trailing blanks.
    fn plainLine(self: *Flow) []const u8 {
        const start = self.i;
        while (self.i < self.line.len) : (self.i += 1) {
            const c = self.line[self.i];
            if (c == ',' or c == '[' or c == ']' or c == '{' or c == '}') break;
            if (c == ':' and self.separatorFollows()) break;
            if (c == '#' and self.i > start and (self.line[self.i - 1] == ' ' or self.line[self.i - 1] == '\t')) break;
        }
        return std.mem.trimEnd(u8, self.line[start..self.i], " \t");
    }

    fn plain(self: *Flow) Error!Value {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.p.a, self.plainLine());
        // It goes on while the following lines start with plain text.
        while (self.i == self.line.len) {
            var j = self.p.pos + 1;
            while (j < self.p.lines.len and Parser.isBlank(self.p.lines[j])) j += 1;
            if (j >= self.p.lines.len) break;
            const next = self.p.lines[j];
            const body = std.mem.trimStart(u8, next, " \t");
            var probe: Flow = .{ .p = self.p, .line = body, .i = 0, .parent = self.parent };
            switch (body[0]) {
                ',', '[', ']', '{', '}', '#' => break,
                ':' => if (probe.separatorFollows()) break,
                else => {},
            }
            try self.p.checkContinuation(next, self.parent);
            const blanks = j - self.p.pos - 1;
            if (blanks == 0) try out.append(self.p.a, ' ') else try out.appendNTimes(self.p.a, '\n', blanks);
            self.p.pos = j;
            self.line = next;
            self.i = next.len - body.len;
            try out.appendSlice(self.p.a, self.plainLine());
        }
        const text = out.items;
        return .{ .scalar = .{ .text = text, .style = .plain, .kind = model.resolve(text) } };
    }

    /// An entry of a flow mapping, or of a flow sequence that turns out to be
    /// a single `key: value` pair.
    const Entry = struct { key: Value, value: ?Value };

    fn entry(self: *Flow, in_mapping: bool) Error!Entry {
        const first_line = self.p.pos;
        var key: Value = null_scalar;
        var json_like = false;
        const empty_key = self.peek() == ':' and self.separatorFollows();
        if (!empty_key) {
            const c = self.peek().?;
            json_like = c == '"' or c == '\'' or c == '[' or c == '{';
            key = try self.node();
        }
        // In a sequence, a pair's key and its `:` share one line.
        if (in_mapping) try self.skip() else self.skipInLine();
        // `"key":value` may leave out the blank after the colon.
        if (self.peek() != ':' or !(json_like or self.separatorFollows())) return .{ .key = key, .value = null };
        if (!in_mapping and self.p.pos != first_line) return self.p.err("a key in a flow sequence must be on one line");
        self.i += 1;
        try self.skip();
        const c = self.peek().?;
        const value = if (c == ',' or c == ']' or c == '}') null_scalar else try self.node();
        return .{ .key = key, .value = value };
    }

    fn keyText(self: *Flow, key: Value) Error![]const u8 {
        return switch (key) {
            .scalar => |s| s.text,
            else => self.p.unsupported("a collection as a key is not supported"),
        };
    }

    /// Consumes the `,` after an entry, or stops before the closing bracket.
    fn separator(self: *Flow, close: u8, msg: []const u8) Error!void {
        try self.skip();
        if (self.peek() == ',') {
            self.i += 1;
        } else if (self.peek() != close) return self.p.err(msg);
    }

    fn seq(self: *Flow) Error!Value {
        try self.p.enter();
        defer self.p.depth -= 1;
        self.i += 1; // '['
        const s = try self.p.a.create(Seq);
        s.* = .{ .flow = true };
        while (true) {
            try self.skip();
            if (self.peek() == ']') {
                self.i += 1;
                return .{ .seq = s };
            }
            const e = try self.entry(false);
            if (e.value) |v| {
                const pair = try self.p.a.create(Map);
                pair.* = .{ .flow = true };
                try pair.entries.put(self.p.a, try self.keyText(e.key), v);
                try s.append(self.p.a, .{ .map = pair });
            } else try s.append(self.p.a, e.key);
            try self.separator(']', "expected ',' or ']' in a flow sequence");
        }
    }

    fn map(self: *Flow) Error!Value {
        try self.p.enter();
        defer self.p.depth -= 1;
        self.i += 1; // '{'
        const m = try self.p.a.create(Map);
        m.* = .{ .flow = true };
        while (true) {
            try self.skip();
            if (self.peek() == '}') {
                self.i += 1;
                return .{ .map = m };
            }
            const e = try self.entry(true);
            const key = try self.keyText(e.key);
            if (m.entries.contains(key)) return self.p.err("duplicate key");
            try m.entries.put(self.p.a, key, e.value orelse null_scalar);
            try self.separator('}', "expected ',' or '}' in a flow mapping");
        }
    }
};

const CommentSplit = struct { content: []const u8, comment: ?[]const u8 };

/// Splits a trailing `# comment` off `s`. A `#` starts one only at the start or
/// after a blank, and not inside a quoted scalar.
fn splitComment(s: []const u8) CommentSplit {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return .{ .content = s[0..i], .comment = std.mem.trimEnd(u8, s[i..], " \t") };
        }
        if ((c == '"' or c == '\'') and quoteStarts(s, i)) {
            if (scanQuoted(s[i..])) |e| {
                i += e - 1;
            } else return .{ .content = s, .comment = null }; // runs on to the next line
        }
    }
    return .{ .content = s, .comment = null };
}

/// A quote opens a quoted scalar only where a value or key can start.
fn quoteStarts(s: []const u8, i: usize) bool {
    if (i == 0) return true;
    return switch (s[i - 1]) {
        ' ', '\t', '[', '{', ',', ':' => true,
        else => false,
    };
}

/// `---` or `...` at the very start of a line, followed by a blank or nothing
/// (YAML 1.2.2 `c-forbidden`).
fn isForbidden(line: []const u8) bool {
    if (line.len < 3) return false;
    if (!std.mem.eql(u8, line[0..3], "---") and !std.mem.eql(u8, line[0..3], "...")) return false;
    return line.len == 3 or line[3] == ' ' or line[3] == '\t';
}

/// Finds the quote that closes a quoted scalar. `find` may be called again
/// after more text is appended; it does not rescan what it has seen.
const QuoteScan = struct {
    quote: u8,
    i: usize = 1,

    /// The offset just past the closing quote, or null if `s` does not close it.
    fn find(self: *QuoteScan, s: []const u8) ?usize {
        while (self.i < s.len) : (self.i += 1) {
            const c = s[self.i];
            if (self.quote == '"' and c == '\\') {
                self.i += 1;
            } else if (c == self.quote) {
                if (self.quote == '\'' and self.i + 1 < s.len and s[self.i + 1] == '\'') {
                    self.i += 1;
                } else return self.i + 1;
            }
        }
        return null;
    }
};

/// For a string starting with a quote: the offset just past the closing quote,
/// or null if it is not closed in `s`.
fn scanQuoted(s: []const u8) ?usize {
    var scan: QuoteScan = .{ .quote = s[0] };
    return scan.find(s);
}
