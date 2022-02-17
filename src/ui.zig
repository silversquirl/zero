const std = @import("std");
const gl = @import("zgl");
const glfw = @import("glfw");
const nvg = @import("nanovg");

/// An unsigned int that can be losslessly converted to an f32
pub const I = u24;

/// A 2-vector of unsigned integers that can be losslessly converted to f32
pub const Vec2 = std.meta.Vector(2, I);

/// A 2-vector of optional unsigned integers that can be losslessly converted to f32
pub const OptVec2 = [2]?I;

/// A layout direction (row or column)
pub const Direction = enum { row, col };

/// Root window
pub const Window = struct {
    child: *Widget,

    size: Vec2,
    win: glfw.Window,
    ctx: *nvg.Context,

    pub fn init(title: [*:0]const u8, size: Vec2, child: *Widget) !Window {
        const win = try glfw.Window.create(size[0], size[1], title, null, null, .{
            .context_version_major = 3,
            .context_version_minor = 3,
            .opengl_profile = .opengl_core_profile,
        });
        errdefer win.destroy();

        try glfw.makeContextCurrent(win);
        const ctx = nvg.Context.createGl3(.{});
        errdefer ctx.deleteGl3();

        return Window{
            .child = child,
            .size = size,
            .win = win,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *Window) void {
        self.ctx.deleteGl3();
        self.win.destroy();
    }

    pub fn draw(self: *Window) !void {
        try glfw.makeContextCurrent(self.win);
        const fb_size = try self.win.getFramebufferSize();

        gl.viewport(0, 0, fb_size.width, fb_size.height);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(.{ .color = true });

        self.ctx.beginFrame(
            @intToFloat(f32, self.size[0]),
            @intToFloat(f32, self.size[1]),
            @intToFloat(f32, fb_size.width) / @intToFloat(f32, self.size[0]),
        );

        // Offset by 1 here because nvg doesn't render pixels at 0 coords
        self.child.draw(self.ctx, .{ 1, 1 });

        self.ctx.endFrame();
        try self.win.swapBuffers();
    }

    pub fn layout(self: *Window) void {
        // TODO: do this with a callback instead of every frame
        if (self.win.getSize()) |size| {
            self.size = .{
                @intCast(I, size.width),
                @intCast(I, size.height),
            };
        } else |_| {}

        self.child.pos = .{ 0, 0 };
        self.child.layoutMin();
        // Subtract 1 here because nvg doesn't render pixels at 0 coords
        self.child.layoutFull(self.size - Vec2{ 1, 1 });
    }
};

/// Generic widget interface for layout, input, and rendering
pub const Widget = struct {
    /// Widget position relative to parent
    pos: Vec2 = Vec2{ 0, 0 },
    /// Widget size
    size: Vec2 = Vec2{ 0, 0 },

    // FIXME: max_size and min_size are horribly broken
    min_size: OptVec2 = .{ null, null },
    max_size: OptVec2 = .{ null, null },

    /// How much to grow compared to siblings. 0 = no growth
    /// 360 is a highly composite number; good for lots of nice ratios
    growth: u16 = 360,
    /// Whether or not to fill the box in the cross direction
    expand: bool = true,

    funcs: struct {
        draw: fn (*Widget, *nvg.Context, offset: Vec2) void,

        layoutMin: fn (*Widget) void,
        layoutFull: fn (*Widget, container_size: Vec2) void,
    },

    fn draw(self: *Widget, ctx: *nvg.Context, offset: Vec2) void {
        self.funcs.draw(self, ctx, offset);
    }

    fn layoutMin(self: *Widget) void {
        self.funcs.layoutMin(self);
        self.clampSize();
    }
    fn layoutFull(self: *Widget, container_size: Vec2) void {
        self.funcs.layoutFull(self, container_size);
        self.clampSize();
    }

    fn clampSize(self: *Widget) void {
        for (self.min_size) |n_opt, i| {
            if (n_opt) |n| {
                self.size[i] = @maximum(self.size[i], n);
            }
        }

        for (self.max_size) |n_opt, i| {
            if (n_opt) |n| {
                self.size[i] = @minimum(self.size[i], n);
            }
        }
    }
};

/// A nested box for layout purposes
pub const Box = struct {
    w: Widget = .{ .funcs = .{
        .draw = draw,
        .layoutMin = layoutMin,
        .layoutFull = layoutFull,
    } },

    /// Direction in which to layout children
    direction: Direction = .row,
    children: std.ArrayListUnmanaged(*Widget) = .{},

    pub fn init(opts: anytype) Box {
        var self = Box{};
        inline for (comptime std.meta.fieldNames(@TypeOf(opts))) |field| {
            if (comptime std.mem.eql(u8, field, "direction")) {
                self.direction = opts.direction;
            } else {
                @field(self.w, field) = @field(opts, field);
            }
        }
        return self;
    }

    fn layoutMin(widget: *Widget) void {
        const self = @fieldParentPtr(Box, "w", widget);

        const dim = @enumToInt(self.direction);
        self.w.size = .{ 0, 0 };

        for (self.children.items) |child| {
            child.layoutMin();
            self.w.size[dim] += child.size[dim];
        }
    }

    fn layoutFull(widget: *Widget, total: Vec2) void {
        const self = @fieldParentPtr(Box, "w", widget);

        const dim = @enumToInt(self.direction);
        const extra = total[dim] - self.w.size[dim];

        self.w.size = total;
        self.w.clampSize();

        var total_growth: I = 0;
        for (self.children.items) |child| {
            total_growth += child.growth;
        }

        var pos = Vec2{ 0, 0 };
        for (self.children.items) |child| {
            var child_total = child.size;
            if (total_growth > 0 and child.growth > 0) {
                child_total[dim] += extra * child.growth / total_growth;
            }
            if (child.expand) {
                child_total[1 - dim] = @maximum(child_total[1 - dim], total[1 - dim]);
            }

            child.pos = pos;
            child.layoutFull(child_total);

            pos[dim] += child.size[dim];
        }
    }

    pub fn addChild(self: *Box, allocator: std.mem.Allocator, child: *Widget) !void {
        try self.children.append(allocator, child);
    }

    fn draw(widget: *Widget, ctx: *nvg.Context, offset: Vec2) void {
        const self = @fieldParentPtr(Box, "w", widget);

        var rng = std.rand.DefaultPrng.init(@ptrToInt(self));
        const color = randRgb(rng.random(), 1.0);

        ctx.beginPath();
        ctx.roundedRect(
            @intToFloat(f32, self.w.pos[0] + offset[0]),
            @intToFloat(f32, self.w.pos[1] + offset[1]),
            @intToFloat(f32, self.w.size[0]),
            @intToFloat(f32, self.w.size[1]),
            40,
        );

        ctx.fillColor(color);
        ctx.fill();

        for (self.children.items) |child| {
            child.draw(ctx, offset + self.w.pos);
        }
    }
    fn randRgb(rand: std.rand.Random, alpha: f32) nvg.Color {
        var vec = std.meta.Vector(3, f32){
            rand.floatNorm(f32),
            rand.floatNorm(f32),
            rand.floatNorm(f32),
        };
        const mag = @sqrt(@reduce(.Add, vec * vec));
        vec /= @splat(3, mag);
        return nvg.Color.rgbaf(vec[0], vec[1], vec[2], alpha);
    }
};
