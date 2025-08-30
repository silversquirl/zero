const Editor = @This();

gpa: std.mem.Allocator,
files: std.ArrayListUnmanaged(File),
current_file: u32,

pub fn init(gpa: std.mem.Allocator) Editor {
    return .{
        .gpa = gpa,
        .files = .empty,
        .current_file = undefined,
    };
}

pub fn openFile(editor: *Editor, dir: std.fs.Dir, filename: []const u8) !void {
    try editor.files.append(editor.gpa, try .open(editor.gpa, dir, filename));
}

pub const File = struct {
    // TODO: store file handle and/or path
    buffer: Buffer,

    pub const empty: File = .{
        .buffer = .empty,
    };

    pub fn open(gpa: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) !File {
        const data = try dir.readFileAlloc(gpa, filename, std.math.maxInt(u64));
        return .{ .buffer = .fromOwnedSlice(data) };
    }
};

const std = @import("std");
const Buffer = @import("Buffer.zig");
