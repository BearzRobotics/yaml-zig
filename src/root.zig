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

pub const Value = @import("value.zig").Value;
pub const Scalar = @import("value.zig").Scalar;
pub const Kind = @import("value.zig").Kind;
pub const Style = @import("value.zig").Style;
pub const Seq = @import("value.zig").Seq;
pub const Map = @import("value.zig").Map;
pub const Comments = @import("value.zig").Comments;
pub const ParseError = @import("parser.zig").Error;
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
        const res = try @import("parser.zig").parse(gpa, arena.allocator(), source, options, diag);
        return .{
            .arena = arena,
            .root = res.root,
            .indent = res.indent,
            .explicit_start = res.explicit_start,
            .header = res.header,
            .footer = res.footer,
        };
    }

    /// Reads all of `r` (at most `options.max_bytes`), then parses it.
    pub fn parseReader(gpa: Allocator, r: *std.Io.Reader, options: Options, diag: ?*Diagnostic) ParseReaderError!Document {
        const bytes = r.allocRemaining(gpa, .limited(options.max_bytes)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.LimitExceeded,
            error.ReadFailed => return error.ReadFailed,
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
    pub fn string(self: *Document, s: []const u8) Allocator.Error!Value {
        const text = try self.dupe(s);
        if (std.mem.indexOfScalar(u8, s, '\n') != null) {
            const ok = for (s) |c| {
                if (c != '\n' and c != '\t' and (c < 0x20 or c == 0x7F)) break false;
            } else true;
            if (ok and std.unicode.utf8ValidateSlice(s)) return .{ .scalar = .{ .text = text, .style = .literal, .kind = .string } };
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

    pub const PathError = Allocator.Error || error{ NotACollection, NotFound };

    /// Sets the value at `path` (mapping keys; a number indexes a sequence),
    /// creating missing mappings on the way. Replacing a value keeps its
    /// comments. Values must be arena-owned: build them with the methods above.
    pub fn set(self: *Document, path: []const []const u8, v: Value) PathError!void {
        std.debug.assert(path.len > 0);
        const a = self.allocator();
        var cur = self.root;
        for (path[0 .. path.len - 1]) |seg| {
            switch (cur) {
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
        switch (cur) {
            .map => |m| try m.put(a, try self.dupe(last), v),
            .seq => |q| q.items.items[try index(q, last)] = v,
            .scalar => return error.NotACollection,
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
                .seq => |q| cur = q.items.items[index(q, seg) catch return null],
                .scalar => return null,
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
        switch (parent) {
            .map => |m| {
                if (m.get(last) == null) return error.NotFound;
                try m.setComments(a, last, own);
            },
            .seq => |q| q.comments.items[try index(q, last)] = own,
            .scalar => return error.NotACollection,
        }
    }

    // ---- writing ---------------------------------------------------------------------

    pub fn write(self: *const Document, w: *std.Io.Writer) WriteError!void {
        try @import("writer.zig").write(w, .{
            .root = self.root,
            .indent = self.indent,
            .explicit_start = self.explicit_start,
            .header = self.header,
            .footer = self.footer,
        });
    }

    /// Returns the YAML text; caller frees with `gpa`.
    pub fn toOwnedString(self: *const Document, gpa: Allocator) (Allocator.Error || error{WriteFailed})![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        self.write(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

test {
    _ = @import("tests.zig");
}
