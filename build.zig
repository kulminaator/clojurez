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

    // Copy io.clj into zig package for @embedFile
    // Source of truth: src/clj/io.clj
    // Destination: src/zig/namespaces/core/clj/io.clj (referenced by io_clj.zig)
    const copy_io = b.addSystemCommand(&.{
        "cp",
        "src/clj/io.clj",
        "src/zig/namespaces/core/clj/io.clj",
    });
    copy_io.addFileInput(b.path("src/clj/io.clj"));

    // Copy math.clj into zig package for @embedFile
    // Source of truth: src/clj/math.clj
    // Destination: src/zig/namespaces/core/clj/math.clj (referenced by math_clj.zig)
    const copy_math = b.addSystemCommand(&.{
        "cp",
        "src/clj/math.clj",
        "src/zig/namespaces/core/clj/math.clj",
    });
    copy_math.addFileInput(b.path("src/clj/math.clj"));

    // Copy walk.clj into zig package for @embedFile
    // Source of truth: src/clj/walk.clj
    // Destination: src/zig/namespaces/core/clj/walk.clj (referenced by walk_clj.zig)
    const copy_walk = b.addSystemCommand(&.{
        "cp",
        "src/clj/walk.clj",
        "src/zig/namespaces/core/clj/walk.clj",
    });
    copy_walk.addFileInput(b.path("src/clj/walk.clj"));

    // Copy template.clj into zig package for @embedFile
    // Source of truth: src/clj/template.clj
    // Destination: src/zig/namespaces/core/clj/template.clj (referenced by template_clj.zig)
    const copy_template = b.addSystemCommand(&.{
        "cp",
        "src/clj/template.clj",
        "src/zig/namespaces/core/clj/template.clj",
    });
    copy_template.addFileInput(b.path("src/clj/template.clj"));

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

    var debug_exe: ?*std.Build.Step.Compile = null;
    var last_install: ?*std.Build.Step.InstallArtifact = null;
    for (variants) |v| {
        const module = b.createModule(.{
            .root_source_file = src_path,
            .target = target,
            .optimize = v.opt,
            // Note: no .single_threaded — we need threading for futures/promises.
            .strip = if (v.strip) true else null,
        });

        const exe = b.addExecutable(.{
            .name = v.name,
            .root_module = module,
        });

        // Debug builds have ~25KB stack frame per function call due to safety checks.
        // Each Clojure recursive call invokes ~27 Zig functions = ~675KB per recursion level.
        // Default 8MB only supports ~12 levels. 64MB supports ~95 levels which is reasonable.
        if (v.opt == .Debug) {
            exe.stack_size = 1024 * 1024 * 64; // 64MB for debug
        }

        // All variants depend on .clj files being copied first
        exe.step.dependOn(&copy_core.step);
        exe.step.dependOn(&copy_string.step);
        exe.step.dependOn(&copy_io.step);
        exe.step.dependOn(&copy_math.step);
        exe.step.dependOn(&copy_walk.step);
        exe.step.dependOn(&copy_template.step);

        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);
        last_install = install;
        // Keep reference to the debug executable for doc generation
        if (v.name[0] == 'c' and std.mem.eql(u8, v.name, "clojurez")) {
            debug_exe = exe;
        }
    }

    // Auto-generate API documentation after building the binary.
    // Uses addRunArtifact so the binary is properly tracked as a dependency.
    if (debug_exe) |exe| {
        const gen_docs = b.addRunArtifact(exe);
        gen_docs.addArg("doc/gen_docs.clj");
        gen_docs.has_side_effects = true;
        // Depend on all binaries being installed first
        if (last_install) |inst| {
            gen_docs.step.dependOn(&inst.step);
        }
        b.getInstallStep().dependOn(&gen_docs.step);
    }
}
