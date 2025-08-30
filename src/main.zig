var cli_args: CliArgs = undefined;
var editor: Editor = undefined;

const CliArgs = struct {
    arena: std.heap.ArenaAllocator,
    filenames: []const [:0]const u8,

    fn parseFromCommandLine() !CliArgs {
        var args: CliArgs = .{
            .arena = .init(gpa),
            .filenames = &.{},
        };
        const str_args = try std.process.argsAlloc(args.arena.allocator());

        args.filenames = str_args[1..];
        return args;
    }
};

fn init() dvui.App.StartOptions {
    cli_args = CliArgs.parseFromCommandLine() catch @panic("Out of memory");

    return .{
        // TODO: remember previous window size
        .size = .{ .w = 800, .h = 600 },
        .title = if (cli_args.filenames.len > 0)
            cli_args.filenames[0]
        else
            "<new file>",
    };
}

fn initWindow(win: *dvui.Window) !void {
    editor = .init(gpa);

    if (cli_args.filenames.len > 0) {
        for (cli_args.filenames) |filename| {
            try editor.openFile(std.fs.cwd(), filename);
        }
    } else {
        try editor.files.append(editor.gpa, .empty);
    }
    editor.current_file = 0;

    win.theme = switch (win.backend.preferredColorScheme() orelse .dark) {
        .dark => dvui.Theme.builtin.adwaita_dark,
        .light => dvui.Theme.builtin.adwaita_light,
    };
}
fn deinit() void {
    cli_args.arena.deinit();
    if (gpa_is_debug) {
        _ = debug_allocator.deinit();
    }
}

fn frame() !dvui.App.Result {
    const file = &editor.files.items[editor.current_file];
    const text = file.buffer.text.items;
    dvui.labelNoFmt(@src(), text, .{}, .{});
    return .ok;
}

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = init },
    .initFn = initWindow,
    .frameFn = frame,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

const gpa_is_debug = @import("builtin").mode == .Debug;
var debug_allocator: if (gpa_is_debug) std.heap.DebugAllocator(.{}) = .init;
const gpa = if (gpa_is_debug)
    debug_allocator.allocator()
else
    std.heap.smp_allocator;

const std = @import("std");
const dvui = @import("dvui");
const Buffer = @import("Buffer.zig");
const Editor = @import("Editor.zig");
