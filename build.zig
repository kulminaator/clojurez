const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Copy core.clj into zig package for @embedFile
    // Source of truth: src/clj/core.clj
    // Destination: src/zig/namespaces/core/clj/core.clj (referenced by core_clj.zig)
    const copy_core = b.addSystemCommand(&.{
        "cp",
        "src/clj/core.clj",
        "src/zig/namespaces/core/clj/core.clj",
    });
    copy_core.addFileInput(b.path("src/clj/core.clj"));

    // Copy string.clj into zig package for @embedFile
    // Source of truth: src/clj/string.clj
    // Destination: src/zig/namespaces/core/clj/string.clj (referenced by string_clj.zig)
    const copy_string = b.addSystemCommand(&.{
        "cp",
        "src/clj/string.clj",
        "src/zig/namespaces/core/clj/string.clj",
    });
    copy_string.addFileInput(b.path("src/clj/string.clj"));

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

        // All variants depend on core.clj and string.clj being copied first
        exe.step.dependOn(&copy_core.step);
        exe.step.dependOn(&copy_string.step);


        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
    }
}
