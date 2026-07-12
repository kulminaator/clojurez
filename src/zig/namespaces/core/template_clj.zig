const std = @import("std");

/// The Clojure template library source, embedded at compile time.
/// This is read from clj/template.clj during compilation.
pub const template_clj_source: []const u8 = @embedFile("clj/template.clj");
