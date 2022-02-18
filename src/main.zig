const std = @import("std");
const glfw = @import("glfw");

const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var root = ui.Box{};
    var a = ui.Box.init(.{
        .min_size = .{ 100, null },
        .max_size = .{ 500, null },
    });
    var b = ui.Box.init(.{ .direction = .col });
    var c = ui.Box.init(.{ .growth = 120 });
    var d = ui.Box.init(.{});
    try root.addChild(gpa.allocator(), &a.w);
    try root.addChild(gpa.allocator(), &b.w);
    try b.addChild(gpa.allocator(), &c.w);
    try b.addChild(gpa.allocator(), &d.w);

    try glfw.init(.{});
    defer glfw.terminate();

    var win = try ui.Window.init("hi", .{ 1280, 800 }, &root.w);
    defer win.deinit();

    while (!win.win.shouldClose()) {
        win.layout();
        try win.draw();

        try glfw.waitEvents();
    }
}
