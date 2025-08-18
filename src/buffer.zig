const std = @import("std");

/// Text buffer supporting efficient insertion and deletion
///
/// This is implemented as an array of "segments" pointing into an array of "layers".
/// Each layer is a mutable buffer. Edits can either modify the relevant layer directly,
/// or split the layer based on a heuristic to create two new segments, then insert a
/// segment of a new layer between them.
///
/// If too many segments are created, a "unify" operation may be performed, which flattens
/// the layer structure, resulting in much fewer segments and hence faster editing.
///
/// This datastructure supports "holes", allowing large files to be only partially loaded.
/// For this purpose, the sentinel buffer index 0xffff_ffff is used to indicate a hole.
///
/// "Marks" are automatically tracked positions in the buffer that are updated whenever a
/// change is made. They can be created at the start or end of a buffer, or at the position
/// of another mark, and can be moved by byte offset.
pub const Buffer = struct {
    allocator: std.mem.Allocator,

    filled_size: usize = 0, // Current size of the buffer (excluding holes)
    segments: std.ArrayListUnmanaged(Segment) = .{},
    layers: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .{},

    seg_marks: std.ArrayListUnmanaged(std.ArrayListUnmanaged(usize)) = .{},
    marks: std.ArrayListUnmanaged(MarkEntry) = .{},
    free_mark: ?usize = null,

    const Segment = struct {
        layer: u32,
        off: u32,
        len: u32,
    };
    const MarkEntry = union {
        pos: MarkPos,
        free: usize,
    };
    const MarkPos = struct {
        seg: u32,
        off: u32,
    };
    pub const Mark = struct { i: usize };
    pub const MarkAnchor = union(enum) {
        start,
        end,
        mark: Mark,
    };

    // 16k copy takes ~6us
    const copy_max = 16 << 10;
    // Min average size of layers. We want to have no more than one layer per this many bytes
    const layer_size = 128 << 10;

    /// Create an empty buffer
    pub fn init(allocator: std.mem.Allocator) !Buffer {
        var self = Buffer{ .allocator = allocator };

        // Add one layer and one segment, because it's easier than dealing with the null case
        try self.layers.append(self.allocator, .{});
        try self.segments.append(self.allocator, .{ .layer = 0, .off = 0, .len = 0 });
        try self.seg_marks.append(self.allocator, .{});

        return self;
    }
    /// Destroy a buffer
    pub fn deinit(self: *Buffer) void {
        self.segments.deinit(self.allocator);
        for (self.layers.items) |*layer| {
            layer.deinit(self.allocator);
        }
        self.layers.deinit(self.allocator);

        for (self.seg_marks.items) |*sm| {
            sm.deinit(self.allocator);
        }
        self.seg_marks.deinit(self.allocator);
        self.marks.deinit(self.allocator);
    }

    /// Create a new mark
    pub fn mark(self: *Buffer, anchor: MarkAnchor) !Mark {
        // Alloc
        var idx: usize = undefined;
        var entry: *MarkEntry = undefined;
        if (self.free_mark) |i| {
            idx = i;
            entry = &self.marks.items[i];

            // iff no more values, next value == this value
            self.free_mark = if (entry.free == i) null else entry.free;
        } else {
            idx = self.marks.items.len;
            entry = try self.marks.addOne(self.allocator);
        }

        // Init
        entry.* = .{ .pos = switch (anchor) {
            .start => .{
                .seg = 0,
                .off = 0,
            },
            .end => .{
                .seg = @intCast(self.segments.items.len - 1),
                .off = @intCast(self.segments.items[self.segments.items.len - 1].len),
            },
            .mark => |m| self.marks.items[m.i].pos,
        } };

        try self.seg_marks.items[entry.pos.seg].append(self.allocator, idx);

        self.checkMark(entry.pos);
        return Mark{ .i = idx };
    }

    /// Recreate a mark
    pub fn remark(self: *Buffer, m: Mark, anchor: MarkAnchor) !void {
        self.unmark(m);
        const new = try self.mark(anchor);
        std.debug.assert(m.i == new.i);
    }

    /// Remove a mark
    pub fn unmark(self: *Buffer, m: Mark) void {
        const entry = &self.marks.items[m.i];

        // OPTIM: record index in the segment's marks on the mark pos?
        for (self.seg_marks.items[entry.pos.seg].items, 0..) |idx, i| {
            if (idx == m.i) {
                _ = self.seg_marks.items[entry.pos.seg].swapRemove(i);
                break;
            }
        } else unreachable;

        entry.* = .{ .free = self.free_mark orelse m.i };
        self.free_mark = m.i;
    }

    /// Move a mark by a byte offset
    pub fn move(self: Buffer, m: Mark, movement: i64) !void {
        var pos = self.marks.items[m.i].pos;
        self.checkMark(pos);
        const start_seg = pos.seg;

        var off = movement;
        if (off < 0) {
            while (pos.off < -off and pos.seg > 0) {
                pos.seg -= 1;
                off += pos.off + 1;
                pos.off = self.segments.items[pos.seg].len - 1;
            }
        } else {
            while (pos.seg < self.segments.items.len - 1 and
                pos.off +| off >= self.segments.items[pos.seg].len)
            {
                off -= self.segments.items[pos.seg].len - pos.off;
                pos.seg += 1;
                pos.off = 0;
            }
        }

        pos.off = @min(
            std.math.lossyCast(u32, pos.off + off),
            self.segments.items[pos.seg].len,
        );

        // Add to new segment
        try self.seg_marks.items[pos.seg].append(self.allocator, m.i);
        // Remove from old segment
        for (self.seg_marks.items[start_seg].items, 0..) |idx, i| {
            if (idx == m.i) {
                _ = self.seg_marks.items[start_seg].swapRemove(i);
                break;
            }
        } else unreachable;
        // Update position
        self.marks.items[m.i].pos = pos;

        self.checkMark(pos);
    }

    /// Ensure a mark is valid
    inline fn checkMark(self: Buffer, pos: MarkPos) void {
        const seg = self.segments.items[pos.seg];
        if (pos.off >= seg.len) {
            std.debug.assert(pos.off == seg.len);
            std.debug.assert(pos.seg == self.segments.items.len - 1);
        }
    }

    /// Return the byte at a mark
    pub fn get(self: Buffer, m: Mark) ?u8 {
        return self.getPos(self.marks.items[m.i].pos);
    }
    fn getPos(self: Buffer, pos: MarkPos) ?u8 {
        self.checkMark(pos);
        const seg = self.segments.items[pos.seg];
        const layer = self.layers.items[seg.layer];
        if (pos.off < seg.len) {
            return layer.items[seg.off + pos.off];
        } else {
            return null;
        }
    }

    /// Scan a mark forward or backward to the next of a given byte. If the byte is not found, the cursor is not moved.
    /// Returns true if that byte was found, false otherwise
    pub fn scan(self: *Buffer, m: Mark, b: u8, direction: Direction) !bool {
        const start = try self.mark(.{ .mark = m });
        defer self.unmark(start);
        errdefer self.remark(m, .{ .mark = start }) catch unreachable;

        const pos = &self.marks.items[m.i].pos;
        self.checkMark(pos.*);
        while (pos.seg > 0 or pos.off > 0) {
            try self.move(m, switch (direction) {
                .forward => 1,
                .backward => -1,
            });

            // check upper bound
            if (pos.seg == self.segments.items.len - 1 and
                pos.off == self.segments.items[pos.seg].len)
            {
                break;
            }

            if (self.get(m) == b) {
                return true;
            }
        }

        self.remark(m, .{ .mark = start }) catch unreachable;
        return false;
    }
    pub const Direction = enum { forward, backward };

    /// Create a reader from the buffer, linked to the specified mark.
    /// The mark will be moved when the reader advances.
    pub fn readerAt(self: *Buffer, m: Mark) Reader {
        return Reader{ .context = .{ .buf = self, .mark = m } };
    }
    pub const Reader = std.io.Reader(ReaderState, ReadError, ReaderState.read);
    pub const ReadError = error{OutOfMemory};
    const ReaderState = struct {
        buf: *Buffer,
        mark: Mark,

        fn read(self: ReaderState, buffer: []u8) ReadError!usize {
            for (buffer, 0..) |*b, i| {
                b.* = self.buf.get(self.mark) orelse return i;
                try self.buf.move(self.mark, 1);
            } else {
                return buffer.len;
            }
        }
    };

    /// Insert data into the buffer before the specified mark
    pub fn insert(self: *Buffer, m: Mark, data: []const u8) !void {
        // TODO: handle >4GiB insertions?

        const pos = self.marks.items[m.i].pos;
        self.checkMark(pos);

        if (self.canDirectlyModify(pos)) |pos2| {
            const seg = &self.segments.items[pos2.seg];
            try self.layers.items[seg.layer].insertSlice(self.allocator, pos2.off, data);
            seg.len += @intCast(data.len); // FIXME: segments should not grow over 4GiB
            self.filled_size += data.len;

            // Fix marks within this segment
            for (self.seg_marks.items[pos2.seg].items) |idx| {
                const seg_pos = &self.marks.items[idx].pos;
                std.debug.assert(seg_pos.seg == pos2.seg);
                if (seg_pos.off >= pos2.off) {
                    seg_pos.off += @intCast(data.len);
                }
            }
        } else {
            try self.allowUnify();

            // Create new layer
            var layer = std.ArrayListUnmanaged(u8){};
            errdefer layer.deinit(self.allocator);
            try layer.appendSlice(self.allocator, data);
            const layer_i: u32 = @intCast(self.layers.items.len);
            try self.layers.append(self.allocator, layer);
            errdefer _ = self.layers.swapRemove(layer_i);

            // Insert new segment
            try self.insertSegment(pos, .{
                .layer = layer_i,
                .off = 0,
                .len = @intCast(data.len),
            });
            self.filled_size += data.len;
        }
    }

    /// Remove data from the buffer between two marks
    pub fn remove(self: *Buffer, start: Mark, end: Mark) !void {
        var a = self.marks.items[start.i].pos;
        var b = self.marks.items[end.i].pos;

        self.checkMark(a);
        self.checkMark(b);

        // This is a very naive algorithm, but avoids adjusting marks which is complex and expensive
        // Also makes memory management easy because only unify can ever free

        // Edit first segment
        if (a.seg < b.seg) {
            const seg = &self.segments.items[a.seg];
            const l = &self.layers.items[seg.layer];
            if (seg.off + seg.len == l.items.len) {
                // Shrink layer
                l.shrinkRetainingCapacity(seg.off + a.off);
            }

            // Shrink segment
            self.filled_size -= seg.len - a.off;
            seg.len = a.off;

            try self.moveMarksUp(a.seg);

            a.seg += 1;
            a.off = 0;
        }

        // Delete middle segments
        while (a.seg < b.seg) : (a.seg += 1) {
            const seg = &self.segments.items[a.seg];
            self.filled_size -= seg.len;
            seg.len = 0;
            try self.moveMarksUp(a.seg);
        }

        // Edit last segment
        std.debug.assert(a.seg == b.seg);
        if (a.off < b.off) {
            const count = b.off - a.off;
            if (self.canDirectlyModify(b)) |pos| {
                const seg = &self.segments.items[pos.seg];
                // Edit layer directly
                self.layers.items[seg.layer].replaceRange(
                    std.testing.failing_allocator,
                    a.off,
                    count,
                    &.{},
                ) catch unreachable;
                seg.len -= count;
            } else {
                const seg = &self.segments.items[b.seg];
                // Split segment
                if (a.off > 0) {
                    try self.segments.insert(self.allocator, b.seg, .{
                        .layer = seg.layer,
                        .off = seg.off,
                        .len = a.off,
                    });
                    try self.seg_marks.insert(self.allocator, b.seg + 1, .{});
                    try self.fixMarks(b.seg);
                    b.seg += 1;
                }
                seg.off += b.off;
                seg.len -= b.off;
                for (self.seg_marks.items[b.seg].items) |m| {
                    const pos = &self.marks.items[m].pos;
                    std.debug.assert(pos.seg == b.seg);
                    pos.off -|= b.off;
                    self.checkMark(pos.*);
                }
            }

            self.filled_size -= count;
            b.off = 0;
        }

        try self.allowUnify();
    }

    /// Checks whether or not it is acceptable to modify a segment directly
    /// Returns segment index or null
    inline fn canDirectlyModify(self: Buffer, pos_const: MarkPos) ?MarkPos {
        var pos = pos_const;
        if (pos.seg > 0 and pos.off == 0) {
            // TODO: try both options
            pos.seg -= 1;
            pos.off = self.segments.items[pos.seg].len;
        }

        const seg = self.segments.items[pos.seg];
        const layer = self.layers.items[seg.layer];
        if (layer.items.len - (seg.off + pos.off) <= copy_max) {
            // Copying will be fast
            return pos;
        } else {
            return null;
        }
    }

    /// This will happen automatically, but it's sometimes useful to call it manually.
    ///
    /// For example, when saving you need to iterate the entire buffer anyway, so might as well
    /// clean it up while you're at it to improve edit performance after the save.
    pub fn unify(self: *Buffer) !void {
        var total: usize = 0;
        // TODO
        for (self.segments.items) |seg| {
            total += seg.len;
        }
        std.debug.assert(total == self.filled_size);
    }
    inline fn allowUnify(self: *Buffer) !void {
        // Unify if we have too many layers
        const n_layers = self.layers.items.len;
        if (n_layers > 1 and self.filled_size / n_layers <= layer_size) {
            try self.unify();
        }
    }

    fn insertSegment(self: *Buffer, pos: MarkPos, seg: Segment) !void {
        const old = &self.segments.items[pos.seg];
        if (pos.off == 0) {
            // No need to split, just insert before
            try self.segments.insert(self.allocator, pos.seg, seg);
            try self.seg_marks.insert(self.allocator, pos.seg, .{});
            self.fixMarks(pos.seg + 1) catch unreachable;
        } else if (pos.off == old.len) {
            // No need to split, just insert after
            try self.segments.insert(self.allocator, pos.seg + 1, seg);
            self.fixMarks(pos.seg + 2) catch unreachable;
        } else {
            // Split the old segment
            const new = Segment{
                .layer = old.layer,
                .off = old.off + pos.off,
                .len = old.len - pos.off,
            };

            old.len = pos.off;

            // TODO: use insertSlice and fix all marks in one go
            try self.segments.insert(self.allocator, pos.seg + 1, new);
            try self.seg_marks.insert(self.allocator, pos.seg + 1, .{});
            try self.fixMarks(pos.seg);

            // Insert the new segment
            try self.segments.insert(self.allocator, pos.seg + 1, seg);
            try self.seg_marks.insert(self.allocator, pos.seg + 1, .{});
            try self.fixMarks(pos.seg);
        }
    }

    /// Fix marks after inserting a new segment
    fn fixMarks(self: *Buffer, start: u32) !void {
        var i = start;
        const n_seg = self.seg_marks.items.len;
        std.debug.assert(n_seg == self.segments.items.len);
        while (i < n_seg) : (i += 1) {
            const seg = self.segments.items[i];
            const seg_m = &self.seg_marks.items[i];
            var j: usize = 0;
            while (j < seg_m.items.len) {
                const m = seg_m.items[j];
                j += 1;

                // Fix position
                const pos = &self.marks.items[m].pos;
                pos.seg = i;

                // Fix segment
                if (pos.off >= seg.len) {
                    if (i == n_seg - 1) {
                        pos.off = seg.len;
                    } else {
                        try self.seg_marks.items[pos.seg + 1].append(self.allocator, m);
                        j -= 1;
                        _ = seg_m.swapRemove(j);

                        pos.off -= seg.len;
                        pos.seg += 1;
                    }
                }
            }
        }
    }

    /// Move marks in a given segment forwards one segment
    fn moveMarksUp(self: *Buffer, seg: u32) !void {
        const src = &self.seg_marks.items[seg];
        const dst = &self.seg_marks.items[seg + 1];
        for (src.items) |m| {
            try dst.append(self.allocator, m);
            const pos = &self.marks.items[m].pos;
            pos.seg += 1;
            pos.off = 0;
        }
        src.shrinkAndFree(self.allocator, 0);
    }
};

test "insert + read" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    const a = try buf.mark(.start);
    const p = &buf.marks.items[a.i].pos;
    try expectEqualPos(.{ .seg = 0, .off = 0 }, p.*);
    try buf.insert(a, "a" ** 20_000);
    try expectEqualPos(.{ .seg = 0, .off = 20_000 }, p.*);
    try buf.remark(a, .start);
    try buf.insert(a, "b" ** 10_000);
    try expectEqualPos(.{ .seg = 1, .off = 0 }, p.*);
    try buf.insert(a, "b" ** 10_000);
    try expectEqualPos(.{ .seg = 1, .off = 0 }, p.*);

    try buf.remark(a, .end);
    try expectEqualPos(.{ .seg = 1, .off = 20_000 }, p.*);
    try buf.insert(a, "c" ** 20_000);
    try expectEqualPos(.{ .seg = 1, .off = 40_000 }, p.*);
    try buf.move(a, -20_000);
    try expectEqualPos(.{ .seg = 1, .off = 20_000 }, p.*);
    try buf.insert(a, "d" ** 20_000);
    try expectEqualPos(.{ .seg = 3, .off = 0 }, p.*);

    try std.testing.expectEqualSlices(Buffer.Segment, &.{
        .{ .layer = 1, .off = 0, .len = 20_000 },
        .{ .layer = 0, .off = 0, .len = 20_000 },
        .{ .layer = 2, .off = 0, .len = 20_000 },
        .{ .layer = 0, .off = 20_000, .len = 20_000 },
    }, buf.segments.items);

    try std.testing.expectEqual(@as(usize, 3), buf.layers.items.len);

    try buf.remark(a, .start);
    try expectRead("b" ** 20_000 ++ "a" ** 20_000 ++ "d" ** 20_000 ++ "c" ** 20_000, buf.readerAt(a));
}

test "delete" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    const a = try buf.mark(.start);
    try buf.insert(a, "a" ** 20_000);
    try buf.remark(a, .start);
    try buf.insert(a, "b" ** 20_000);

    const b = try buf.mark(.{ .mark = a });
    try buf.move(a, -1000);
    try buf.move(b, 1000);
    try buf.remove(a, b);

    try expectEqualPos(.{ .seg = 1, .off = 0 }, buf.marks.items[a.i].pos);
    try expectEqualPos(.{ .seg = 1, .off = 0 }, buf.marks.items[b.i].pos);

    try std.testing.expectEqualSlices(Buffer.Segment, &.{
        .{ .layer = 1, .off = 0, .len = 19_000 },
        .{ .layer = 0, .off = 1000, .len = 19_000 },
    }, buf.segments.items);

    try std.testing.expectEqual(@as(usize, 2), buf.layers.items.len);

    try buf.remark(a, .start);
    try expectRead("b" ** 19_000 ++ "a" ** 19_000, buf.readerAt(a));
}

test "scan" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    const a = try buf.mark(.start);
    try buf.insert(a, "a" ** 20_000);
    try buf.insert(a, "asdjflka;jiojwla;jsd");
    try buf.remark(a, .start);
    try buf.insert(a, "asdfasdf;bsdfasdf;");
    try buf.insert(a, "b" ** 20_000);

    const b = try buf.mark(.{ .mark = a });
    const b_pos = &buf.marks.items[b.i].pos;

    try expectEqualPos(.{ .seg = 1, .off = 0 }, b_pos.*);
    try std.testing.expect(try buf.scan(b, ';', .backward));
    try expectEqualPos(.{ .seg = 0, .off = 17 }, b_pos.*);
    try std.testing.expect(try buf.scan(b, ';', .backward));
    try expectEqualPos(.{ .seg = 0, .off = 8 }, b_pos.*);
    try std.testing.expect(!try buf.scan(b, ';', .backward));
    try expectEqualPos(.{ .seg = 0, .off = 8 }, b_pos.*);

    try buf.remark(b, .{ .mark = a });
    try expectEqualPos(.{ .seg = 1, .off = 0 }, b_pos.*);
    try std.testing.expect(try buf.scan(b, ';', .forward));
    try expectEqualPos(.{ .seg = 1, .off = 20_000 + 8 }, b_pos.*);
    try std.testing.expect(try buf.scan(b, ';', .forward));
    try expectEqualPos(.{ .seg = 1, .off = 20_000 + 16 }, b_pos.*);
    try std.testing.expect(!try buf.scan(b, ';', .forward));
}

fn expectRead(expected: []const u8, r: anytype) !void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    while (n < expected.len) {
        const count = try r.read(&buf);
        try std.testing.expectEqualStrings(expected[n .. n + count], buf[0..count]);
        n += count;
        if (count < buf.len) break;
    }
    try std.testing.expectEqual(expected.len, n);
}

fn expectEqualPos(expected: Buffer.MarkPos, actual: Buffer.MarkPos) !void {
    try std.testing.expectEqual(expected.seg, actual.seg);
    try std.testing.expectEqual(expected.off, actual.off);
}
