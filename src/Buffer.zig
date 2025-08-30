//! Simple text buffer. This is incredibly inefficient, but works well enough until I can be
//! bothered to write something better. The API is designed to be implementation-agnostic.
const Buffer = @This();

const Selection = struct {
    start: u32,
    len: u32,

    fn end(sel: Selection) u32 {
        return sel.start + sel.len;
    }
};

text: std.ArrayListUnmanaged(u8),
selections: std.ArrayListUnmanaged(Selection),

pub const empty: Buffer = .{
    .text = .empty,
    .selections = .empty,
};

pub fn deinit(buf: *Buffer, gpa: std.mem.Allocator) void {
    buf.text.deinit(gpa);
    buf.selections.deinit(gpa);
}

pub fn fromOwnedSlice(data: []u8) Buffer {
    return .{
        .text = .fromOwnedSlice(data),
        .selections = .empty,
    };
}

pub fn insertBefore(buf: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    for (buf.selections.items, 0..) |*sel, i| {
        sel.start += @intCast(text.len * (i + 1));
        try buf.text.insertSlice(gpa, sel.start - text.len, text);
    }
}

pub fn insertEnd(buf: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    for (buf.selections.items, 0..) |*sel, i| {
        sel.start += @intCast(text.len * i);
        try buf.text.insertSlice(gpa, sel.end(), text);
        sel.len += @intCast(text.len);
    }
}

pub fn delete(buf: *Buffer) !void {
    var total: u32 = 0;
    var i: usize = 0;
    while (i < buf.selections.items.len) {
        const sel = &buf.selections.items[i];
        const remove = i < buf.selections.items.len - 1 and buf.selections.items[i + 1].start == sel.end();
        sel.start -= total;
        sel.len = 1;
        total += sel.len;
        buf.text.replaceRangeAssumeCapacity(sel.start, sel.len, &.{});
        i += 1;
        if (remove) {
            buf.selections.replaceRangeAssumeCapacity(i, 1, &.{});
            i -= 1;
        }
    }
}

pub fn addSelection(buf: *Buffer, gpa: std.mem.Allocator, start: u32, len: u32) !void {
    std.debug.assert(len >= 1);

    var i: usize = 0;
    while (i < buf.selections.items.len) : (i += 1) {
        if (buf.selections.items[i].end() > start) break;
    }
    var j: usize = i;
    while (j < buf.selections.items.len) : (j += 1) {
        if (buf.selections.items[j].start > start + len) break;
    }

    if (i == j) {
        try buf.selections.insert(gpa, i, .{ .start = start, .len = len });
    } else {
        const new_start = @min(start, buf.selections.items[i].start);
        const new_end = @max(start + len, buf.selections.items[j - 1].end());
        const new_len = new_end - new_start;
        try buf.selections.replaceRange(gpa, i, j - i, &.{.{ .start = new_start, .len = new_len }});
    }
}

pub fn clearSelections(buf: *Buffer) void {
    buf.selections.clearRetainingCapacity();
}

test "insertBefore" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.text.appendSlice(gpa, "hello");
    try buf.selections.appendSlice(gpa, &.{
        .{ .start = 0, .len = 2 },
        .{ .start = 4, .len = 1 },
    });

    try buf.insertBefore(gpa, "X");

    try std.testing.expectEqualStrings("XhellXo", buf.text.items);
    try std.testing.expectEqualSlices(
        Selection,
        &.{
            .{ .start = 1, .len = 2 },
            .{ .start = 6, .len = 1 },
        },
        buf.selections.items,
    );
}

test "insertEnd" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.text.appendSlice(gpa, "hello");
    try buf.selections.appendSlice(gpa, &.{
        .{ .start = 0, .len = 2 },
        .{ .start = 4, .len = 1 },
    });

    try buf.insertEnd(gpa, "XY");

    try std.testing.expectEqualStrings("heXYlloXY", buf.text.items);
    try std.testing.expectEqualSlices(
        Selection,
        &.{
            .{ .start = 0, .len = 4 },
            .{ .start = 6, .len = 3 },
        },
        buf.selections.items,
    );
}

test "delete" {
    const gpa = std.testing.allocator;
    var buf = try Buffer.init(gpa, 20);
    defer buf.deinit(gpa);

    try buf.text.appendSlice(gpa, "hello world");
    try buf.selections.appendSlice(gpa, &.{
        .{ .start = 1, .len = 2 },
        .{ .start = 3, .len = 3 },
        .{ .start = 9, .len = 1 },
    });

    try buf.delete();

    try std.testing.expectEqualStrings("hword", buf.text.items);
    try std.testing.expectEqualSlices(
        Selection,
        &.{
            .{ .start = 1, .len = 1 },
            .{ .start = 4, .len = 1 },
        },
        buf.selections.items,
    );
}

test "add selection" {
    const gpa = std.testing.allocator;
    var buf: Buffer = try .init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.selections.appendSlice(gpa, &.{
        .{ .start = 0, .len = 2 },
        .{ .start = 4, .len = 1 },
    });

    try buf.addSelection(gpa, 2, 1);

    try std.testing.expectEqualSlices(
        Selection,
        &.{
            .{ .start = 0, .len = 2 },
            .{ .start = 2, .len = 1 },
            .{ .start = 4, .len = 1 },
        },
        buf.selections.items,
    );
}

test "add selection with merging" {
    const gpa = std.testing.allocator;
    var buf: Buffer = try .init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.selections.appendSlice(gpa, &.{
        .{ .start = 0, .len = 2 },
        .{ .start = 4, .len = 2 },
        .{ .start = 9, .len = 1 },
        .{ .start = 11, .len = 3 },
        .{ .start = 16, .len = 4 },
    });

    try buf.addSelection(gpa, 3, 10);

    try std.testing.expectEqualSlices(
        Selection,
        &.{
            .{ .start = 0, .len = 2 },
            .{ .start = 3, .len = 11 },
            .{ .start = 16, .len = 4 },
        },
        buf.selections.items,
    );
}

const std = @import("std");
