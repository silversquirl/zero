//! Simple text buffer. This is incredibly inefficient, but works well enough until I can be
//! bothered to write something better. The API is designed to be implementation-agnostic.
const Buffer = @This();

text: std.ArrayList(u8),
selections: std.ArrayList(struct { u32, u32 }),

pub fn init(gpa: std.mem.Allocator, capacity: usize) !Buffer {
    var buf: Buffer = .{
        .text = .empty,
        .selections = .empty,
    };
    errdefer buf.deinit(gpa);

    try buf.text.ensureTotalCapacity(gpa, capacity);
    const cursor = try buf.selections.addOne(gpa);
    cursor.* = 0;

    return buf;
}
fn deinit(buf: *Buffer, gpa: std.mem.Allocator) void {
    buf.text.deinit(gpa);
    buf.selections.deinit(gpa);
}

pub fn insert(buf: *Buffer, gpa: std.mem.Allocator, text: []const u8) !void {
    var end = buf.text.items.len;
    _ = try buf.text.addManyAsSlice(gpa, text.len * buf.selections.items.len);

    var i = buf.selections.items.len;
    while (i > 0) {
        i -= 1;
        const start = buf.selections.items[i];
        const off: u32 = @intCast(text.len * (i + 1));
        buf.selections.items[i] += off;
        @memmove(buf.text.items[off + start .. off + end], buf.text.items[start..end]); // Make space
        @memcpy(buf.text.items[start .. start + text.len], text); // Insert
        end = start;
    }
}

// pub fn moveBack

test "build string" {
    const gpa = std.testing.allocator;
    var buf: Buffer = try .init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.insert(gpa, "Hello");
    try buf.insert(gpa, " world");
    buf.selections.items[0] -= 6;
    try buf.insert(gpa, ",");
    buf.selections.items[0] = @intCast(buf.text.items.len);
    try buf.insert(gpa, "!");
    try std.testing.expectEqualStrings("Hello, world!", buf.text.items);
}

test "multiple selections" {
    const gpa = std.testing.allocator;
    var buf: Buffer = try .init(gpa, 10);
    defer buf.deinit(gpa);

    try buf.insert(gpa, "I really like lists");
}

const std = @import("std");
