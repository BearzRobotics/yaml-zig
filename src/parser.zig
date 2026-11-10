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
        if (try self.cur()) |c| {
            if (std.mem.eql(u8, c.content, "---")) {
                res.explicit_start = true;
                if (self.pending.items.len != 0) res.header = try self.a.dupe([]const u8, self.pending.items);
                self.pending.clearRetainingCapacity();
                self.pos += 1;
            } else if (c.content.len != 0 and c.content[0] == '%') return self.unsupported("directives are not supported");
        }
        res.root = try self.block(-1);
        try self.skipBlank();
        if (try self.cur()) |c| {
            if (std.mem.eql(u8, c.content, "...")) {
                self.pos += 1;
                try self.skipBlank();
                if (self.pos < self.lines.len) return self.unsupported("several documents are not supported");
            } else if (std.mem.startsWith(u8, c.content, "---")) {
                return self.unsupported("several documents are not supported");
            } else return self.err("unexpected content or bad indentation");
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
        try self.enter();
        defer self.depth -= 1;
        if (isSeqEntry(c.content)) return self.sequence(c.indent);
        if (try self.splitKey(c.content)) |_| return self.mapping(c.indent);
        return self.scalarAt(self.lines[self.pos][c.indent..], parent);
    }

    // ---- sequences -----------------------------------------------------------------

    /// `---` or `...` at the start of a line ends or starts a document.
    fn isDocMarker(c: Cur) bool {
        if (c.indent != 0 or c.content.len < 3) return false;
        const m = c.content[0..3];
        if (!std.mem.eql(u8, m, "---") and !std.mem.eql(u8, m, "...")) return false;
        return c.content.len == 3 or c.content[3] == ' ';
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
        if (c0 == '[' or c0 == '{' or c0 == '|' or c0 == '>') return null;
        if (c0 == '?' and (content.len == 1 or content[1] == ' ')) return self.unsupported("complex keys are not supported");
        if (c0 == '"' or c0 == '\'') {
            const end = scanQuoted(content) orelse return null;
            var k = end;
            while (k < content.len and content[k] == ' ') k += 1;
            if (k < content.len and content[k] == ':' and (k + 1 == content.len or content[k + 1] == ' ')) {
                return .{ .key = try self.decodeQuoted(content[0..end]), .rest = k + 1 };
            }
            return null;
        }
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            if (content[i] == ':' and (i + 1 == content.len or content[i + 1] == ' ' or content[i + 1] == '\t')) {
                const key = std.mem.trimEnd(u8, content[0..i], " \t");
                if (key.len == 0) return self.err("empty key");
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
            '"', '\'' => return self.quotedScalar(rest),
            '|', '>' => return self.blockScalar(rest, parent),
            '[', '{' => return self.flowValue(rest),
            else => return self.plainScalar(rest, parent),
        }
    }

    fn quotedScalar(self: *Parser, first: []const u8) Error!Value {
        var text: []const u8 = first;
        var end = scanQuoted(text);
        // A quoted scalar may run over several lines.
        while (end == null) {
            self.pos += 1;
            if (self.pos >= self.lines.len) return self.err("unterminated quoted scalar");
            text = try std.mem.concat(self.a, u8, &.{ text, "\n", self.lines[self.pos] });
            end = scanQuoted(text);
        }
        const tail = splitComment(text[end.?..]);
        if (std.mem.trim(u8, tail.content, " \t").len != 0) return self.err("unexpected text after a quoted scalar");
        self.trailing = if (tail.comment) |t| try self.a.dupe(u8, t) else null;
        self.pos += 1;
        const s = try self.decodeQuoted(text[0..end.?]);
        return .{ .scalar = .{ .text = s, .style = if (text[0] == '"') .double else .single, .kind = .string } };
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
            if (@as(i64, @intCast(ind)) <= parent or l[ind] == '#') break;
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

    fn flowValue(self: *Parser, first: []const u8) Error!Value {
        // Gather lines until the brackets balance; comments inside are dropped.
        var text: std.ArrayList(u8) = .empty;
        var sc = splitComment(first);
        try text.appendSlice(self.a, std.mem.trimEnd(u8, sc.content, " \t"));
        var comment = sc.comment;
        while (!balanced(text.items)) {
            self.pos += 1;
            if (self.pos >= self.lines.len) return self.err("unterminated flow collection");
            sc = splitComment(self.lines[self.pos]);
            try text.append(self.a, ' ');
            try text.appendSlice(self.a, std.mem.trim(u8, sc.content, " \t"));
            if (sc.comment != null) comment = sc.comment;
        }
        self.pos += 1;
        self.trailing = if (comment) |t| try self.a.dupe(u8, t) else null;
        var fp: Flow = .{ .p = self, .s = text.items };
        const v = try fp.value();
        fp.skipWs();
        if (fp.i != fp.s.len) return self.err("unexpected text after a flow collection");
        return v;
    }

    fn balanced(s: []const u8) bool {
        var depth: i32 = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                '[', '{' => depth += 1,
                ']', '}' => depth -= 1,
                '"', '\'' => {
                    if (scanQuoted(s[i..])) |e| i += e - 1 else return false;
                },
                else => {},
            }
        }
        return depth <= 0;
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

const Flow = struct {
    p: *Parser,
    s: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn skipWs(self: *Flow) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn value(self: *Flow) Error!Value {
        self.skipWs();
        if (self.i >= self.s.len) return self.p.err("expected a value in a flow collection");
        if (self.depth >= self.p.options.max_depth) return self.p.fail("nesting too deep", error.LimitExceeded);
        self.depth += 1;
        defer self.depth -= 1;
        switch (self.s[self.i]) {
            '[' => return self.seq(),
            '{' => return self.map(),
            '"', '\'' => {
                const end = scanQuoted(self.s[self.i..]) orelse return self.p.err("unterminated quoted scalar");
                const q = self.s[self.i .. self.i + end];
                self.i += end;
                const t = try self.p.decodeQuoted(q);
                return .{ .scalar = .{ .text = t, .style = if (q[0] == '"') .double else .single, .kind = .string } };
            },
            '&', '*', '!' => return self.p.unsupported("anchors, aliases and tags are not supported"),
            else => {
                const start = self.i;
                while (self.i < self.s.len) : (self.i += 1) {
                    const c = self.s[self.i];
                    if (c == ',' or c == ']' or c == '}' or c == '[' or c == '{') break;
                    if (c == ':' and (self.i + 1 == self.s.len or self.s[self.i + 1] == ' ' or self.s[self.i + 1] == ',' or self.s[self.i + 1] == ']' or self.s[self.i + 1] == '}')) break;
                }
                const t = std.mem.trim(u8, self.s[start..self.i], " \t");
                const dup = try self.p.a.dupe(u8, t);
                return .{ .scalar = .{ .text = dup, .style = .plain, .kind = model.resolve(dup) } };
            },
        }
    }

    fn seq(self: *Flow) Error!Value {
        self.i += 1; // '['
        const s = try self.p.a.create(Seq);
        s.* = .{ .flow = true };
        while (true) {
            self.skipWs();
            if (self.i >= self.s.len) return self.p.err("unterminated flow sequence");
            if (self.s[self.i] == ']') {
                self.i += 1;
                return .{ .seq = s };
            }
            try s.append(self.p.a, try self.value());
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == ',') {
                self.i += 1;
            } else if (self.i < self.s.len and self.s[self.i] == ']') {
                continue;
            } else return self.p.err("expected ',' or ']' in a flow sequence");
        }
    }

    fn map(self: *Flow) Error!Value {
        self.i += 1; // '{'
        const m = try self.p.a.create(Map);
        m.* = .{ .flow = true };
        while (true) {
            self.skipWs();
            if (self.i >= self.s.len) return self.p.err("unterminated flow mapping");
            if (self.s[self.i] == '}') {
                self.i += 1;
                return .{ .map = m };
            }
            const k = try self.value();
            const key = switch (k) {
                .scalar => |sc| sc.text,
                else => return self.p.err("a flow mapping key must be a scalar"),
            };
            if (m.entries.contains(key)) return self.p.err("duplicate key");
            self.skipWs();
            var v: Value = null_scalar;
            if (self.i < self.s.len and self.s[self.i] == ':') {
                self.i += 1;
                self.skipWs();
                if (self.i < self.s.len and self.s[self.i] != ',' and self.s[self.i] != '}') v = try self.value();
            }
            try m.entries.put(self.p.a, key, v);
            self.skipWs();
            if (self.i < self.s.len and self.s[self.i] == ',') {
                self.i += 1;
            } else if (self.i < self.s.len and self.s[self.i] == '}') {
                continue;
            } else return self.p.err("expected ',' or '}' in a flow mapping");
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

/// For a string starting with a quote: the offset just past the closing quote,
/// or null if it is not closed in `s`.
fn scanQuoted(s: []const u8) ?usize {
    const q = s[0];
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (q == '"') {
            if (s[i] == '\\') {
                i += 1;
                continue;
            }
            if (s[i] == '"') return i + 1;
        } else if (s[i] == '\'') {
            if (i + 1 < s.len and s[i + 1] == '\'') {
                i += 1;
                continue;
            }
            return i + 1;
        }
    }
    return null;
}
