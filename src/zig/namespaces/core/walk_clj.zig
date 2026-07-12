const std = @import("std");

/// The Clojure walk library source, embedded at compile time.
/// This is read from clj/walk.clj during compilation.
pub const walk_clj_source: []const u8 = @embedFile("clj/walk.clj");
