const std = @import("std");
const nvg = @import("nanovg");

/// An unsigned int that can be losslessly converted to an f32
pub const I = u24;

/// A 2-vector of unsigned integers that can be losslessly converted to f32
pub const Vec2 = std.meta.Vector(2, I);

/// A 2-vector of optional unsigned integers that can be losslessly converted to f32
pub const OptVec2 = [2]?I;

/// A layout direction (row or column)
pub const Direction = enum { row, col };

/// A nested box for layout purposes
pub const Box = struct {
    pos: Vec2 = Vec2{ 0, 0 },
    size: Vec2 = Vec2{ 0, 0 },

    // FIXME: max_size and min_size are horribly broken
    min_size: OptVec2 = .{ null, null },
    max_size: OptVec2 = .{ null, null },

    /// How much to grow compared to siblings. 0 = no growth
    /// 360 is a highly composite number; good for lots of nice ratios
    growth: u16 = 360,
    /// Whether or not to fill the box in the cross direction
    expand: bool = true,

    /// Direction in which to layout children
    direction: Direction = .row,
    children: std.ArrayListUnmanaged(*Box) = .{},

    pub fn layout(self: *Box, container_size: Vec2) void {
        self.pos = .{ 0, 0 };
        self.layoutMin();
        self.layoutFlex(container_size);
    }

    fn clamp(self: *Box) void {
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

    fn layoutMin(self: *Box) void {
        const dim = @enumToInt(self.direction);
        self.size = .{ 0, 0 };

        for (self.children.items) |child| {
            child.layoutMin();
            self.size[dim] += child.size[dim];
        }
    }

    fn layoutFlex(self: *Box, total: Vec2) void {
        const dim = @enumToInt(self.direction);
        const extra = total[dim] - self.size[dim];

        self.size = total;
        self.clamp();

        var total_growth: I = 0;
        for (self.children.items) |child| {
            total_growth += child.growth;
        }

        var pos = self.pos;
        for (self.children.items) |child| {
            var child_total = child.size;
            if (total_growth > 0 and child.growth > 0) {
                child_total[dim] += extra * child.growth / total_growth;
            }
            if (child.expand) {
                child_total[1 - dim] = @maximum(child_total[1 - dim], total[1 - dim]);
            }

            child.pos = pos;
            child.layoutFlex(child_total);

            pos[dim] += child.size[dim];
        }
    }

    pub fn addChild(self: *Box, allocator: std.mem.Allocator, child: *Box) !void {
        try self.children.append(allocator, child);
    }

    pub fn draw(self: *Box, ctx: *nvg.Context) void {
        var rng = std.rand.DefaultPrng.init(@ptrToInt(self));
        const color = randRgb(rng.random(), 1.0);
        // const color = nvg.Color.hex(rng.random().int(u32) | 0xff);

        ctx.beginPath();
        ctx.roundedRect(
            @intToFloat(f32, self.pos[0]),
            @intToFloat(f32, self.pos[1]),
            @intToFloat(f32, self.size[0]),
            @intToFloat(f32, self.size[1]),
            40,
        );

        ctx.fillColor(color);
        ctx.fill();

        for (self.children.items) |child| {
            child.draw(ctx);
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
