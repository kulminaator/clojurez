const std = @import("std");

/// The Clojure string library source, embedded at compile time.
/// This is read from clj/string.clj during compilation.
pub const string_clj_source: []const u8 = @embedFile("clj/string.clj");
