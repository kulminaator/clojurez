const std = @import("std");

/// The zig.regexp library source, embedded at compile time.
/// This is read from clj/regexp.clj during compilation.
pub const regexp_clj_source: []const u8 = @embedFile("clj/regexp.clj");
