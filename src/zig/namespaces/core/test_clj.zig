const std = @import("std");

/// The Clojure test library source, embedded at compile time.
/// This is read from clj/test.clj during compilation.
pub const test_clj_source: []const u8 = @embedFile("clj/test.clj");
