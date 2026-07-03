const std = @import("std");

/// The zig.io library source, embedded at compile time.
/// This is read from clj/io.clj during compilation.
pub const io_clj_source: []const u8 = @embedFile("clj/io.clj");
