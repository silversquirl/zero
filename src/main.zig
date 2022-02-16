const std = @import("std");
const gl = @import("zgl");
const glfw = @import("glfw");
const nvg = @import("nanovg");

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

    while (!win.shouldClose()) {
        const size = try win.getSize();
        const fb_size = try win.getFramebufferSize();

        gl.viewport(0, 0, fb_size.width, fb_size.height);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(.{ .color = true });

        ctx.beginFrame(
            @intToFloat(f32, size.width),
            @intToFloat(f32, size.height),
            @intToFloat(f32, fb_size.width) / @intToFloat(f32, size.width),
        );

        ctx.roundedRect(100, 100, 200, 300, 40);
        ctx.fillColor(nvg.Color.hex(0xff00ffff));
        ctx.fill();

        ctx.endFrame();
        try win.swapBuffers();
        try glfw.waitEvents();
    }
}
