const std = @import("std");
const gl = @import("zgl");
const glfw = @import("glfw");
const nvg = @import("nanovg");

const layout = @import("layout.zig");

pub fn main() !void {
    try glfw.init(.{});
    defer glfw.terminate();

    const win = try glfw.Window.create(1280, 800, "hi", null, null, .{
        .context_version_major = 3,
        .context_version_minor = 3,
        .opengl_profile = .opengl_core_profile,
    });
    defer win.destroy();

    try glfw.makeContextCurrent(win);
    const ctx = nvg.Context.createGl3(.{});
    defer ctx.deleteGl3();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var root = layout.Box{};
    var a = layout.Box{};
    var b = layout.Box{ .direction = .col };
    var c = layout.Box{ .growth = 120 };
    var d = layout.Box{};
    try root.addChild(gpa.allocator(), &a);
    try root.addChild(gpa.allocator(), &b);
    try b.addChild(gpa.allocator(), &c);
    try b.addChild(gpa.allocator(), &d);

    while (!win.shouldClose()) {
        const size = try win.getSize();

        root.layout(.{
            @intCast(layout.I, size.width),
            @intCast(layout.I, size.height),
        });

        {
            const fb_size = try win.getFramebufferSize();

            gl.viewport(0, 0, fb_size.width, fb_size.height);
            gl.clearColor(0, 0, 0, 0);
            gl.clear(.{ .color = true });

            ctx.beginFrame(
                @intToFloat(f32, size.width),
                @intToFloat(f32, size.height),
                @intToFloat(f32, fb_size.width) / @intToFloat(f32, size.width),
            );
        }

        root.draw(ctx);

        ctx.endFrame();
        try win.swapBuffers();
        try glfw.waitEvents();
    }
}
