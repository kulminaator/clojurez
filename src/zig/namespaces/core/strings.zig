// String built-in functions: str, utf8-valid?
const std = @import("std");
const vm = @import("../../value.zig");
const Value = vm.Value;
const list = @import("../../list.zig");
const Env = vm.Env;
const helpers = @import("helpers.zig");
const test_utils = @import("test_utils.zig");
const protocols = @import("protocols.zig");
const eval_ns = @import("../../eval_ns.zig");
const Allocator = std.mem.Allocator;

/// Try to call Object/toString on a value. Returns the string result or null if not implemented.
fn tryToString(allocator: Allocator, val: *const Value, env: *Env) anyerror!?[]const u8 {
    // Look up clojure.core namespace
    const ns_mgr = eval_ns.findNsManager(env) orelse return null;
    const core_env = ns_mgr.getNamespace("clojure.core") orelse return null;

    // Look up Object protocol in clojure.core
    const object_proto_val = core_env.get("Object") orelse return null;
    if (std.meta.activeTag(object_proto_val) != .map) return null;

    // Get :impls from protocol map (borrowed reference — do NOT deinit)
    var impls_kw = try vm.keywordValue(allocator, "impls");
    defer vm.valueDeinit(&impls_kw, allocator);
    const impls_map = protocols.getMapEntry(object_proto_val, impls_kw) orelse return null;

    // Get type keyword for this value
    const type_kw_str = protocols.typeKeyword(val.*);
    var type_kw = try vm.keywordValue(allocator, type_kw_str);
    defer vm.valueDeinit(&type_kw, allocator);
    const type_impls = protocols.getMapEntry(impls_map, type_kw) orelse return null;

    // Check if toString method exists (borrowed reference — do NOT deinit)
    var method_kw = try vm.keywordValue(allocator, "toString");
    defer vm.valueDeinit(&method_kw, allocator);
    const impl_fn = protocols.getMapEntry(type_impls, method_kw) orelse return null;

    // Build args: (toString this)
    var args: list.List = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, try vm.shallowClone(val, allocator));

    // Call the implementation directly
    const eval_mod = @import("../../eval.zig");
    const result = eval_mod.callWithEnvV(allocator, &impl_fn, &args, env, 0) catch return null;

    if (std.meta.activeTag(result.*) == .string) {
        return try allocator.dupe(u8, result.*.string);
    }
    vm.valueDeinit(&result.*, allocator);
    allocator.destroy(result);
    return null;
}

pub fn core_str(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    const allocator = env_env.allocator;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (args.items) |arg| {
        // For records, try Object/toString first (avoids infinite recursion with symbols)
        if (std.meta.activeTag(arg) == .record) {
            if (try tryToString(allocator, &arg, env_env)) |to_str| {
                defer allocator.free(to_str);
                try buf.appendSlice(allocator, to_str);
                continue;
            }
        }
        // Handle character type: convert code point to UTF-8 string
        if (std.meta.activeTag(arg) == .character) {
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(arg.character, &utf8_buf) catch return error.InvalidUnicode;
            try buf.appendSlice(env_env.allocator, utf8_buf[0..utf8_len]);
            continue;
        }
        const s = try vm.fmt(arg, env_env.allocator);
        defer env_env.allocator.free(s);
        // Strip quotes from string values
        if (std.meta.activeTag(arg) == .string and s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
            try buf.appendSlice(env_env.allocator, s[1 .. s.len - 1]);
        } else {
            try buf.appendSlice(env_env.allocator, s);
        }
    }
    return vm.stringValue(env_env.allocator, try buf.toOwnedSlice(env_env.allocator));
}

pub fn core_utf8_valid_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    if (std.meta.activeTag(args.items[0]) != .string) return error.TypeError;
    return vm.boolValue(std.unicode.utf8ValidateSlice(args.items[0].string));
}

/// subs - returns the substring of s beginning at start inclusive, and ending
/// at end (defaults to length of string), exclusive.
/// Uses UTF-8 code point indices (consistent with nth on strings).
pub fn core_subs(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    if (std.meta.activeTag(args.items[0]) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = args.items[0].string;
    const start = try helpers.toInt(args.items[1]);
    if (start < 0) return error.IndexOutOfBounds;

    const codepoint_count = vm.utf8CodepointCount(s);
    var end: i64 = @as(i64, @intCast(codepoint_count));
    if (args.items.len == 3) {
        end = try helpers.toInt(args.items[2]);
    }
    if (end < start) return error.IndexOutOfBounds;
    if (end > @as(i64, @intCast(codepoint_count))) end = @as(i64, @intCast(codepoint_count));

    // Find the byte offset for start code point
    var byte_start: usize = 0;
    var i: i64 = 0;
    while (i < start) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, @as(usize, @intCast(i))) orelse break;
        byte_start += cp_bytes.len;
    }
    // Find the byte offset for end code point
    var byte_end: usize = byte_start;
    i = start;
    while (i < end) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, @as(usize, @intCast(i))) orelse break;
        byte_end += cp_bytes.len;
    }

    return vm.stringValue(allocator, s[byte_start..byte_end]);
}

pub fn registerStringFunctions(env: *Env) anyerror!void {
    try env.put("str", vm.builtinFnValue(core_str));
    try env.put("utf8-valid?", vm.builtinFnValue(core_utf8_valid_q));
    try env.put("subs", vm.builtinFnValue(core_subs));
}

// ===== clojure.string namespace built-in functions =====
// These are registered into the clojure.string namespace.
// Higher-level wrappers (reverse, join, escape) are in Clojure code.

/// Helper: convert a codepoint to upper-case (ASCII-aware).
/// Non-ASCII codepoints are returned unchanged.
fn cpToUpperCase(cp: u21) u21 {
    return if (cp < 128) std.ascii.toUpper(@as(u8, @intCast(cp))) else cp;
}

/// Helper: convert a codepoint to lower-case (ASCII-aware).
/// Non-ASCII codepoints are returned unchanged.
fn cpToLowerCase(cp: u21) u21 {
    return if (cp < 128) std.ascii.toLower(@as(u8, @intCast(cp))) else cp;
}

/// Helper: check if a codepoint is whitespace (ASCII whitespace + common Unicode whitespace).
fn isWhitespaceCp(cp: u21) bool {
    if (cp < 128) return std.ascii.isWhitespace(@as(u8, @intCast(cp)));
    // Common Unicode whitespace codepoints
    return cp == 0x0085 or // Next Line
        cp == 0x00A0 or // No-break space
        cp == 0x1680 or // Ogham space mark
        cp == 0x2000 or cp == 0x2001 or cp == 0x2002 or cp == 0x2003 or
        cp == 0x2004 or cp == 0x2005 or cp == 0x2006 or cp == 0x2007 or
        cp == 0x2008 or cp == 0x2009 or cp == 0x200A or cp == 0x200B or
        cp == 0x2028 or // Line separator
        cp == 0x2029 or // Paragraph separator
        cp == 0x202F or // Narrow no-break space
        cp == 0x205F or // Medium mathematical space
        cp == 0x3000;  // Ideographic space
}

/// upper-case - converts string to all upper-case.
pub fn str_upper_case(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    var upper: std.ArrayList(u8) = .empty;
    errdefer upper.deinit(allocator);

    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const upper_cp = cpToUpperCase(cp);
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(upper_cp, &utf8_buf) catch return error.InvalidUnicode;
        try upper.appendSlice(allocator, utf8_buf[0..utf8_len]);
    }
    return vm.stringValue(allocator, try upper.toOwnedSlice(allocator));
}

/// lower-case - converts string to all lower-case.
pub fn str_lower_case(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    var lower: std.ArrayList(u8) = .empty;
    errdefer lower.deinit(allocator);

    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const lower_cp = cpToLowerCase(cp);
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(lower_cp, &utf8_buf) catch return error.InvalidUnicode;
        try lower.appendSlice(allocator, utf8_buf[0..utf8_len]);
    }
    return vm.stringValue(allocator, try lower.toOwnedSlice(allocator));
}

/// capitalize - converts first character to upper-case, all others to lower-case.
pub fn str_capitalize(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    if (s.len == 0) return vm.stringValue(allocator, "");

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    var first = true;
    while (it.nextCodepoint()) |cp| {
        const out_cp = if (first) cpToUpperCase(cp) else cpToLowerCase(cp);
        first = false;
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(out_cp, &utf8_buf) catch return error.InvalidUnicode;
        try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
    }
    return vm.stringValue(allocator, try result.toOwnedSlice(allocator));
}

/// trim - removes whitespace from both ends of string.
pub fn str_trim(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    if (s.len == 0) return vm.stringValue(allocator, "");

    const codepoint_count = vm.utf8CodepointCount(s);
    if (codepoint_count == 0) return vm.stringValue(allocator, "");

    // Find first non-whitespace code point index
    var start: usize = 0;
    while (start < codepoint_count) : (start += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, start) orelse break;
        const cp = std.unicode.utf8Decode(cp_bytes) catch break;
        if (!isWhitespaceCp(cp)) break;
    }

    // Find last non-whitespace code point index
    var end: usize = codepoint_count;
    while (end > 0) {
        end -= 1;
        const cp_bytes = vm.utf8CodepointAt(s, end) orelse break;
        const cp = std.unicode.utf8Decode(cp_bytes) catch break;
        if (!isWhitespaceCp(cp)) break;
    }

    if (start > end) return vm.stringValue(allocator, "");

    // Convert code point indices to byte offsets
    var byte_start: usize = 0;
    var i: usize = 0;
    while (i < start) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
        byte_start += cp_bytes.len;
    }
    var byte_end: usize = byte_start;
    i = start;
    while (i <= end) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
        byte_end += cp_bytes.len;
    }

    return vm.stringValue(allocator, s[byte_start..byte_end]);
}

/// triml - removes whitespace from the left side of string.
pub fn str_triml(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    if (s.len == 0) return vm.stringValue(allocator, "");

    const codepoint_count = vm.utf8CodepointCount(s);
    if (codepoint_count == 0) return vm.stringValue(allocator, "");

    // Find first non-whitespace code point index
    var start: usize = 0;
    while (start < codepoint_count) : (start += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, start) orelse break;
        const cp = std.unicode.utf8Decode(cp_bytes) catch break;
        if (!isWhitespaceCp(cp)) break;
    }

    if (start >= codepoint_count) return vm.stringValue(allocator, "");

    // Convert code point index to byte offset
    var byte_start: usize = 0;
    var i: usize = 0;
    while (i < start) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
        byte_start += cp_bytes.len;
    }

    return vm.stringValue(allocator, s[byte_start..]);
}

/// trimr - removes whitespace from the right side of string.
pub fn str_trimr(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    if (s.len == 0) return vm.stringValue(allocator, "");

    const codepoint_count = vm.utf8CodepointCount(s);
    if (codepoint_count == 0) return vm.stringValue(allocator, "");

    // Find last non-whitespace code point index
    var end: usize = codepoint_count;
    while (end > 0) {
        end -= 1;
        const cp_bytes = vm.utf8CodepointAt(s, end) orelse break;
        const cp = std.unicode.utf8Decode(cp_bytes) catch break;
        if (!isWhitespaceCp(cp)) break;
    }

    if (end == 0) return vm.stringValue(allocator, "");

    // Convert code point index to byte offset (include the character at end)
    var byte_end: usize = 0;
    var i: usize = 0;
    while (i <= end) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
        byte_end += cp_bytes.len;
    }

    return vm.stringValue(allocator, s[0..byte_end]);
}

/// trim-newline - removes trailing \n or \r characters.
pub fn str_trim_newline(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const allocator = env_env.allocator;
    const s = arg.string;

    if (s.len == 0) return vm.stringValue(allocator, "");

    // Find last non-newline byte (we operate on bytes since \n and \r are single-byte)
    var end: usize = s.len;
    var found_non_newline = false;
    while (end > 0) {
        end -= 1;
        if (s[end] != '\n' and s[end] != '\r') {
            found_non_newline = true;
            break;
        }
    }

    if (!found_non_newline) return vm.stringValue(allocator, "");
    return vm.stringValue(allocator, s[0 .. end + 1]);
}

/// blank? - true if s is nil, empty, or contains only whitespace.
pub fn str_blank_q(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len != 1) return error.ArityError;
    const arg = args.items[0];

    // nil is blank
    if (std.meta.activeTag(arg) == .nil) return vm.boolValue(true);
    if (std.meta.activeTag(arg) != .string) return error.TypeError;
    const s = arg.string;

    if (s.len == 0) return vm.boolValue(true);

    // Check if all code points are whitespace
    const view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isWhitespaceCp(cp)) return vm.boolValue(false);
    }
    return vm.boolValue(true);
}

/// index-of - return index of value (string or char) in s.
/// Optionally searching forward from from-index. Returns nil if not found.
pub fn str_index_of(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const s_arg = args.items[0];
    if (std.meta.activeTag(s_arg) != .string) return error.TypeError;
    const s = s_arg.string;

    const codepoint_count = vm.utf8CodepointCount(s);

    // Handle from_index as i64 to support negative values (clamped to 0)
    var from_index: i64 = 0;
    if (args.items.len == 3) {
        from_index = try helpers.toInt(args.items[2]);
        if (from_index < 0) from_index = 0;
    }

    // Clamp from_index to codepoint count
    const from_index_clamped: usize = if (from_index > @as(i64, @intCast(codepoint_count)))
        codepoint_count
    else
        @as(usize, @intCast(from_index));

    // Search for substring
    if (std.meta.activeTag(args.items[1]) == .string) {
        const needle = args.items[1].string;
        // Empty needle: return from_index clamped to codepoint count
        if (needle.len == 0) return vm.intValue(@as(i64, @intCast(from_index_clamped)));

        // Find byte offset from from_index code points
        var byte_from: usize = 0;
        var i: usize = 0;
        while (i < from_index_clamped) : (i += 1) {
            const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
            byte_from += cp_bytes.len;
        }

        const remaining = s[byte_from..];
        if (std.mem.indexOf(u8, remaining, needle)) |idx| {
            // Convert byte offset to code point index
            const absolute_byte = byte_from + idx;
            var cp_idx: usize = 0;
            var byte_pos: usize = 0;
            while (byte_pos < absolute_byte) {
                const cp_bytes = vm.utf8CodepointAt(s, cp_idx) orelse break;
                byte_pos += cp_bytes.len;
                cp_idx += 1;
            }
            return vm.intValue(@as(i64, @intCast(cp_idx)));
        }
        return vm.nilValue();
    }
    // Search for character
    if (std.meta.activeTag(args.items[1]) == .character) {
        const ch = args.items[1].character;
        var utf8_needle: [4]u8 = undefined;
        const needle_len = std.unicode.utf8Encode(ch, &utf8_needle) catch return error.InvalidUnicode;

        var byte_from: usize = 0;
        var i: usize = 0;
        while (i < from_index_clamped) : (i += 1) {
            const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
            byte_from += cp_bytes.len;
        }

        const remaining = s[byte_from..];
        if (std.mem.indexOf(u8, remaining, utf8_needle[0..needle_len])) |idx| {
            const absolute_byte = byte_from + idx;
            var cp_idx: usize = 0;
            var byte_pos: usize = 0;
            while (byte_pos < absolute_byte) {
                const cp_bytes = vm.utf8CodepointAt(s, cp_idx) orelse break;
                byte_pos += cp_bytes.len;
                cp_idx += 1;
            }
            return vm.intValue(@as(i64, @intCast(cp_idx)));
        }
        return vm.nilValue();
    }
    return error.TypeError;
}

/// last-index-of - return last index of value (string or char) in s.
/// Optionally searching backward from from-index. Returns nil if not found.
pub fn str_last_index_of(self: *const Value, args: *const list.List, env_env: *Env) anyerror!Value {
    _ = self;
    _ = env_env;
    if (args.items.len < 2 or args.items.len > 3) return error.ArityError;
    const s_arg = args.items[0];
    if (std.meta.activeTag(s_arg) != .string) return error.TypeError;
    const s = s_arg.string;

    const codepoint_count = vm.utf8CodepointCount(s);

    // Handle from_index as i64 to support negative values (return nil)
    var from_index: i64 = @as(i64, @intCast(codepoint_count));
    if (args.items.len == 3) {
        from_index = try helpers.toInt(args.items[2]);
        if (from_index < 0) return vm.nilValue();
    }

    // Clamp from_index to codepoint count for search boundary
    const from_index_clamped: usize = if (from_index > @as(i64, @intCast(codepoint_count)))
        codepoint_count
    else
        @as(usize, @intCast(from_index));

    // Compute byte position of from_index_clamped
    var byte_from: usize = 0;
    var i: usize = 0;
    while (i < from_index_clamped) : (i += 1) {
        const cp_bytes = vm.utf8CodepointAt(s, i) orelse break;
        byte_from += cp_bytes.len;
    }

    // Search for substring
    if (std.meta.activeTag(args.items[1]) == .string) {
        const needle = args.items[1].string;
        if (needle.len == 0) return vm.intValue(@as(i64, @intCast(from_index_clamped)));

        // Find last occurrence where start byte <= byte_from.
        // We scan forward to find all matches with start <= byte_from.
        var best_byte: ?usize = null;
        var search_pos: usize = 0;
        while (search_pos <= byte_from) {
            const remaining = s[search_pos..];
            if (std.mem.indexOf(u8, remaining, needle)) |idx| {
                const match_byte = search_pos + idx;
                if (match_byte <= byte_from) {
                    best_byte = match_byte;
                    search_pos = match_byte + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        if (best_byte) |best| {
            var cp_idx: usize = 0;
            var byte_pos: usize = 0;
            while (byte_pos < best) {
                const cp_bytes = vm.utf8CodepointAt(s, cp_idx) orelse break;
                byte_pos += cp_bytes.len;
                cp_idx += 1;
            }
            return vm.intValue(@as(i64, @intCast(cp_idx)));
        }
        return vm.nilValue();
    }
    // Search for character
    if (std.meta.activeTag(args.items[1]) == .character) {
        const ch = args.items[1].character;
        var utf8_needle: [4]u8 = undefined;
        const needle_len = std.unicode.utf8Encode(ch, &utf8_needle) catch return error.InvalidUnicode;

        var best_byte: ?usize = null;
        var search_pos: usize = 0;
        while (search_pos <= byte_from) {
            const remaining = s[search_pos..];
            if (std.mem.indexOf(u8, remaining, utf8_needle[0..needle_len])) |idx| {
                const match_byte = search_pos + idx;
                if (match_byte <= byte_from) {
                    best_byte = match_byte;
                    search_pos = match_byte + 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        if (best_byte) |best| {
            var cp_idx: usize = 0;
            var byte_pos: usize = 0;
            while (byte_pos < best) {
                const cp_bytes = vm.utf8CodepointAt(s, cp_idx) orelse break;
                byte_pos += cp_bytes.len;
                cp_idx += 1;
            }
            return vm.intValue(@as(i64, @intCast(cp_idx)));
        }
        return vm.nilValue();
    }
    return error.TypeError;
}

/// starts-with? - true if s starts with substr.
pub fn str_starts_with_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const s_arg = args.items[0];
    const substr_arg = args.items[1];
    if (std.meta.activeTag(s_arg) != .string or std.meta.activeTag(substr_arg) != .string) return error.TypeError;
    const s = s_arg.string;
    const substr = substr_arg.string;
    return vm.boolValue(std.mem.startsWith(u8, s, substr));
}

/// ends-with? - true if s ends with substr.
pub fn str_ends_with_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const s_arg = args.items[0];
    const substr_arg = args.items[1];
    if (std.meta.activeTag(s_arg) != .string or std.meta.activeTag(substr_arg) != .string) return error.TypeError;
    const s = s_arg.string;
    const substr = substr_arg.string;
    return vm.boolValue(std.mem.endsWith(u8, s, substr));
}

/// includes? - true if s includes substr.
pub fn str_includes_q(self: *const Value, args: *const list.List, _: *Env) anyerror!Value {
    _ = self;
    if (args.items.len != 2) return error.ArityError;
    const s_arg = args.items[0];
    const substr_arg = args.items[1];
    if (std.meta.activeTag(s_arg) != .string or std.meta.activeTag(substr_arg) != .string) return error.TypeError;
    const s = s_arg.string;
    const substr = substr_arg.string;
    return vm.boolValue(std.mem.indexOf(u8, s, substr) != null);
}

/// Register clojure.string namespace built-in functions.
pub fn registerStringNamespaceFunctions(env: *Env) anyerror!void {
    try env.put("upper-case", vm.builtinFnValue(str_upper_case));
    try env.put("lower-case", vm.builtinFnValue(str_lower_case));
    try env.put("capitalize", vm.builtinFnValue(str_capitalize));
    try env.put("trim", vm.builtinFnValue(str_trim));
    try env.put("triml", vm.builtinFnValue(str_triml));
    try env.put("trimr", vm.builtinFnValue(str_trimr));
    try env.put("trim-newline", vm.builtinFnValue(str_trim_newline));
    try env.put("blank?", vm.builtinFnValue(str_blank_q));
    try env.put("index-of", vm.builtinFnValue(str_index_of));
    try env.put("last-index-of", vm.builtinFnValue(str_last_index_of));
    try env.put("starts-with?", vm.builtinFnValue(str_starts_with_q));
    try env.put("ends-with?", vm.builtinFnValue(str_ends_with_q));
    try env.put("includes?", vm.builtinFnValue(str_includes_q));
}

// ===== Unit Tests =====
const testEnv = test_utils.testEnv;
const makeArgs = test_utils.makeArgs;
const testSelf = test_utils.testSelf;

test "strings::str: single string strips quotes" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_str(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .string);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello"));
}

test "strings::str: concatenates multiple values" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s1 = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s1, std.heap.page_allocator);
    var s2 = try vm.stringValue(std.heap.page_allocator, "world");
    defer vm.valueDeinit(&s2, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s1, s2 });
    var result = core_str(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "helloworld"));
}

test "strings::str: integer converted to string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(42) });
    var result = core_str(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "42"));
}

test "strings::str: no args returns empty string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{});
    var result = core_str(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, ""));
}

test "strings::utf8_valid_q: valid string" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = core_utf8_valid_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::utf8_valid_q: non-string returns error" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.intValue(1) });
    try std.testing.expectError(error.TypeError, core_utf8_valid_q(testSelf(), &args, &a));
}

// ===== clojure.string namespace unit tests =====

test "strings::upper_case: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_upper_case(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "HELLO"));
}

test "strings::lower_case: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "HELLO");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_lower_case(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello"));
}

test "strings::capitalize: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hELLO");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_capitalize(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "Hello"));
}

test "strings::capitalize: empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_capitalize(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, ""));
}

test "strings::trim: both sides" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "  hello  ");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trim(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello"));
}

test "strings::trim: empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trim(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, ""));
}

test "strings::trim: all whitespace" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "   ");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trim(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, ""));
}

test "strings::triml: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "  hello  ");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_triml(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello  "));
}

test "strings::trimr: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "  hello  ");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trimr(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "  hello"));
}

test "strings::trim_newline: basic" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello\n\n");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trim_newline(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello"));
}

test "strings::trim_newline: cr" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello\r");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_trim_newline(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.mem.eql(u8, result.string, "hello"));
}

test "strings::blank_q: nil" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ vm.nilValue() });
    var result = str_blank_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::blank_q: empty" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_blank_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::blank_q: whitespace" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "   ");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_blank_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::blank_q: text" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s });
    var result = str_blank_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "strings::starts_with_q: true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "hel");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_starts_with_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::starts_with_q: false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "world");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_starts_with_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "strings::ends_with_q: true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "lo");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_ends_with_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::ends_with_q: false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "xyz");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_ends_with_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "strings::includes_q: true" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello world");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "lo w");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_includes_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == true);
}

test "strings::includes_q: false" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello world");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var sub = try vm.stringValue(std.heap.page_allocator, "xyz");
    defer vm.valueDeinit(&sub, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, sub });
    var result = str_includes_q(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(result.bool == false);
}

test "strings::index_of: found" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello world");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var needle = try vm.stringValue(std.heap.page_allocator, "world");
    defer vm.valueDeinit(&needle, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, needle });
    var result = str_index_of(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 6);
}

test "strings::index_of: not found" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello world");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var needle = try vm.stringValue(std.heap.page_allocator, "xyz");
    defer vm.valueDeinit(&needle, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, needle });
    var result = str_index_of(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

test "strings::last_index_of: found" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello hello");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var needle = try vm.stringValue(std.heap.page_allocator, "hello");
    defer vm.valueDeinit(&needle, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, needle });
    var result = str_last_index_of(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .integer);
    try std.testing.expect(result.integer == 6);
}

test "strings::last_index_of: not found" {
    var a = testEnv();
    defer a.deinit(std.heap.page_allocator);
    var s = try vm.stringValue(std.heap.page_allocator, "hello world");
    defer vm.valueDeinit(&s, std.heap.page_allocator);
    var needle = try vm.stringValue(std.heap.page_allocator, "xyz");
    defer vm.valueDeinit(&needle, std.heap.page_allocator);
    const args = makeArgs(&[_]Value{ s, needle });
    var result = str_last_index_of(testSelf(), &args, &a) catch unreachable;
    defer vm.valueDeinit(&result, std.heap.page_allocator);
    try std.testing.expect(std.meta.activeTag(result) == .nil);
}

