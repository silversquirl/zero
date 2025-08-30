fn start() dvui.App.StartOptions {
    return .{
        // TODO: remember previous window size
        .size = .{ .w = 800, .h = 600 },
        // TODO: use filename
        .title = "Zero",
    };
}

fn frame() !dvui.App.Result {
    return .ok;
}

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .frameFn = frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

const std = @import("std");
const dvui = @import("dvui");
const Buffer = @import("Buffer.zig");
