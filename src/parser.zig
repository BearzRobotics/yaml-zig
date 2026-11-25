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
const Anchor = model.Anchor;

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
    /// The directive lines above `---`, as written.
    directives: []const []const u8 = &.{},
    /// The document was closed with `...`.
    explicit_end: bool = false,
};

const null_scalar: Value = .{ .scalar = .{ .text = "", .style = .plain, .kind = .null } };

/// Reads the documents of a stream one at a time. Each can go into an arena of
/// its own.
pub const Reader = struct {
    parser: Parser,
    lines: std.ArrayList([]const u8),

    /// `source` must stay as it is while the reader is used.
    pub fn init(gpa: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) Error!Reader {
        if (source.len > options.max_bytes) return failAt(diag, 1, 1, "input too large", error.LimitExceeded);
        if (!std.unicode.utf8ValidateSlice(source)) return failAt(diag, 1, 1, "invalid UTF-8", error.InvalidUtf8);
        var text = source;
        if (std.mem.startsWith(u8, text, byte_order_mark)) text = text[byte_order_mark.len..];

        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(gpa);
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
        return .{
            .parser = .{ .a = undefined, .gpa = gpa, .lines = lines.items, .options = options, .diag = diag },
            .lines = lines,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.parser.pending.deinit(self.parser.gpa);
        self.parser.scratch.deinit(self.parser.gpa);
        self.lines.deinit(self.parser.gpa);
    }

    /// The next document, allocated in `arena`, or null at the end of the
    /// stream.
    pub fn next(self: *Reader, arena: Allocator) Error!?Result {
        self.parser.a = arena;
        return self.parser.document();
    }

    /// The comments left over at the end of a stream with no document to
    /// take them.
    pub fn leftover(self: *Reader, arena: Allocator) Error![]const []const u8 {
        self.parser.a = arena;
        return self.parser.footerLines(self.parser.pending.items.len);
    }
};

const byte_order_mark = "\xEF\xBB\xBF";

/// Reads a stream that holds at most one document.
pub fn parse(gpa: Allocator, arena: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) Error!Result {
    var reader = try Reader.init(gpa, source, options, diag);
    defer reader.deinit();
    const result = try reader.next(arena) orelse
        return .{ .root = null_scalar, .indent = 2, .explicit_start = false, .header = &.{}, .footer = try reader.leftover(arena) };
    // Anything further would be another document.
    try reader.parser.skipBlank();
    if (reader.parser.pos < reader.parser.lines.len)
        return reader.parser.unsupported("several documents: read them with Stream.parse");
    return result;
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
    /// Comment and blank lines not yet given to anything. They point into the
    /// source: which document's arena they belong in is not yet known.
    pending: std.ArrayList([]const u8) = .empty,
    /// At the start of the stream or after `...`: directives may follow.
    after_end: bool = true,
    /// Set when a node turned out to be empty after lines of properties: how
    /// many pending comment lines stood above them. The rest follow the node.
    own_pending: ?usize = null,
    /// The current document's anchors; a name may be given again.
    anchors: std.StringHashMapUnmanaged(*Anchor) = .empty,
    /// The current document's `%TAG` handles and their prefixes.
    handles: std.StringHashMapUnmanaged([]const u8) = .empty,
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
                try self.checkPrintable(body);
                try self.pending.append(self.gpa, body);
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
        return self.dupeLines(self.pending.items);
    }

    fn dupeLines(self: *Parser, lines: []const []const u8) Error![]const []const u8 {
        if (lines.len == 0) return &.{};
        const out = try self.a.alloc([]const u8, lines.len);
        for (lines, out) |line, *o| o.* = try self.a.dupe(u8, line);
        return out;
    }

    /// Takes the first `count` pending lines as a footer, without the empty
    /// lines at its end.
    fn footerLines(self: *Parser, count: usize) Error![]const []const u8 {
        var n = count;
        while (n > 0 and self.pending.items[n - 1].len == 0) n -= 1;
        const footer = try self.dupeLines(self.pending.items[0..n]);
        self.pending.replaceRangeAssumeCapacity(0, count, &.{});
        return footer;
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
            .alias => true,
        };
    }

    /// The comments of an item whose value starts below its `key:` or `-` line.
    /// `before` and `line_comment` were found above and on that line. If the
    /// value is one node, comments between the line and the value, and after
    /// the value, have no other owner than this item.
    fn commentsAround(self: *Parser, v: Value, before: []const []const u8, line_comment: ?[]const u8) Error!Comments {
        if (!isOneNode(v)) return .{ .before = before, .after = line_comment };
        const between = try self.takeAbove();
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

    /// The next document of the stream, or null if there is none.
    fn document(self: *Parser) Error!?Result {
        var res: Result = .{ .root = null_scalar, .indent = 2, .explicit_start = false, .header = &.{}, .footer = &.{} };
        self.step = 0;

        // The prefix: `...` lines left over, and directives.
        var directives: std.ArrayList([]const u8) = .empty;
        var seen_yaml = false;
        self.handles = .empty;
        self.anchors = .empty;
        const first = while (true) {
            // A byte order mark may start any document.
            if (self.after_end and self.pos < self.lines.len and std.mem.startsWith(u8, self.lines[self.pos], byte_order_mark))
                try self.dropByteOrderMark();
            try self.skipBlank();
            const c = (try self.cur()) orelse {
                if (directives.items.len != 0) return self.err("directives must be followed by '---'");
                return null;
            };
            if (isDocMarker(c) and c.content[0] == '.') {
                if (directives.items.len != 0) return self.err("directives must be followed by '---'");
                try self.endMarker(c);
                self.after_end = true;
            } else if (self.after_end and c.indent == 0 and !c.tabbed and c.content.len != 0 and c.content[0] == '%') {
                const line = std.mem.trimEnd(u8, self.lines[self.pos], " \t");
                switch (model.parseDirective(line) catch return self.err("bad directive")) {
                    .yaml => {
                        if (seen_yaml) return self.err("a second %YAML directive");
                        seen_yaml = true;
                    },
                    .tag => |t| {
                        const slot = try self.handles.getOrPut(self.a, try self.a.dupe(u8, t.handle));
                        if (slot.found_existing) return self.err("a second %TAG directive for one handle");
                        slot.value_ptr.* = try self.a.dupe(u8, t.prefix);
                    },
                    .reserved => {},
                }
                try directives.append(self.a, try self.a.dupe(u8, line));
                self.pos += 1;
            } else break c;
        };
        res.directives = directives.items;
        self.after_end = false;

        // Content that shares its line with `---`.
        var inline_root: ?[]const u8 = null;
        if (isDocMarker(first)) {
            res.explicit_start = true;
            res.header = try self.dupeLines(self.pending.items);
            self.pending.clearRetainingCapacity();
            const rest = std.mem.trimStart(u8, self.lines[self.pos][3..], " \t");
            if (rest.len == 0 or rest[0] == '#') {
                if (rest.len != 0) res.start_comment = try self.keepComment(std.mem.trimEnd(u8, rest, " \t"));
                self.pos += 1;
            } else inline_root = rest;
        } else if (directives.items.len != 0) return self.err("directives must be followed by '---'");
        var props: Props = .{};
        var props_comment: ?[]const u8 = null;
        if (inline_root) |rest| {
            props = try self.takeProps(rest);
            if (props.any() and endsLine(props.rest)) {
                props_comment = try self.commentOn(props.rest);
                inline_root = null;
                self.pos += 1;
            }
        }
        if (inline_root != null) {
            const on_marker_line = "a block collection cannot start on the '---' line";
            if (isSeqEntry(props.rest)) return self.err(on_marker_line);
            res.root = switch (try self.readNode(props.rest, -1, true)) {
                .value => |v| v,
                .key => return self.err(on_marker_line),
            };
            try self.apply(&res.root, props);
            res.root_comments = .{ .after = self.takeTrailing() };
        } else {
            try self.skipBlank();
            const present = if (try self.cur()) |c| !isDocMarker(c) else false;
            res.root = try self.block(-1, null, props, false);
            if (present and isOneNode(res.root)) {
                res.root_comments.before = try self.takeAbove();
                res.root_comments.after = self.takeTrailing();
            }
        }
        if (props_comment) |c| {
            // A comment after the root's properties, above the root itself.
            if (res.root_comments.after == null and isOneNode(res.root)) {
                res.root_comments.after = c;
            } else res.header = try std.mem.concat(self.a, []const u8, &.{ res.header, &.{c} });
        }
        try self.skipBlank();
        // Comments up to here, and on a first `...`, end this document. Any
        // after that go to the next one, if there is one.
        var own = self.pending.items.len;
        if (try self.cur()) |c| {
            if (!isDocMarker(c)) return self.err("unexpected content or bad indentation");
            if (c.content[0] == '-') {
                // Comments above the next `---` are that document's header.
                own = 0;
            } else {
                res.explicit_end = true;
                self.after_end = true;
                try self.endMarker(c);
                own = self.pending.items.len;
                while (true) {
                    try self.skipBlank();
                    const end = (try self.cur()) orelse {
                        own = self.pending.items.len;
                        break;
                    };
                    if (!isDocMarker(end) or end.content[0] != '.') break;
                    try self.endMarker(end);
                }
            }
        }
        res.footer = try self.footerLines(own);
        if (self.step != 0) res.indent = self.step;
        return res;
    }

    /// Consumes the `...` line `c`. The marker is optional and is not written
    /// back, so its comment becomes a comment line.
    fn endMarker(self: *Parser, c: Cur) Error!void {
        if (c.content.len != 3) return self.err("unexpected content after '...'");
        if (splitPlain(self.lines[self.pos][3..]).comment) |t| {
            try self.checkPrintable(t);
            try self.pending.append(self.gpa, t);
        }
        self.pos += 1;
    }

    fn dropByteOrderMark(self: *Parser) Error!void {
        // `lines` is shared and read-only; the line is only read from here on.
        const lines = @constCast(self.lines);
        lines[self.pos] = lines[self.pos][byte_order_mark.len..];
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
    /// indentation says something about the document's step. `outer` holds the
    /// properties already read for it. With `sequence_at_parent`, as for a
    /// mapping's value, a sequence may also stand in the parent's column.
    fn block(self: *Parser, parent: i64, under: ?usize, outer: Props, sequence_at_parent: bool) Error!Value {
        try self.skipBlank();
        const c = (try self.cur()) orelse return self.emptyNode(outer);
        if (isDocMarker(c)) return self.emptyNode(outer);
        if (@as(i64, @intCast(c.indent)) <= parent) {
            if (!sequence_at_parent or c.indent != parent or c.tabbed or !isSeqEntry(c.content)) return self.emptyNode(outer);
            try self.enter();
            defer self.depth -= 1;
            var v = try self.sequence(c.indent);
            try self.apply(&v, outer);
            return v;
        }
        const rest = std.mem.trimStart(u8, self.lines[self.pos][c.indent..], " \t");
        const props = try self.takeProps(rest);
        if (props.any() and endsLine(props.rest)) {
            // Properties on a line of their own belong to what follows. A node
            // has at most one of each, so this does not recurse far.
            if (try self.commentOn(props.rest)) |text| try self.pending.append(self.gpa, text);
            const both = try self.merge(outer, props);
            self.pos += 1;
            const above = self.pending.items.len;
            try self.skipBlank();
            if (!try self.nodeFollows(parent, sequence_at_parent)) {
                self.own_pending = above;
                return self.emptyNode(both);
            }
            return self.block(parent, under, both, sequence_at_parent);
        }
        return self.collectionOrNode(rest, props, outer, parent, c.indent, c.tabbed, under, "a tab cannot indent a line");
    }

    /// Whether the current line is part of a node nested under `parent`.
    fn nodeFollows(self: *Parser, parent: i64, sequence_at_parent: bool) Error!bool {
        const c = (try self.cur()) orelse return false;
        if (isDocMarker(c)) return false;
        if (@as(i64, @intCast(c.indent)) > parent) return true;
        return sequence_at_parent and c.indent == parent and !c.tabbed and isSeqEntry(c.content);
    }

    /// The pending comments that stand above a node just read.
    fn takeAbove(self: *Parser) Error![]const []const u8 {
        const count = self.own_pending orelse return self.takeBefore();
        self.own_pending = null;
        self.seen_item = true;
        const above = try self.dupeLines(self.pending.items[0..count]);
        self.pending.replaceRangeAssumeCapacity(0, count, &.{});
        return above;
    }

    /// What starts at `rest`, in column `column` of the current line, where a
    /// block collection may start. One cannot if tabs lead up to it. `props`
    /// are the properties at the start of `rest`; `outer` those from before.
    fn collectionOrNode(self: *Parser, rest: []const u8, props: Props, outer: Props, parent: i64, column: usize, tabbed: bool, under: ?usize, tab_message: []const u8) Error!Value {
        if (isSeqEntry(props.rest)) {
            if (props.any()) return self.errAt(props.rest, "a block sequence cannot start on its properties' line");
            if (tabbed) return self.err(tab_message);
            try self.enterAt(rest);
            defer self.depth -= 1;
            self.learnStep(column, under);
            var v = try self.sequence(column);
            try self.apply(&v, outer);
            return v;
        }
        switch (try self.readNode(props.rest, parent, true)) {
            .value => |value| {
                var v = value;
                try self.apply(&v, try self.merge(outer, props));
                return v;
            },
            .key => |found| {
                if (tabbed) return self.err(tab_message);
                // Properties on the key's line are the key's; those from the
                // lines above are the mapping's.
                var key = found;
                key.column = self.columnOf(rest);
                try self.apply(&key.value, props);
                try self.enterAt(rest);
                defer self.depth -= 1;
                self.learnStep(column, under);
                var v = try self.mapping(column, key);
                try self.apply(&v, outer);
                return v;
            },
        }
    }

    // ---- node properties -------------------------------------------------------------

    const Props = struct {
        tag: ?[]const u8 = null,
        anchor: ?*Anchor = null,
        /// What follows the properties on their line.
        rest: []const u8 = "",

        fn any(self: Props) bool {
            return self.tag != null or self.anchor != null;
        }
    };

    /// Reads the properties at the start of `rest`, if any.
    fn takeProps(self: *Parser, rest: []const u8) Error!Props {
        var props: Props = .{ .rest = rest };
        while (props.rest.len != 0) {
            switch (props.rest[0]) {
                '&' => {
                    if (props.anchor != null) return self.errAt(props.rest, "a node cannot have two anchors");
                    const name = anchorName(props.rest[1..]);
                    const after = props.rest[1 + name.len ..];
                    if (name.len == 0 or (after.len != 0 and !isWhite(after[0]))) return self.errAt(props.rest, "bad anchor");
                    props.anchor = try self.defineAnchor(name);
                    props.rest = std.mem.trimStart(u8, after, " \t");
                },
                '!' => {
                    if (props.tag != null) return self.errAt(props.rest, "a node cannot have two tags");
                    const tag = try self.readTag(props.rest, false) orelse return self.errAt(props.rest, "bad tag");
                    props.tag = tag.name;
                    props.rest = std.mem.trimStart(u8, props.rest[tag.len..], " \t");
                },
                else => break,
            }
        }
        return props;
    }

    /// The name that starts `s`, which follows `&` or `*`.
    fn anchorName(s: []const u8) []const u8 {
        var end: usize = 0;
        while (end < s.len and !isWhite(s[end]) and std.mem.findScalar(u8, ",[]{}", s[end]) == null) end += 1;
        return s[0..end];
    }

    /// An anchor takes effect where it is written: the node it is on, which
    /// has yet to be read, may hold aliases of itself.
    fn defineAnchor(self: *Parser, name: []const u8) Error!*Anchor {
        try self.checkPrintable(name);
        const a = try self.a.create(Anchor);
        a.* = .{ .name = try self.a.dupe(u8, name), .value = null_scalar, .complete = false };
        try self.anchors.put(self.a, a.name, a);
        return a;
    }

    /// The anchor an alias named `name` refers to.
    fn lookupAnchor(self: *Parser, name: []const u8) ?*Anchor {
        return self.anchors.get(name);
    }

    const Tag = struct { name: []const u8, len: usize };

    /// The tag that starts `s`, resolved to its full name, or null if it is
    /// badly formed or its handle is unknown. It must be followed by a blank,
    /// the end of the line or, `in_flow`, what ends a flow entry.
    fn readTag(self: *Parser, s: []const u8, in_flow: bool) Error!?Tag {
        var end: usize = 1;
        var name: []const u8 = undefined;
        if (s.len > 1 and s[1] == '<') {
            // Verbatim: taken as it is.
            const close = std.mem.indexOfScalar(u8, s, '>') orelse return null;
            const uri = s[2..close];
            if (!model.isVerbatimTag(uri)) return null;
            name = try self.a.dupe(u8, uri);
            end = close + 1;
        } else {
            while (end < s.len and !isWhite(s[end]) and std.mem.findScalar(u8, ",[]{}", s[end]) == null) end += 1;
            const token = s[0..end];
            if (token.len == 1) {
                name = "!";
            } else {
                // `!!suffix`, `!name!suffix` or `!suffix`.
                const second = std.mem.indexOfScalarPos(u8, token, 1, '!');
                const handle = if (second) |i| token[0 .. i + 1] else token[0..1];
                const suffix = token[handle.len..];
                if (suffix.len == 0 or !model.isTagHandle(handle)) return null;
                const prefix = self.handles.get(handle) orelse if (std.mem.eql(u8, handle, "!!"))
                    model.core_prefix
                else if (std.mem.eql(u8, handle, "!"))
                    "!"
                else
                    return null;
                name = try model.expandTag(self.a, prefix, suffix) orelse return null;
            }
        }
        if (end < s.len and !isWhite(s[end]) and !(in_flow and std.mem.findScalar(u8, ",]}", s[end]) != null)) return null;
        return .{ .name = name, .len = end };
    }

    fn merge(self: *Parser, outer: Props, inner: Props) Error!Props {
        if (outer.tag != null and inner.tag != null) return self.err("a node cannot have two tags");
        if (outer.anchor != null and inner.anchor != null) return self.err("a node cannot have two anchors");
        return .{ .tag = outer.tag orelse inner.tag, .anchor = outer.anchor orelse inner.anchor, .rest = inner.rest };
    }

    /// Gives a node that has just been read its properties.
    fn apply(self: *Parser, v: *Value, props: Props) Error!void {
        if (!props.any()) return;
        switch (v.*) {
            .scalar => |*s| {
                if (props.tag) |tag| {
                    s.tag = tag;
                    s.kind = model.kindOf(tag, s.style, s.text);
                }
                s.anchor = props.anchor orelse s.anchor;
            },
            .seq => |q| {
                q.tag = props.tag orelse q.tag;
                q.anchor = props.anchor orelse q.anchor;
            },
            .map => |m| {
                m.tag = props.tag orelse m.tag;
                m.anchor = props.anchor orelse m.anchor;
            },
            .alias => return self.err("an alias cannot have properties"),
        }
        if (props.anchor) |a| {
            a.value = v.*;
            a.complete = true;
        }
    }

    /// A key's hash is taken as it goes in, so what it refers to must be whole.
    fn checkKey(self: *Parser, key: Value, column: usize) Error!void {
        if (key == .alias and !key.alias.complete)
            return failAt(self.diag, self.pos + 1, column, "a key cannot be an alias of a node that holds it", error.Unsupported);
    }

    /// A node with no content, which may still have properties.
    fn emptyNode(self: *Parser, props: Props) Error!Value {
        var v = null_scalar;
        try self.apply(&v, props);
        return v;
    }

    /// Whether nothing but a comment is left of a line.
    fn endsLine(rest: []const u8) bool {
        return rest.len == 0 or rest[0] == '#';
    }

    /// The comment that `endsLine` found, checked but not copied.
    fn commentOn(self: *Parser, rest: []const u8) Error!?[]const u8 {
        if (rest.len == 0) return null;
        const text = std.mem.trimEnd(u8, rest, " \t");
        try self.checkPrintable(text);
        return try self.a.dupe(u8, text);
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
        value: Value,
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
            '*' => {
                const name = anchorName(rest[1..]);
                const tail = rest[1 + name.len ..];
                const target = if (name.len != 0) self.lookupAnchor(name) else null;
                const anchor = target orelse return self.errAt(rest, "an alias needs an anchor above it");
                const after = std.mem.trimStart(u8, tail, " \t");
                if (keys and isValueIndicator(after, 0))
                    return .{ .key = .{ .column = self.columnOf(rest), .value = .{ .alias = anchor }, .rest = after[1..] } };
                if (!endsLine(after) or (after.len != 0 and after.len == tail.len)) return self.errAt(rest, "unexpected text after an alias");
                self.trailing = try self.commentOn(after);
                self.pos += 1;
                return .{ .value = .{ .alias = anchor } };
            },
            '&', '!' => return self.errAt(rest, "properties cannot stand here"),
            '@', '`' => return self.errAt(rest, "a reserved indicator cannot start a scalar"),
            '%' => return self.errAt(rest, "a '%' cannot start a plain scalar"),
            '"', '\'' => {
                const first_line = self.pos;
                const g = try self.gatherQuoted(rest, parent);
                if (keys and self.pos == first_line) {
                    const after = std.mem.trimStart(u8, g.tail, " \t");
                    if (isValueIndicator(after, 0)) return .{ .key = .{
                        .column = self.columnOf(rest),
                        .value = .{ .scalar = .{ .text = try self.decodeQuoted(g.quoted), .style = if (rest[0] == '"') .double else .single, .kind = .string } },
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
                const found = std.mem.trimEnd(u8, content[0..i], " \t");
                try self.checkPrintable(found);
                const text = try self.a.dupe(u8, found);
                return .{ .key = .{ .column = self.columnOf(rest), .value = .{ .scalar = .{ .text = text, .style = .plain, .kind = model.resolve(text) } }, .rest = rest[i + 1 ..] } };
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
            const props = try self.takeProps(rest);
            var item: Value = undefined;
            var after: ?[]const u8 = null;
            if (endsLine(props.rest)) {
                after = try self.commentOn(props.rest);
                self.pos += 1;
                try self.skipBlank();
                const next = try self.cur();
                const present = next != null and next.?.indent > indent;
                item = try self.block(@intCast(indent), indent, props, false);
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
                item = try self.collectionOrNode(rest, props, .{}, @intCast(indent), j, tabbed, null, "a tab cannot indent a collection");
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
        const rest = std.mem.trimStart(u8, self.lines[self.pos][indent..], " \t");
        const props = try self.takeProps(rest);
        if (!endsLine(props.rest)) {
            switch (try self.readNode(props.rest, @intCast(indent), true)) {
                .key => |found| {
                    var key = found;
                    key.column = indent + 1;
                    try self.apply(&key.value, props);
                    return key;
                },
                .value => {},
            }
        }
        self.pos = first_line;
        return self.err("expected 'key:'");
    }

    /// The mapping whose keys are in column `indent`. The first one has been read.
    fn mapping(self: *Parser, indent: usize, first_key: Key) Error!Value {
        const map = try self.a.create(Map);
        map.* = .{};
        var key = first_key;
        while (true) {
            try self.checkKey(key.value, key.column);
            if (map.entries.contains(key.value)) return failAt(self.diag, self.pos + 1, key.column, "duplicate key", error.Syntax);
            var before = try self.takeBefore();
            const rest = std.mem.trimStart(u8, key.rest, " \t");
            const props = try self.takeProps(rest);
            var v: Value = undefined;
            var after: ?[]const u8 = null;
            if (endsLine(props.rest)) {
                after = try self.commentOn(props.rest);
                self.pos += 1;
                try self.skipBlank();
                const next = try self.cur();
                const deeper = next != null and next.?.indent > indent;
                v = try self.block(@intCast(indent), indent, props, true);
                // After a null value, pending comments belong to what follows.
                if (v != .scalar or deeper) {
                    const found = try self.commentsAround(v, before, after);
                    before = found.before;
                    after = found.after;
                }
            } else {
                v = (try self.readNode(props.rest, @intCast(indent), false)).value;
                try self.apply(&v, props);
                after = self.takeTrailing();
            }
            try map.putValue(self.a, key.value, v);
            map.entries.values()[map.count() - 1].comments = .{ .before = before, .after = after };

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

    /// A node, with any properties before it.
    fn node(self: *Flow) Error!Value {
        var props: Parser.Props = .{};
        while (self.peek()) |c| {
            if (c == '&') {
                if (props.anchor != null) return self.err("a node cannot have two anchors");
                const name = Parser.anchorName(self.line[self.i + 1 ..]);
                if (name.len == 0) return self.err("bad anchor");
                self.i += 1 + name.len;
                if (self.peek()) |after| {
                    if (after == '[' or after == '{') return self.err("bad anchor");
                }
                props.anchor = try self.p.defineAnchor(name);
            } else if (c == '!') {
                if (props.tag != null) return self.err("a node cannot have two tags");
                const tag = try self.p.readTag(self.line[self.i..], true) orelse return self.err("bad tag");
                props.tag = tag.name;
                self.i += tag.len;
            } else break;
            try self.skip();
        }
        var v: Value = null_scalar;
        const next = self.peek() orelse return self.err("expected a value in a flow collection");
        // Properties may be all there is to a node.
        const empty = props.any() and (next == ',' or next == ']' or next == '}' or (next == ':' and self.separatorFollows()));
        if (!empty) v = try self.content();
        try self.p.apply(&v, props);
        return v;
    }

    fn content(self: *Flow) Error!Value {
        const c = self.peek().?;
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
            '*' => {
                const name = Parser.anchorName(self.line[self.i + 1 ..]);
                const anchor = if (name.len != 0) self.p.lookupAnchor(name) else null;
                if (anchor == null) return self.err("an alias needs an anchor above it");
                self.i += 1 + name.len;
                return .{ .alias = anchor.? };
            },
            '&', '!' => return self.err("properties cannot stand here"),
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
            key = try self.node();
            // `"key":value` may leave out the blank after the colon.
            json_like = switch (key) {
                .scalar => |s| s.style == .single or s.style == .double,
                else => true,
            };
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
        switch (key) {
            .scalar, .alias => {},
            .seq, .map => return self.p.unsupported("a collection as a key is not supported"),
        }
        try self.p.checkKey(key, self.i + 1);
        if (m.entries.contains(key)) return self.err("duplicate key");
        try m.putValue(self.p.a, key, value);
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
        .scalar, .alias => return 0,
        .seq => |q| for (q.items.items) |item| {
            deepest = @max(deepest, levelsIn(item));
        },
        .map => |m| for (m.entries.values()) |e| {
            deepest = @max(deepest, levelsIn(e.value));
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
