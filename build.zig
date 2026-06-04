const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const src_path = b.path("src/zig/main.zig");

    // Build 3 variants into zig-out/bin/:
    //   clojurez       — default optimize mode (Debug by default)
    //   clojurez-medium — -OReleaseSmall
    //   clojurez-mini   — -OReleaseSmall -fstrip

    const variants = [_]struct {
        name: []const u8,
        opt: std.builtin.OptimizeMode,
        strip: bool,
    }{
        .{ .name = "clojurez", .opt = optimize, .strip = false },
        .{ .name = "clojurez-medium", .opt = .ReleaseSmall, .strip = false },
        .{ .name = "clojurez-mini", .opt = .ReleaseSmall, .strip = true },
    };

    for (variants) |v| {
        const module = b.createModule(.{
            .root_source_file = src_path,
            .target = target,
            .optimize = v.opt,
            .single_threaded = true,
            .strip = if (v.strip) true else null,
        });

        const exe = b.addExecutable(.{
            .name = v.name,
            .root_module = module,
        });

        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
    }
}
