const std = @import("std");

/// The Clojure math library source, embedded at compile time.
/// This is read from clj/math.clj during compilation.
pub const math_clj_source: []const u8 = @embedFile("clj/math.clj");
