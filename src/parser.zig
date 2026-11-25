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
//! anchors, aliases, tags, directives, complex keys (`? `, or a collection as
//! a key), several documents in one stream.
//!
//! The rules follow YAML 1.2.2, https://yaml.org/spec/1.2.2/, whose
//! production names (`c-forbidden`, `s-flow-line-prefix`) appear in comments.
//! ai/SPEC.md lists the one deliberate departure.
//!
//! The input is split into lines. Block structure is walked by indentation:
//! `readNode` reads whatever starts at a position and then says whether a `:`
//! made it a key (docs/decisions/0001). `Flow` moves a cursor over the same
//! lines for `[...]` and `{...}`. Comment
//! and blank lines collect in `pending` and become the `before` of the next
//! item; a comment after a value on its line is left in `trailing`, and
//! becomes the item's `after`. Every path that reads a value must take it.

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
    /// Nesting or input size exceeded `Options` limits.
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
    /// Comments on a root that is a scalar or a flow collection. (Those of a
    /// block collection belong to its items.)
    root_comments: Comments = .{},
    /// The comment on the `---` line.
    start_comment: ?[]const u8 = null,
};

const null_scalar: Value = .{ .scalar = .{ .text = "", .style = .plain, .kind = .null } };

pub fn parse(gpa: Allocator, arena: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) Error!Result {
    if (source.len > options.max_bytes) return failAt(diag, 1, 1, "input too large", error.LimitExceeded);
    if (!std.unicode.utf8ValidateSlice(source)) return failAt(diag, 1, 1, "invalid UTF-8", error.InvalidUtf8);
    var text = source;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    // A line ends at LF, CR LF or a lone CR (`b-break`).
    var start: usize = 0;
    while (start < text.len) {
        var end = start;
        while (end < text.len and text[end] != '\n' and text[end] != '\r') : (end += 1) {
            // No other control character may appear anywhere in a stream.
            if (text[end] < 0x20 and text[end] != '\t') return failAt(diag, lines.items.len + 1, end - start + 1, "control character", error.Syntax);
        }
        try lines.append(gpa, text[start..end]);
        start = end + 1;
        if (end < text.len and text[end] == '\r' and start < text.len and text[start] == '\n') start += 1;
    }

    var p: Parser = .{ .a = arena, .gpa = gpa, .lines = lines.items, .options = options, .diag = diag };
    defer p.pending.deinit(gpa);
    defer p.scratch.deinit(gpa);
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
    /// Tabs separate the indent from the content. Such a line may hold a scalar
    /// or a flow collection, but no block structure: tabs do not indent.
    tabbed: bool = false,
};

const Parser = struct {
    a: Allocator,
    gpa: Allocator,
    lines: []const []const u8,
    pos: usize = 0,
    options: Options,
    diag: ?*Diagnostic,
    pending: std.ArrayList([]const u8) = .empty,
    /// Where the text of one scalar is put together before it is copied to the
    /// arena. Reused, so that a document with many scalars does not allocate
    /// and free a buffer for each.
    scratch: std.ArrayList(u8) = .empty,
    trailing: ?[]const u8 = null,
    seen_item: bool = false,
    depth: u32 = 0,
    step: u8 = 0,
    /// Column of the quote that opens the quoted scalar read last.
    quote_column: usize = 1,

    fn err(self: *Parser, msg: []const u8) Error {
        return self.fail(msg, error.Syntax);
    }

    fn unsupported(self: *Parser, msg: []const u8) Error {
        return self.fail(msg, error.Unsupported);
    }

    /// The column at which `suffix`, the end of the current line, starts.
    fn columnOf(self: *const Parser, suffix: []const u8) usize {
        return self.lines[self.pos].len - suffix.len + 1;
    }

    /// Reports a syntax error at the start of `suffix`.
    fn errAt(self: *Parser, suffix: []const u8, msg: []const u8) Error {
        return failAt(self.diag, self.pos + 1, self.columnOf(suffix), msg, error.Syntax);
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
            } else {
                const body = std.mem.trim(u8, l, " \t");
                if (body[0] != '#') break;
                try self.pending.append(self.gpa, try self.keepComment(body));
            }
        }
    }

    /// The current (non-blank, non-comment) line; call `skipBlank` first.
    fn cur(self: *Parser) Error!?Cur {
        if (self.pos >= self.lines.len) return null;
        const l = self.lines[self.pos];
        const ind = indentOf(l);
        const body = std.mem.trimStart(u8, l[ind..], " \t");
        const sc = splitComment(body);
        return .{ .indent = ind, .content = std.mem.trimEnd(u8, sc.content, " \t"), .tabbed = body.len != l.len - ind };
    }

    /// Quoted scalars may hold any character that is not a C0 control; all
    /// other text must be printable.
    fn checkPrintable(self: *Parser, text: []const u8) Error!void {
        if (model.findNonPrintable(text) != null) return self.err("non-printable character outside a quoted scalar");
    }

    fn keepComment(self: *Parser, text: []const u8) Error![]const u8 {
        try self.checkPrintable(text);
        return self.a.dupe(u8, text);
    }

    fn takeBefore(self: *Parser) Error![]const []const u8 {
        defer {
            self.pending.clearRetainingCapacity();
            self.seen_item = true;
        }
        if (self.pending.items.len == 0) return &.{};
        return self.a.dupe([]const u8, self.pending.items);
    }

    /// Takes the document's indentation step from the first block collection
    /// found on a line below the item it is nested in.
    fn learnStep(self: *Parser, indent: usize, under: ?usize) void {
        const parent = under orelse return;
        if (self.step == 0 and indent > parent and indent - parent <= 8) self.step = @intCast(indent - parent);
    }

    /// A scalar or a flow collection: a value with no items that could carry
    /// comments of their own.
    fn isOneNode(v: Value) bool {
        return switch (v) {
            .scalar => true,
            .seq => |q| q.flow,
            .map => |m| m.flow,
        };
    }

    /// The comments of an item whose value starts below its `key:` or `-` line.
    /// `before` and `line_comment` were found above and on that line. If the
    /// value is one node, comments between the line and the value, and after
    /// the value, have no other owner than this item.
    fn commentsAround(self: *Parser, v: Value, before: []const []const u8, line_comment: ?[]const u8) Error!Comments {
        if (!isOneNode(v)) return .{ .before = before, .after = line_comment };
        const between = try self.takeBefore();
        const value_comment = self.takeTrailing();
        var lines: std.ArrayList([]const u8) = .empty;
        try lines.appendSlice(self.a, before);
        // There is room for one comment on the line that will be written.
        if (value_comment != null) {
            if (line_comment) |c| try lines.append(self.a, c);
        }
        for (between) |l| if (l.len != 0) try lines.append(self.a, l);
        return .{ .before = lines.items, .after = value_comment orelse line_comment };
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
                if (rest.len == 0 or rest[0] == '#') {
                    if (rest.len != 0) res.start_comment = try self.keepComment(std.mem.trimEnd(u8, rest, " \t"));
                    self.pos += 1;
                } else inline_root = rest;
            } else if (c.indent == 0 and c.content[0] == '%') return self.unsupported("directives are not supported");
        }
        if (inline_root) |rest| {
            const on_marker_line = "a block collection cannot start on the '---' line";
            if (isSeqEntry(rest)) return self.err(on_marker_line);
            res.root = switch (try self.readNode(rest, -1, true)) {
                .value => |v| v,
                .key => return self.err(on_marker_line),
            };
            res.root_comments = .{ .after = self.takeTrailing() };
        } else {
            try self.skipBlank();
            const present = if (try self.cur()) |c| !isDocMarker(c) else false;
            res.root = try self.block(-1, null);
            if (present and isOneNode(res.root)) {
                res.root_comments.before = try self.takeBefore();
                res.root_comments.after = self.takeTrailing();
            }
        }
        try self.skipBlank();
        if (try self.cur()) |c| {
            if (!isDocMarker(c)) return self.err("unexpected content or bad indentation");
            if (c.content[0] == '-') return self.unsupported("several documents are not supported");
            // `...` ends the document. It may be repeated.
            while (try self.cur()) |end| {
                if (!isDocMarker(end) or end.content[0] != '.') return self.unsupported("several documents are not supported");
                if (end.content.len != 3) return self.err("unexpected content after '...'");
                // `...` is not written back; its comment becomes a footer line.
                if (splitPlain(self.lines[self.pos][3..]).comment) |t| try self.pending.append(self.gpa, try self.keepComment(t));
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

    /// `enter` for a collection that starts at `suffix`.
    fn enterAt(self: *Parser, suffix: []const u8) Error!void {
        if (self.depth >= self.options.max_depth) return self.failHere(suffix, "nesting too deep", error.LimitExceeded);
        self.depth += 1;
    }

    /// Reports `e` at the start of `suffix`, the end of the current line.
    fn failHere(self: *Parser, suffix: []const u8, msg: []const u8, e: Error) Error {
        return failAt(self.diag, self.pos + 1, self.columnOf(suffix), msg, e);
    }

    /// Reports `e` on the current line, at its first character after the indent.
    fn fail(self: *Parser, msg: []const u8, e: Error) Error {
        const index = @min(self.pos, self.lines.len -| 1);
        const column = if (self.lines.len == 0) 1 else indentOf(self.lines[index]) + 1;
        return failAt(self.diag, index + 1, column, msg, e);
    }

    // ---- block structure -------------------------------------------------------------
    //
    // `readNode` reads whatever starts at a position and says whether a `:` made
    // it a key. The collections are told the column their entries stand in, so
    // one that starts after `- ` is read where it is.

    /// A node on the lines below, indented more than `parent` (an indent, or -1
    /// at the top). `under` is the indent of the item it is nested in, if its
    /// indentation says something about the document's step.
    fn block(self: *Parser, parent: i64, under: ?usize) Error!Value {
        try self.skipBlank();
        const c = (try self.cur()) orelse return null_scalar;
        if (@as(i64, @intCast(c.indent)) <= parent) return null_scalar;
        if (isDocMarker(c)) return null_scalar;
        const rest = std.mem.trimStart(u8, self.lines[self.pos][c.indent..], " \t");
        return self.collectionOrNode(rest, parent, c.indent, c.tabbed, under, "a tab cannot indent a line");
    }

    /// What starts at `rest`, in column `column` of the current line, where a
    /// block collection may start. One cannot if tabs lead up to it.
    fn collectionOrNode(self: *Parser, rest: []const u8, parent: i64, column: usize, tabbed: bool, under: ?usize, tab_message: []const u8) Error!Value {
        if (isSeqEntry(rest)) {
            if (tabbed) return self.err(tab_message);
            try self.enterAt(rest);
            defer self.depth -= 1;
            self.learnStep(column, under);
            return self.sequence(column);
        }
        switch (try self.readNode(rest, parent, true)) {
            .value => |v| return v,
            .key => |key| {
                if (tabbed) return self.err(tab_message);
                // The key may have moved `pos` no further: it is on one line.
                try self.enterAt(rest);
                defer self.depth -= 1;
                self.learnStep(column, under);
                return self.mapping(column, key);
            },
        }
    }

    fn isSeqEntry(content: []const u8) bool {
        return content.len != 0 and content[0] == '-' and (content.len == 1 or isWhite(content[1]));
    }

    /// `---` or `...` at the start of a line ends or starts a document.
    fn isDocMarker(c: Cur) bool {
        return c.indent == 0 and !c.tabbed and isForbidden(c.content);
    }

    /// A `:` that ends a key: followed by a blank or the end of the line.
    fn isValueIndicator(s: []const u8, i: usize) bool {
        return i < s.len and s[i] == ':' and (i + 1 == s.len or isWhite(s[i + 1]));
    }

    const Key = struct {
        /// The column the key starts in, for diagnostics.
        column: usize,
        text: []const u8,
        style: model.Style,
        /// What follows the `:` on its line.
        rest: []const u8,
    };

    const Node = union(enum) { key: Key, value: Value };

    /// Reads the node that starts `rest`, a suffix of the current line. With
    /// `keys`, a node followed by `:` on the line it starts on is a key, and
    /// only that much is consumed. Otherwise the whole value is consumed, with
    /// the lines it spans, and `trailing` is set.
    fn readNode(self: *Parser, rest_in: []const u8, parent: i64, keys: bool) Error!Node {
        const rest = std.mem.trimStart(u8, rest_in, " \t");
        switch (rest[0]) {
            '&', '*', '!' => return self.failHere(rest, "anchors, aliases and tags are not supported", error.Unsupported),
            '@', '`' => return self.errAt(rest, "a reserved indicator cannot start a scalar"),
            '%' => return self.errAt(rest, "a '%' cannot start a plain scalar"),
            '"', '\'' => {
                const first_line = self.pos;
                const g = try self.gatherQuoted(rest, parent);
                if (keys and self.pos == first_line) {
                    const after = std.mem.trimStart(u8, g.tail, " \t");
                    if (isValueIndicator(after, 0)) return .{ .key = .{
                        .column = self.columnOf(rest),
                        .text = try self.decodeQuoted(g.quoted),
                        .style = if (rest[0] == '"') .double else .single,
                        .rest = after[1..],
                    } };
                }
                return .{ .value = try self.quotedValue(g) };
            },
            '|', '>' => return .{ .value = try self.blockScalar(rest, parent) },
            '[', '{' => return .{ .value = try self.flowValue(rest, parent) },
            ',', ']', '}', '#' => return self.errAt(rest, "this indicator cannot start a plain scalar"),
            '-', '?' => if (rest.len == 1 or isWhite(rest[1])) {
                if (keys and rest[0] == '?') return self.failHere(rest, "complex keys are not supported", error.Unsupported);
                return self.errAt(rest, "this indicator cannot start a plain scalar here");
            },
            ':' => if (!keys and (rest.len == 1 or isWhite(rest[1])))
                return self.errAt(rest, "this indicator cannot start a plain scalar here"),
            else => {},
        }
        if (keys) {
            const content = splitPlain(rest).content;
            var i: usize = 0;
            while (i < content.len) : (i += 1) {
                if (!isValueIndicator(content, i)) continue;
                // The key may be empty (`: value`).
                const text = std.mem.trimEnd(u8, content[0..i], " \t");
                try self.checkPrintable(text);
                return .{ .key = .{ .column = self.columnOf(rest), .text = try self.a.dupe(u8, text), .style = .plain, .rest = rest[i + 1 ..] } };
            }
        }
        return .{ .value = try self.plainScalar(rest, parent) };
    }

    // ---- sequences -----------------------------------------------------------------

    /// The sequence whose first `-` is in column `indent` of the current line.
    fn sequence(self: *Parser, indent: usize) Error!Value {
        const seq = try self.a.create(Seq);
        seq.* = .{};
        var first = true;
        while (true) : (first = false) {
            if (!first) {
                try self.skipBlank();
                const c = (try self.cur()) orelse break;
                if (c.indent < indent or isDocMarker(c)) break;
                if (c.tabbed) return self.err("a tab cannot indent a line");
                if (c.indent > indent) return self.err("bad indentation of a sequence entry");
                if (!isSeqEntry(c.content)) break;
            }
            var before = try self.takeBefore();
            const raw = self.lines[self.pos];
            var j = indent + 1;
            while (j < raw.len and isWhite(raw[j])) j += 1;
            const rest = raw[j..];
            var item: Value = undefined;
            var after: ?[]const u8 = null;
            if (rest.len == 0 or rest[0] == '#') {
                after = if (rest.len != 0) try self.keepComment(std.mem.trimEnd(u8, rest, " \t")) else null;
                self.pos += 1;
                try self.skipBlank();
                const next = try self.cur();
                const present = next != null and next.?.indent > indent;
                item = try self.block(@intCast(indent), indent);
                // After a null item, pending comments belong to what follows.
                if (present) {
                    const found = try self.commentsAround(item, before, after);
                    before = found.before;
                    after = found.after;
                }
            } else {
                // The blanks before a collection on the dash's line indent it,
                // so they must be spaces.
                const tabbed = std.mem.indexOfScalar(u8, raw[indent..j], '\t') != null;
                item = try self.collectionOrNode(rest, @intCast(indent), j, tabbed, null, "a tab cannot indent a collection");
                after = self.takeTrailing();
            }
            try seq.items.append(self.a, item);
            try seq.comments.append(self.a, .{ .before = before, .after = after });
        }
        return .{ .seq = seq };
    }

    // ---- mappings --------------------------------------------------------------------

    /// The key that starts the line at column `indent`.
    fn nextKey(self: *Parser, indent: usize) Error!Key {
        const first_line = self.pos;
        switch (try self.readNode(self.lines[self.pos][indent..], @intCast(indent), true)) {
            .key => |key| return key,
            .value => {
                self.pos = first_line;
                return self.err("expected 'key:'");
            },
        }
    }

    /// The mapping whose keys are in column `indent`. The first one has been read.
    fn mapping(self: *Parser, indent: usize, first_key: Key) Error!Value {
        const map = try self.a.create(Map);
        map.* = .{};
        var key = first_key;
        while (true) {
            if (map.entries.contains(key.text)) return failAt(self.diag, self.pos + 1, key.column, "duplicate key", error.Syntax);
            var before = try self.takeBefore();
            const rest = std.mem.trimStart(u8, key.rest, " \t");
            var v: Value = undefined;
            var after: ?[]const u8 = null;
            if (rest.len == 0 or rest[0] == '#') {
                after = if (rest.len != 0) try self.keepComment(std.mem.trimEnd(u8, rest, " \t")) else null;
                self.pos += 1;
                try self.skipBlank();
                const next = try self.cur();
                const deeper = next != null and next.?.indent > indent;
                if (deeper) {
                    v = try self.block(@intCast(indent), indent);
                } else if (next != null and next.?.indent == indent and !next.?.tabbed and isSeqEntry(next.?.content)) {
                    try self.enter();
                    defer self.depth -= 1;
                    v = try self.sequence(indent);
                } else v = null_scalar;
                // After a null value, pending comments belong to what follows.
                if (v != .scalar or deeper) {
                    const found = try self.commentsAround(v, before, after);
                    before = found.before;
                    after = found.after;
                }
            } else {
                v = (try self.readNode(rest, @intCast(indent), false)).value;
                after = self.takeTrailing();
            }
            try map.entries.put(self.a, key.text, v);
            try map.noteKeyStyle(self.a, key.text, key.style);
            if (before.len != 0 or after != null) try map.comments.put(self.a, key.text, .{ .before = before, .after = after });

            try self.skipBlank();
            const c = (try self.cur()) orelse break;
            if (c.indent < indent or isDocMarker(c)) break;
            if (c.tabbed) return self.err("a tab cannot indent a line");
            if (c.indent > indent) return self.err("bad indentation of a mapping entry");
            if (isSeqEntry(c.content)) break;
            key = try self.nextKey(indent);
        }
        return .{ .map = map };
    }

    // ---- scalars and flow collections ---------------------------------------------------

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
        const buf = &self.scratch;
        buf.clearRetainingCapacity();
        try buf.appendSlice(self.gpa, first);
        var scan: QuoteScan = .{ .quote = first[0] };
        var line = first;
        const first_line = self.pos;
        const column = self.columnOf(first);
        const end = while (true) {
            if (scan.find(buf.items)) |e| break e;
            self.pos += 1;
            if (self.pos >= self.lines.len) return failAt(self.diag, first_line + 1, column, "unterminated quoted scalar", error.Syntax);
            line = self.lines[self.pos];
            try self.checkContinuation(line, parent);
            try buf.append(self.gpa, '\n');
            try buf.appendSlice(self.gpa, line);
        };
        self.quote_column = column;
        return .{
            .quoted = try self.a.dupe(u8, buf.items[0..end]),
            .tail = line[line.len - (buf.items.len - end) ..],
        };
    }

    /// The value of the quoted scalar `g`, whose last line is the current one.
    fn quotedValue(self: *Parser, g: Gathered) Error!Value {
        const tail = splitPlain(g.tail);
        if (g.tail.len != 0 and g.tail[0] == '#') return self.errAt(g.tail, "a comment needs a blank before '#'");
        if (std.mem.trim(u8, tail.content, " \t").len != 0) return self.errAt(std.mem.trimStart(u8, g.tail, " \t"), "unexpected text after a quoted scalar");
        self.trailing = if (tail.comment) |t| try self.keepComment(t) else null;
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
        const sc = splitPlain(first);
        var out: std.ArrayList(u8) = .empty;
        const head = std.mem.trimEnd(u8, sc.content, " \t");
        if (hasMappingIndicator(head)) return self.errAt(first, "':' followed by a blank cannot appear in a plain scalar");
        try self.checkPrintable(head);
        if (sc.comment) |t| try self.checkPrintable(t);
        try out.appendSlice(self.a, head);
        var comment = sc.comment;
        self.pos += 1;
        // Continuation lines: more indented than the parent, until a comment.
        // Indicators such as `- ` or a quote are plain text on these lines.
        while (comment == null) {
            var j = self.pos;
            var blanks: usize = 0;
            while (j < self.lines.len and isBlank(self.lines[j])) : (j += 1) blanks += 1;
            if (j >= self.lines.len) break;
            const l = self.lines[j];
            const ind = indentOf(l);
            if (@as(i64, @intCast(ind)) <= parent or l[ind] == '#' or isForbidden(l)) break;
            const part = splitPlain(l[ind..]);
            const t = std.mem.trim(u8, part.content, " \t");
            // Only a comment line leaves nothing here.
            if (t.len == 0) break;
            if (hasMappingIndicator(t)) return self.err("unexpected content after a plain scalar (bad indentation?)");
            self.pos = j;
            try self.checkPrintable(t);
            if (part.comment) |text| try self.checkPrintable(text);
            if (blanks == 0) try out.append(self.a, ' ') else try out.appendNTimes(self.a, '\n', blanks);
            try out.appendSlice(self.a, t);
            comment = part.comment;
            self.pos = j + 1;
        }
        // Checked above, on the line where it stands.
        self.trailing = if (comment) |t| try self.a.dupe(u8, t) else null;
        const text = out.items;
        return .{ .scalar = .{ .text = text, .style = .plain, .kind = model.resolve(text) } };
    }

    fn hasMappingIndicator(s: []const u8) bool {
        for (s, 0..) |c, i| {
            if (c == ':' and (i + 1 == s.len or isWhite(s[i + 1]))) return true;
        }
        return false;
    }

    fn blockScalar(self: *Parser, header: []const u8, parent: i64) Error!Value {
        const sc = splitPlain(header);
        const h = std.mem.trim(u8, sc.content, " \t");
        const literal = h[0] == '|';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: usize = 0;
        // At most one indentation digit and one chomping sign, in either order.
        for (h[1..]) |c| switch (c) {
            '-', '+' => {
                if (chomp != .clip) return self.err("bad block scalar header");
                chomp = if (c == '-') .strip else .keep;
            },
            '1'...'9' => {
                if (explicit != 0) return self.err("bad block scalar header");
                explicit = c - '0';
            },
            else => return self.err("bad block scalar header"),
        };
        self.trailing = if (sc.comment) |t| try self.keepComment(t) else null;
        self.pos += 1;

        // The body is indented past the parent; its first line with anything
        // but spaces sets how far, unless an indicator says.
        const floor: usize = if (parent < 0) 0 else @intCast(parent + 1);
        var content_indent: ?usize = null;
        if (explicit != 0) content_indent = (if (parent < 0) 0 else @as(usize, @intCast(parent))) + explicit;
        var leading_spaces: usize = 0;
        var end = self.pos;
        var last_content = self.pos; // one past the last line that is not empty
        while (end < self.lines.len) : (end += 1) {
            const l = self.lines[end];
            if (isForbidden(l)) break;
            const spaces = indentOf(l);
            if (spaces == l.len) {
                // Only spaces: content if it goes past the indentation.
                if (content_indent) |n| {
                    if (spaces > n) last_content = end + 1;
                } else leading_spaces = @max(leading_spaces, spaces);
                continue;
            }
            const n = content_indent orelse blk: {
                if (spaces < floor) {
                    if (isBlank(l)) return self.fail("a tab cannot indent a line", error.Syntax);
                    break;
                }
                if (leading_spaces > spaces) return self.err("an empty line is indented more than the first line of the block scalar");
                content_indent = spaces;
                break :blk spaces;
            };
            if (spaces < n) {
                if (isBlank(l)) return self.err("a tab cannot indent a line");
                break;
            }
            last_content = end + 1;
        }
        // With no content at all, every line is empty.
        const ci = content_indent orelse std.math.maxInt(usize);
        const body_end = if (chomp == .keep) end else last_content;
        var lines: std.ArrayList([]const u8) = .empty;
        var i = self.pos;
        while (i < body_end) : (i += 1) {
            const l = self.lines[i];
            const text = if (l.len > ci) l[ci..] else "";
            self.pos = i;
            try self.checkPrintable(text);
            try lines.append(self.a, text);
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
        // Without a comment after the closing bracket, the last one inside is
        // moved there rather than lost.
        self.trailing = flow.last_comment;
        if (rest.len != 0) {
            if (rest[0] == ':') return self.failHere(rest, "a collection as a key is not supported", error.Unsupported);
            if (rest[0] != '#' or rest.len == tail.len) return self.errAt(rest, "unexpected text after a flow collection");
            self.trailing = try self.keepComment(std.mem.trimEnd(u8, rest, " \t"));
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
                keep = out.items.len;
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
            if (i >= body.len) return self.escapeError(q, i, "bad escape in a double-quoted scalar");
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
                    if (i + 1 + n > body.len) return self.escapeError(q, i, "bad escape in a double-quoted scalar");
                    const digits = body[i + 1 .. i + 1 + n];
                    // `parseInt` alone would also take a sign and underscores.
                    for (digits) |d| if (!std.ascii.isHex(d)) return self.escapeError(q, i, "bad escape in a double-quoted scalar");
                    const cp = std.fmt.parseInt(u21, digits, 16) catch return self.escapeError(q, i, "bad escape in a double-quoted scalar");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return self.escapeError(q, i, "bad escape in a double-quoted scalar");
                    try out.appendSlice(self.a, buf[0..len]);
                    i += n;
                },
                '\n' => {
                    // An escaped line break joins the lines without a space,
                    // keeping the blanks before the backslash. Each empty line
                    // after it is still a line feed.
                    while (i + 1 < body.len) : (i += 1) {
                        if (body[i + 1] == '\n') {
                            try out.append(self.a, '\n');
                        } else if (!isWhite(body[i + 1])) break;
                    }
                },
                else => return self.escapeError(q, i, "unknown escape in a double-quoted scalar"),
            }
            keep = out.items.len;
        }
        return out.items;
    }

    /// Reports the bad escape whose backslash is just before byte `i` of the
    /// body of `q`, a quoted scalar that ends on the current line.
    fn escapeError(self: *Parser, q: []const u8, i: usize, msg: []const u8) Error {
        const at = @min(i, q.len - 1); // the backslash, as an offset into `q`
        const line = self.pos + 1 - std.mem.count(u8, q[at..], "\n");
        const column = if (std.mem.lastIndexOfScalar(u8, q[0..at], '\n')) |nl| at - nl else self.quote_column + at;
        return failAt(self.diag, line, column, msg, error.Syntax);
    }

    /// Length of `s` without trailing blanks.
    fn trimWs(s: []const u8) usize {
        var n = s.len;
        while (n > 0 and (s[n - 1] == ' ' or s[n - 1] == '\t')) n -= 1;
        return n;
    }
};

/// Reads a flow collection straight from the source lines: `line` is line
/// `p.pos` and `i` the next byte in it. Comments inside the collection have no
/// item to belong to; only the last one is remembered.
const Flow = struct {
    p: *Parser,
    line: []const u8,
    i: usize,
    /// Indent of the enclosing block node; further lines must go past it.
    parent: i64,
    last_comment: ?[]const u8 = null,

    /// A syntax error at the cursor.
    fn err(self: *Flow, msg: []const u8) Error {
        const line = @min(self.p.pos, self.p.lines.len - 1);
        return failAt(self.p.diag, line + 1, @min(self.i, self.line.len) + 1, msg, error.Syntax);
    }

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
                self.last_comment = try self.p.keepComment(std.mem.trimEnd(u8, self.line[self.i..], " \t"));
            }
            self.p.pos += 1;
            if (self.p.pos >= self.p.lines.len) return self.err("unterminated flow collection");
            self.line = self.p.lines[self.p.pos];
            self.i = 0;
            const body = std.mem.trimStart(u8, self.line, " \t");
            // Comment lines may be indented any amount.
            if (body.len != 0 and body[0] != '#' and !self.closesAtParent(self.line))
                try self.p.checkContinuation(self.line, self.parent);
        }
    }

    /// A deliberate departure from YAML 1.2.2, which wants this line indented
    /// further: a closing bracket may stand in the parent's own column.
    ///
    ///     os: [
    ///       linux,
    ///     ]
    ///
    /// This is common in real files, and libyaml-based readers accept it.
    fn closesAtParent(self: *const Flow, line: []const u8) bool {
        const column = Parser.indentOf(line);
        return column == self.parent and column < line.len and (line[column] == ']' or line[column] == '}');
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
        const c = self.peek() orelse return self.err("expected a value in a flow collection");
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
            ',', ']', '}' => return self.err("a flow collection entry cannot be empty"),
            '|', '>', '%', '@', '`', '#' => return self.err("this character cannot start a value in a flow collection"),
            '?', ':', '-' => {
                if (self.separatorFollows()) {
                    if (c == '?') return self.p.unsupported("complex keys are not supported");
                    return self.err("this indicator cannot start a value in a flow collection");
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
        // Gathered outside the arena and copied once, at its exact size: a
        // large collection has very many short scalars.
        const out = &self.p.scratch;
        out.clearRetainingCapacity();
        const head = self.plainLine();
        try self.p.checkPrintable(head);
        try out.appendSlice(self.p.gpa, head);
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
            if (blanks == 0) try out.append(self.p.gpa, ' ') else try out.appendNTimes(self.p.gpa, '\n', blanks);
            self.p.pos = j;
            self.line = next;
            self.i = next.len - body.len;
            const part = self.plainLine();
            try self.p.checkPrintable(part);
            try out.appendSlice(self.p.gpa, part);
        }
        const text = try self.p.a.dupe(u8, out.items);
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
        if (!in_mapping and self.p.pos != first_line) return self.err("a key in a flow sequence must be on one line");
        self.i += 1;
        try self.skip();
        const c = self.peek().?;
        const value = if (c == ',' or c == ']' or c == '}') null_scalar else try self.node();
        return .{ .key = key, .value = value };
    }

    fn put(self: *Flow, m: *Map, key: Value, value: Value) Error!void {
        const s = switch (key) {
            .scalar => |s| s,
            else => return self.p.unsupported("a collection as a key is not supported"),
        };
        if (m.entries.contains(s.text)) return self.err("duplicate key");
        try m.entries.put(self.p.a, s.text, value);
        try m.noteKeyStyle(self.p.a, s.text, s.style);
    }

    /// Consumes the `,` after an entry, or stops before the closing bracket.
    fn separator(self: *Flow, close: u8, msg: []const u8) Error!void {
        try self.skip();
        if (self.peek() == ',') {
            self.i += 1;
        } else if (self.peek() != close) return self.err(msg);
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
                // The pair is a mapping around its value: one level more than
                // was counted while the value was read.
                if (self.p.depth + 1 + levelsIn(v) > self.p.options.max_depth) return self.p.fail("nesting too deep", error.LimitExceeded);
                const pair = try self.p.a.create(Map);
                pair.* = .{ .flow = true };
                try self.put(pair, e.key, v);
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
            try self.put(m, e.key, e.value orelse null_scalar);
            try self.separator('}', "expected ',' or '}' in a flow mapping");
        }
    }
};

/// How many collections are nested in `v`, itself included.
fn levelsIn(v: Value) usize {
    var deepest: usize = 0;
    switch (v) {
        .scalar => return 0,
        .seq => |q| for (q.items.items) |item| {
            deepest = @max(deepest, levelsIn(item));
        },
        .map => |m| for (m.entries.values()) |item| {
            deepest = @max(deepest, levelsIn(item));
        },
    }
    return 1 + deepest;
}

const CommentSplit = struct { content: []const u8, comment: ?[]const u8 };

/// Splits a trailing `# comment` off text that holds no quoted scalar: a plain
/// scalar, or what follows a value. A `#` starts a comment only at the start of
/// `s` or after a blank.
fn splitPlain(s: []const u8) CommentSplit {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return .{ .content = s[0..i], .comment = std.mem.trimEnd(u8, s[i..], " \t") };
        }
    }
    return .{ .content = s, .comment = null };
}

/// `splitPlain` for a whole line, which may start with a quoted scalar in which
/// a `#` is text. It is only used to see what a line starts with.
fn splitComment(s: []const u8) CommentSplit {
    const start = s.len - std.mem.trimStart(u8, s, " \t").len;
    if (start == s.len or (s[start] != '"' and s[start] != '\'')) return splitPlain(s);
    const end = start + (scanQuoted(s[start..]) orelse return .{ .content = s, .comment = null });
    // A comment needs a blank before it, so the closing quote cannot be followed
    // by one directly.
    var i = end + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '#' and (s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return .{ .content = s[0..i], .comment = std.mem.trimEnd(u8, s[i..], " \t") };
        }
    }
    return .{ .content = s, .comment = null };
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
