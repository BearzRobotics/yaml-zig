//! yaml-zig: a YAML reader and writer that keeps comments.
//!
//! ```zig
//! var diag: yaml.Diagnostic = .{};
//! var doc = try yaml.Document.parse(gpa, source, .{}, &diag);
//! defer doc.deinit();
//! const name = doc.root.map.getString("name");
//! try doc.set(&.{"release"}, try doc.integer(101));
//! const text = try doc.toOwnedString(gpa);   // comments are still there
//! ```
//!
//! See `parser.zig` for the YAML that is read and `writer.zig` for what is
//! written back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const writer = @import("writer.zig");

pub const Value = @import("value.zig").Value;
pub const Scalar = @import("value.zig").Scalar;
pub const Kind = @import("value.zig").Kind;
pub const Style = @import("value.zig").Style;
pub const Seq = @import("value.zig").Seq;
pub const Map = @import("value.zig").Map;
pub const Anchor = @import("value.zig").Anchor;
pub const Comments = @import("value.zig").Comments;
pub const ParseError = parser.Error;
pub const Options = @import("parser.zig").Options;
pub const Diagnostic = @import("parser.zig").Diagnostic;
pub const ParseReaderError = ParseError || error{ReadFailed};
pub const WriteError = @import("writer.zig").Error;

/// A parsed document. Owns an arena holding every string, sequence and
/// mapping reachable from `root`; `deinit` frees all of it at once.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,
    /// Columns per nesting level, learned from the source (2 if there is no nesting).
    indent: u8 = 2,
    /// The source began with `---`.
    explicit_start: bool = false,
    /// Comment lines above a leading `---`, and after the last item (same form as `Comments.before`).
    header: []const []const u8 = &.{},
    footer: []const []const u8 = &.{},
    /// Comments on a root that is a scalar or a flow collection: the lines
    /// above it and the comment on its line.
    root_comments: Comments = .{},
    /// The comment on the `---` line, written only with `explicit_start`.
    start_comment: ?[]const u8 = null,
    /// How deep collections may nest when written: `Options.max_depth` as
    /// parsed, so that the output can be read with the same options.
    max_depth: u32 = (Options{}).max_depth,
    /// `%YAML` and `%TAG` lines, as written above the document's `---`.
    directives: []const []const u8 = &.{},
    /// The source closed the document with `...`. A stream writes the marker
    /// again if another document follows.
    explicit_end: bool = false,

    /// An empty document whose root is an empty mapping.
    pub fn init(gpa: Allocator) Allocator.Error!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const m = try arena.allocator().create(Map);
        m.* = .{};
        return .{ .arena = arena, .root = .{ .map = m } };
    }

    /// Parses `source` (UTF-8). `source` is not retained. On failure the
    /// optional `diag` receives a 1-based line and a message.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) ParseError!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const res = try parser.parse(gpa, arena.allocator(), source, options, diag);
        return fromResult(arena, res, options);
    }

    fn fromResult(arena: std.heap.ArenaAllocator, res: parser.Result, options: Options) Document {
        return .{
            .arena = arena,
            .root = res.root,
            .indent = res.indent,
            .explicit_start = res.explicit_start,
            .header = res.header,
            .footer = res.footer,
            .root_comments = res.root_comments,
            .start_comment = res.start_comment,
            .directives = res.directives,
            .explicit_end = res.explicit_end,
            .max_depth = options.max_depth,
        };
    }

    /// Reads all of `r` (at most `options.max_bytes`), then parses it.
    pub fn parseReader(gpa: Allocator, r: *std.Io.Reader, options: Options, diag: ?*Diagnostic) ParseReaderError!Document {
        const bytes = r.allocRemaining(gpa, .limited(options.max_bytes)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => {
                if (diag) |d| d.* = .{ .line = 1, .column = 1, .message = "input too large" };
                return error.LimitExceeded;
            },
            error.ReadFailed => {
                if (diag) |d| d.* = .{ .line = 1, .column = 1, .message = "read failed" };
                return error.ReadFailed;
            },
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes, options, diag);
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The allocator that owns this document's contents.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }

    pub fn dupe(self: *Document, s: []const u8) Allocator.Error![]const u8 {
        return self.allocator().dupe(u8, s);
    }

    // ---- building values -----------------------------------------------------------

    /// A string scalar, quoted if it would otherwise read as something else
    /// (`"true"`, `"12"`, `""`), as a literal block if it has several lines.
    pub fn string(self: *Document, s: []const u8) (Allocator.Error || error{InvalidUtf8})!Value {
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        const text = try self.dupe(s);
        if (std.mem.indexOfScalar(u8, s, '\n') != null) {
            const ok = for (s) |c| {
                if (c != '\n' and c != '\t' and (c < 0x20 or c == 0x7F)) break false;
            } else true;
            if (ok) return .{ .scalar = .{ .text = text, .style = .literal, .kind = .string } };
        }
        return .{ .scalar = .{ .text = text, .style = .plain, .kind = .string } };
    }

    pub fn integer(self: *Document, i: i64) Allocator.Error!Value {
        const t = try std.fmt.allocPrint(self.allocator(), "{d}", .{i});
        return .{ .scalar = .{ .text = t, .style = .plain, .kind = .integer } };
    }

    pub fn boolean(_: *Document, b: bool) Value {
        return .{ .scalar = .{ .text = if (b) "true" else "false", .style = .plain, .kind = .boolean } };
    }

    pub fn nullValue(_: *Document) Value {
        return .{ .scalar = .{ .text = "", .style = .plain, .kind = .null } };
    }

    /// Puts the anchor `&name` on the node `v`, which must not be an alias,
    /// and returns it. `.{ .alias = anchor }` is then an alias of the node; it
    /// must be written after it.
    pub fn anchorNode(self: *Document, v: *Value, name: []const u8) Allocator.Error!*Anchor {
        std.debug.assert(v.* != .alias);
        const a = try self.allocator().create(Anchor);
        const owned = try self.dupe(name);
        switch (v.*) {
            .scalar => |*s| s.anchor = a,
            .seq => |q| q.anchor = a,
            .map => |m| m.anchor = a,
            .alias => unreachable,
        }
        a.* = .{ .name = owned, .value = v.* };
        return a;
    }

    pub fn newMap(self: *Document) Allocator.Error!Value {
        const m = try self.allocator().create(Map);
        m.* = .{};
        return .{ .map = m };
    }

    pub fn newSeq(self: *Document) Allocator.Error!Value {
        const q = try self.allocator().create(Seq);
        q.* = .{};
        return .{ .seq = q };
    }

    // ---- paths -----------------------------------------------------------------------

    pub const PathError = Allocator.Error || error{ NotACollection, NotFound, InvalidUtf8 };

    /// Sets the value at `path` (mapping keys; a number indexes a sequence),
    /// creating missing mappings on the way. Replacing a value keeps its
    /// comments. Values must be arena-owned: build them with the methods above.
    pub fn set(self: *Document, path: []const []const u8, v: Value) PathError!void {
        std.debug.assert(path.len > 0);
        for (path) |seg| if (!std.unicode.utf8ValidateSlice(seg)) return error.InvalidUtf8;
        const a = self.allocator();
        var cur = self.root;
        for (path[0 .. path.len - 1]) |seg| {
            // A path through an alias edits the anchored node.
            switch (cur.deref()) {
                .alias => unreachable,
                .map => |m| {
                    if (m.getPtr(seg)) |next| {
                        cur = next.*;
                    } else {
                        const nv = try self.newMap();
                        try m.put(a, try self.dupe(seg), nv);
                        cur = nv;
                    }
                },
                .seq => |q| cur = q.items.items[try index(q, seg)],
                .scalar => return error.NotACollection,
            }
        }
        const last = path[path.len - 1];
        switch (cur.deref()) {
            .map => |m| try m.put(a, try self.dupe(last), v),
            .seq => |q| @import("value.zig").replaceNode(&q.items.items[try index(q, last)], v),
            .scalar => return error.NotACollection,
            .alias => unreachable,
        }
    }

    fn index(q: *Seq, seg: []const u8) error{NotFound}!usize {
        const i = std.fmt.parseInt(usize, seg, 10) catch return error.NotFound;
        if (i >= q.items.items.len) return error.NotFound;
        return i;
    }

    /// The value at `path`, or null.
    pub fn lookup(self: *const Document, path: []const []const u8) ?Value {
        var cur = self.root;
        for (path) |seg| {
            switch (cur) {
                .map => |m| cur = m.get(seg) orelse return null,
                .seq => |q| cur = q.items.items[index(q, seg) catch return null].deref(),
                .scalar => return null,
                .alias => unreachable,
            }
        }
        return cur;
    }

    /// Attaches comments to the item at `path`: its `key:` line or its `-` line.
    /// Strings in `c` are copied. Fails with `error.InvalidComment` if a line is
    /// not empty or `#...`.
    pub fn setComments(self: *Document, path: []const []const u8, c: Comments) (PathError || error{InvalidComment})!void {
        std.debug.assert(path.len > 0);
        try @import("value.zig").checkComments(c);
        const a = self.allocator();
        const own: Comments = .{
            .before = blk: {
                const out = try a.alloc([]const u8, c.before.len);
                for (c.before, out) |l, *o| o.* = try a.dupe(u8, l);
                break :blk out;
            },
            .after = if (c.after) |x| try a.dupe(u8, x) else null,
        };
        const parent = if (path.len == 1) self.root else self.lookup(path[0 .. path.len - 1]) orelse return error.NotFound;
        const last = path[path.len - 1];
        switch (parent.deref()) {
            .alias => unreachable,
            .map => |m| {
                if (m.get(last) == null) return error.NotFound;
                try m.setComments(last, own);
            },
            .seq => |q| q.comments.items[try index(q, last)] = own,
            .scalar => return error.NotACollection,
        }
    }

    // ---- writing ---------------------------------------------------------------------

    pub fn write(self: *const Document, w: *std.Io.Writer) WriteError!void {
        try writer.write(w, self.view());
    }

    fn view(self: *const Document) writer.Doc {
        return .{
            .root = self.root,
            .indent = self.indent,
            .explicit_start = self.explicit_start,
            .header = self.header,
            .footer = self.footer,
            .root_comments = self.root_comments,
            .start_comment = self.start_comment,
            .directives = self.directives,
            .explicit_end = self.explicit_end,
            .max_depth = self.max_depth,
            .gpa = self.arena.child_allocator,
        };
    }

    /// Returns the YAML text; caller frees with `gpa`.
    pub fn toOwnedString(self: *const Document, gpa: Allocator) ToStringError![]u8 {
        return toString(self, gpa);
    }
};

pub const ToStringError = writer.CheckError || error{WriteFailed};

fn toString(value: anytype, gpa: Allocator) ToStringError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    value.write(&aw.writer) catch |e| switch (e) {
        // An allocating writer fails only when it cannot grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    return aw.toOwnedSlice();
}

/// All the documents of a YAML stream. Each has its own arena, so one can be
/// edited or kept without the others.
pub const Stream = struct {
    gpa: Allocator,
    /// Allocated with `gpa`; `deinit` frees it and every document in it.
    documents: []Document,
    /// The comments of a stream that has no document.
    comments: []const []const u8 = &.{},
    comment_arena: std.heap.ArenaAllocator,

    /// Parses every document in `source` (UTF-8), which is not retained.
    /// `options.max_bytes` limits the stream as a whole.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) ParseError!Stream {
        var reader = try parser.Reader.init(gpa, source, options, diag);
        defer reader.deinit();
        var documents: std.ArrayList(Document) = .empty;
        errdefer {
            for (documents.items) |*d| d.deinit();
            documents.deinit(gpa);
        }
        while (true) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const res = try reader.next(arena.allocator()) orelse {
                arena.deinit();
                break;
            };
            try documents.append(gpa, Document.fromResult(arena, res, options));
        }
        var comment_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer comment_arena.deinit();
        const comments: []const []const u8 = if (documents.items.len == 0) try reader.leftover(comment_arena.allocator()) else &.{};
        const owned = try documents.toOwnedSlice(gpa);
        return .{ .gpa = gpa, .documents = owned, .comments = comments, .comment_arena = comment_arena };
    }

    pub fn deinit(self: *Stream) void {
        for (self.documents) |*d| d.deinit();
        self.gpa.free(self.documents);
        self.comment_arena.deinit();
        self.* = undefined;
    }

    /// Writes every document, with the `---` and `...` lines that keep them
    /// apart.
    pub fn write(self: *const Stream, w: *std.Io.Writer) WriteError!void {
        for (self.documents) |*d| try writer.check(d.view());
        for (self.comments) |line| {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
        var ended = false;
        for (self.documents, 0..) |*d, i| {
            const next: ?writer.Doc = if (i + 1 < self.documents.len) self.documents[i + 1].view() else null;
            ended = try writer.writeInStream(w, d.view(), i, ended, next);
        }
    }

    /// Returns the YAML text; caller frees with `gpa`.
    pub fn toOwnedString(self: *const Stream, gpa: Allocator) ToStringError![]u8 {
        return toString(self, gpa);
    }
};

test {
    _ = @import("tests.zig");
}
