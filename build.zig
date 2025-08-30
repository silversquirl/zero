const std = @import("std");

var target: std.Build.ResolvedTarget = undefined;
var optimize: std.builtin.OptimizeMode = undefined;

pub fn build(b: *std.Build) void {
    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});

    const backend = b.option(Backend, "backend", "Rendering backend to use") orelse .sdl3;

    const exe = b.addExecutable(.{
        .name = "zero",
        .root_module = module(b, backend),
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const check = b.addExecutable(.{
        .name = "zero",
        .root_module = module(b, backend),
    });
    b.step("check", "Check for compile errors").dependOn(&check.step);

    const test_step = b.addTest(.{
        .root_module = module(b, .testing),
    });
    const run_tests = b.addRunArtifact(test_step);
    b.step("test", "Run all tests").dependOn(&run_tests.step);
}

fn module(b: *std.Build, backend: Backend) *std.Build.Module {
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
    });
    const dvui_mod = dvui_dep.module(switch (backend) {
        .sdl3 => "dvui_sdl3",
        .testing => "dvui_testing",
    });

    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_mod },
        },
    });
}

const Backend = enum { sdl3, testing };
