const std = @import("std");

/// The Clojure core library source, embedded at compile time.
/// This is read from clj/core.clj during compilation.
pub const core_clj_source: []const u8 = @embedFile("clj/core.clj");
