// Unit tests for value.zig — extracted to keep value.zig under 1000 lines.
const std = @import("std");
const vm = @import("value.zig");
const Value = vm.Value;
const list = @import("list.zig");
const vec = @import("vector.zig");

const Allocator = std.mem.Allocator;

// Re-export constructors and types for test use
const nilValue = vm.nilValue;
const boolValue = vm.boolValue;
const intValue = vm.intValue;
const floatValue = vm.floatValue;
const bigIntValue = vm.bigIntValue;
const ratioValue = vm.ratioValue;
const decimalValue = vm.decimalValue;
const stringValue = vm.stringValue;
const charValue = vm.charValue;
const symValue = vm.symValue;
const keywordValue = vm.keywordValue;
const listValue = vm.listValue;
const vectorValue = vm.vectorValue;
const mapValue = vm.mapValue;
const setValue = vm.setValue;
const queueValue = vm.queueValue;
const atomValue = vm.atomValue;
const atomValueShared = Value.atomValueShared;
const utf8CodepointCount = Value.utf8CodepointCount;
const utf8CodepointByteOffset = Value.utf8CodepointByteOffset;
const utf8CodepointAt = Value.utf8CodepointAt;
const Env = vm.Env;
const Set = vm.Set;
const Map = vm.Map;
const Queue = vm.Queue;

test "value::intValue: creates integer value" {
    const v = intValue(42);
    try std.testing.expect(v.type == .integer);
    try std.testing.expect(v.integer == 42);
}

test "value::floatValue: creates float value" {
    const v = floatValue(3.14);
    try std.testing.expect(v.type == .float);
    try std.testing.expect(v.float == 3.14);
}

test "value::boolValue: true and false" {
    const t = boolValue(true);
    try std.testing.expect(t.type == .bool);
    try std.testing.expect(t.bool);
    const f = boolValue(false);
    try std.testing.expect(f.type == .bool);
    try std.testing.expect(!f.bool);
}

test "value::nilValue: creates nil" {
    const v = nilValue();
    try std.testing.expect(v.type == .nil);
}

test "value::stringValue: creates string" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "hello");
    defer v.deinit(a);
    try std.testing.expect(v.type == .string);
    try std.testing.expect(std.mem.eql(u8, v.string, "hello"));
}

test "value::stringValue: rejects invalid UTF-8" {
    const a = std.heap.page_allocator;
    const invalid: []const u8 = &[_]u8{ 0xFF, 0xFF };
    try std.testing.expectError(error.InvalidUTF8, stringValue(a, invalid));
}

test "value::symValue: creates symbol" {
    const a = std.heap.page_allocator;
    var v = try symValue(a, "foo-bar");
    defer v.deinit(a);
    try std.testing.expect(v.type == .symbol);
    try std.testing.expect(std.mem.eql(u8, v.symbol, "foo-bar"));
}

test "value::keywordValue: creates keyword" {
    const a = std.heap.page_allocator;
    var v = try keywordValue(a, "foo");
    defer v.deinit(a);
    try std.testing.expect(v.type == .keyword);
    try std.testing.expect(std.mem.eql(u8, v.keyword, "foo"));
}

test "value::isTruthy: nil is falsy" {
    try std.testing.expect(!nilValue().isTruthy());
}

test "value::isTruthy: false is falsy" {
    try std.testing.expect(!boolValue(false).isTruthy());
}

test "value::isTruthy: true is truthy" {
    try std.testing.expect(boolValue(true).isTruthy());
}

test "value::isTruthy: numbers are truthy" {
    try std.testing.expect(intValue(0).isTruthy());
    try std.testing.expect(intValue(42).isTruthy());
    try std.testing.expect(floatValue(0.0).isTruthy());
}

test "value::equals: integers" {
    try std.testing.expect(intValue(5).equals(intValue(5)));
    try std.testing.expect(!intValue(5).equals(intValue(6)));
    try std.testing.expect(!intValue(5).equals(floatValue(5.0)));
}

test "value::equals: booleans" {
    try std.testing.expect(boolValue(true).equals(boolValue(true)));
    try std.testing.expect(!boolValue(true).equals(boolValue(false)));
    try std.testing.expect(!boolValue(true).equals(nilValue()));
}

test "value::equals: nils" {
    try std.testing.expect(nilValue().equals(nilValue()));
}

test "value::equals: floats" {
    try std.testing.expect(floatValue(1.5).equals(floatValue(1.5)));
    try std.testing.expect(!floatValue(1.5).equals(floatValue(2.0)));
}

test "value::equals: sets (order independent)" {
    const a = std.heap.page_allocator;

    var s1: Set = .empty;
    try s1.append(a, intValue(1));
    try s1.append(a, intValue(2));
    var v1 = setValue(s1);

    var s2: Set = .empty;
    try s2.append(a, intValue(2));
    try s2.append(a, intValue(1));
    var v2 = setValue(s2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));
}

test "value::equals: maps (order independent)" {
    const a = std.heap.page_allocator;

    var m1: Map = .empty;
    try m1.append(a, .{ .key = intValue(1), .value = intValue(10) });
    try m1.append(a, .{ .key = intValue(2), .value = intValue(20) });
    var v1 = mapValue(m1);

    // Same keys/values, different insertion order
    var m2: Map = .empty;
    try m2.append(a, .{ .key = intValue(2), .value = intValue(20) });
    try m2.append(a, .{ .key = intValue(1), .value = intValue(10) });
    var v2 = mapValue(m2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    // Different value for same key
    var m3: Map = .empty;
    try m3.append(a, .{ .key = intValue(1), .value = intValue(99) });
    try m3.append(a, .{ .key = intValue(2), .value = intValue(20) });
    var v3 = mapValue(m3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));

    // Different size (subset)
    var m4: Map = .empty;
    try m4.append(a, .{ .key = intValue(1), .value = intValue(10) });
    var v4 = mapValue(m4);
    defer v4.deinit(a);

    try std.testing.expect(!v1.equals(v4));
}

test "value::equals: lists (deep comparison)" {
    const a = std.heap.page_allocator;

    // Equal lists
    var l1: list.List = .empty;
    try l1.append(a, intValue(1));
    try l1.append(a, intValue(2));
    try l1.append(a, intValue(3));
    var v1 = listValue(l1);

    var l2: list.List = .empty;
    try l2.append(a, intValue(1));
    try l2.append(a, intValue(2));
    try l2.append(a, intValue(3));
    var v2 = listValue(l2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    // Different values
    var l3: list.List = .empty;
    try l3.append(a, intValue(1));
    try l3.append(a, intValue(9));
    try l3.append(a, intValue(3));
    var v3 = listValue(l3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));

    // Different lengths
    var l4: list.List = .empty;
    try l4.append(a, intValue(1));
    try l4.append(a, intValue(2));
    var v4 = listValue(l4);
    defer v4.deinit(a);

    try std.testing.expect(!v1.equals(v4));

    // Empty lists
    const l5: list.List = .empty;
    const v5 = listValue(l5);
    const l6: list.List = .empty;
    const v6 = listValue(l6);

    try std.testing.expect(v5.equals(v6));
}

test "value::equals: vectors (deep comparison)" {
    const a = std.heap.page_allocator;

    // Equal vectors
    var vec1: vec.Vector = .empty;
    try vec1.append(a, intValue(1));
    try vec1.append(a, intValue(2));
    var v1 = vectorValue(vec1);

    var vec2: vec.Vector = .empty;
    try vec2.append(a, intValue(1));
    try vec2.append(a, intValue(2));
    var v2 = vectorValue(vec2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    // Different values
    var vec3: vec.Vector = .empty;
    try vec3.append(a, intValue(1));
    try vec3.append(a, intValue(9));
    var v3 = vectorValue(vec3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));

    // Different lengths
    var vec4: vec.Vector = .empty;
    try vec4.append(a, intValue(1));
    var v4 = vectorValue(vec4);
    defer v4.deinit(a);

    try std.testing.expect(!v1.equals(v4));

    // Empty vectors
    const vec5: vec.Vector = .empty;
    const v5 = vectorValue(vec5);
    const vec6: vec.Vector = .empty;
    const v6 = vectorValue(vec6);

    try std.testing.expect(v5.equals(v6));
}

test "value::equals: nested structures" {
    const a = std.heap.page_allocator;

    // Nested vector in vector: [[1 2] [3 4]]
    var inner1: vec.Vector = .empty;
    try inner1.append(a, intValue(1));
    try inner1.append(a, intValue(2));
    var inner2: vec.Vector = .empty;
    try inner2.append(a, intValue(3));
    try inner2.append(a, intValue(4));

    var outer1: vec.Vector = .empty;
    try outer1.append(a, vectorValue(inner1));
    try outer1.append(a, vectorValue(inner2));
    var v1 = vectorValue(outer1);

    var inner3: vec.Vector = .empty;
    try inner3.append(a, intValue(1));
    try inner3.append(a, intValue(2));
    var inner4: vec.Vector = .empty;
    try inner4.append(a, intValue(3));
    try inner4.append(a, intValue(4));

    var outer2: vec.Vector = .empty;
    try outer2.append(a, vectorValue(inner3));
    try outer2.append(a, vectorValue(inner4));
    var v2 = vectorValue(outer2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    // Nested map in map: {:a {:b 1}}
    var inner_map1: Map = .empty;
    try inner_map1.append(a, .{ .key = intValue(1), .value = intValue(10) });
    var outer_map1: Map = .empty;
    try outer_map1.append(a, .{ .key = intValue(2), .value = mapValue(inner_map1) });
    var mv1 = mapValue(outer_map1);

    var inner_map2: Map = .empty;
    try inner_map2.append(a, .{ .key = intValue(1), .value = intValue(10) });
    var outer_map2: Map = .empty;
    try outer_map2.append(a, .{ .key = intValue(2), .value = mapValue(inner_map2) });
    var mv2 = mapValue(outer_map2);

    defer mv1.deinit(a);
    defer mv2.deinit(a);

    try std.testing.expect(mv1.equals(mv2));
}

test "value::equals: map with string keys" {
    const a = std.heap.page_allocator;

    var m1: Map = .empty;
    try m1.append(a, .{ .key = try stringValue(a, "hello"), .value = intValue(1) });
    try m1.append(a, .{ .key = try stringValue(a, "world"), .value = intValue(2) });
    var v1 = mapValue(m1);

    var m2: Map = .empty;
    try m2.append(a, .{ .key = try stringValue(a, "world"), .value = intValue(2) });
    try m2.append(a, .{ .key = try stringValue(a, "hello"), .value = intValue(1) });
    var v2 = mapValue(m2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));
}

test "value::equals: queues" {
    const a = std.heap.page_allocator;

    var q1: Queue = .empty;
    try q1.append(a, intValue(1));
    try q1.append(a, intValue(2));
    var v1 = queueValue(q1);

    var q2: Queue = .empty;
    try q2.append(a, intValue(1));
    try q2.append(a, intValue(2));
    var v2 = queueValue(q2);

    defer v1.deinit(a);
    defer v2.deinit(a);

    try std.testing.expect(v1.equals(v2));

    var q3: Queue = .empty;
    try q3.append(a, intValue(2));
    try q3.append(a, intValue(1));
    var v3 = queueValue(q3);
    defer v3.deinit(a);

    try std.testing.expect(!v1.equals(v3));
}

test "value::utf8CodepointCount: ASCII" {
    try std.testing.expect(utf8CodepointCount("hello") == 5);
    try std.testing.expect(utf8CodepointCount("") == 0);
    try std.testing.expect(utf8CodepointCount("a") == 1);
}

test "value::utf8CodepointCount: multi-byte UTF-8" {
    try std.testing.expect(utf8CodepointCount("õäö") == 3);
    try std.testing.expect(utf8CodepointCount("😀") == 1);
    try std.testing.expect(utf8CodepointCount("古池や") == 3);
}

test "value::utf8CodepointByteOffset: ASCII" {
    try std.testing.expect(utf8CodepointByteOffset("hello", 0).? == 0);
    try std.testing.expect(utf8CodepointByteOffset("hello", 2).? == 2);
    try std.testing.expect(utf8CodepointByteOffset("hello", 4).? == 4);
    try std.testing.expect(utf8CodepointByteOffset("hello", 5) == null);
}

test "value::utf8CodepointByteOffset: multi-byte UTF-8" {
    try std.testing.expect(utf8CodepointByteOffset("õäö", 0).? == 0);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 1).? == 2);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 2).? == 4);
    try std.testing.expect(utf8CodepointByteOffset("õäö", 3) == null);
}

test "value::utf8CodepointAt: ASCII" {
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("hello", 0).?, "h"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("hello", 4).?, "o"));
    try std.testing.expect(utf8CodepointAt("hello", 5) == null);
}

test "value::utf8CodepointAt: multi-byte UTF-8" {
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 0).?, "õ"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 1).?, "ä"));
    try std.testing.expect(std.mem.eql(u8, utf8CodepointAt("õäö", 2).?, "ö"));
    try std.testing.expect(utf8CodepointAt("õäö", 3) == null);
}

test "value::clone: integer" {
    const a = std.heap.page_allocator;
    const v = intValue(42);
    const c = try v.clone(a);
    try std.testing.expect(c.type == .integer);
    try std.testing.expect(c.integer == 42);
}

test "value::clone: string round-trip" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "test");
    var c = try v.clone(a);
    defer v.deinit(a);
    defer c.deinit(a);
    try std.testing.expect(std.mem.eql(u8, c.string, "test"));
}

test "value::clone: atom shares data" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    var c = try v.clone(a);
    defer v.deinit(a);
    defer c.deinit(a);
    try std.testing.expect(v.atom == c.atom);
}

test "value::atomValue: ref count is 1" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    defer v.deinit(a);
    try std.testing.expect(v.atom.?.ref_count == 1);
}

test "value::atomValueShared: increments ref count" {
    const a = std.heap.page_allocator;
    const init = intValue(42);
    var v = try atomValue(a, init);
    const data = v.atom.?;
    var shared = atomValueShared(data);
    defer v.deinit(a);
    defer shared.deinit(a);
    try std.testing.expect(data.ref_count == 2);
}

test "value::fmt: nil" {
    const a = std.heap.page_allocator;
    const s = try nilValue().fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "nil"));
}

test "value::fmt: bool" {
    const a = std.heap.page_allocator;
    const s1 = try boolValue(true).fmt(a);
    defer a.free(s1);
    try std.testing.expect(std.mem.eql(u8, s1, "true"));
    const s2 = try boolValue(false).fmt(a);
    defer a.free(s2);
    try std.testing.expect(std.mem.eql(u8, s2, "false"));
}

test "value::fmt: integer" {
    const a = std.heap.page_allocator;
    const s = try intValue(42).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "42"));
}

test "value::fmt: string" {
    const a = std.heap.page_allocator;
    var v = try stringValue(a, "hello");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\"hello\""));
}

test "value::fmt: keyword" {
    const a = std.heap.page_allocator;
    var v = try keywordValue(a, "foo");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, ":foo"));
}

test "value::fmt: symbol" {
    const a = std.heap.page_allocator;
    var v = try symValue(a, "x");
    defer v.deinit(a);
    const s = try v.fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "x"));
}

test "value::Env::put and get" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);

    try env.put("x", intValue(42));
    const val = env.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.type == .integer);
    try std.testing.expect(val.?.integer == 42);
}

test "value::Env::get returns null for missing key" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);
    try std.testing.expect(env.get("missing") == null);
}

test "value::Env::has" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);
    try env.put("x", intValue(1));
    try std.testing.expect(env.has("x"));
    try std.testing.expect(!env.has("y"));
}

test "value::Env::parent lookup" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    defer parent.deinit(a);
    defer child.deinit(a);

    try parent.put("x", intValue(42));
    const val = child.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.integer == 42);
}

test "value::Env::child shadows parent" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    defer parent.deinit(a);
    defer child.deinit(a);

    try parent.put("x", intValue(42));
    try child.put("x", intValue(99));
    const val = child.get("x");
    try std.testing.expect(val.?.integer == 99);
}

test "value::Env::put overwrites existing" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    defer env.deinit(a);

    try env.put("x", intValue(1));
    try env.put("x", intValue(2));
    const val = env.get("x");
    try std.testing.expect(val.?.integer == 2);
}

test "value::Env::clone" {
    const a = std.heap.page_allocator;
    var env: Env = Env.init(a);
    try env.put("x", intValue(42));
    var cloned = try env.clone(a);
    defer env.deinit(a);
    defer cloned.deinit(a);

    const val = cloned.get("x");
    try std.testing.expect(val != null);
    try std.testing.expect(val.?.integer == 42);
}

test "value::Env::clone preserves parent" {
    const a = std.heap.page_allocator;
    var parent: Env = Env.init(a);
    var child: Env = Env.init(a);
    child.parent = &parent;
    try parent.put("root", intValue(1));
    try child.put("local", intValue(2));
    var cloned = try child.clone(a);
    defer parent.deinit(a);
    defer child.deinit(a);
    defer cloned.deinit(a);

    try std.testing.expect(cloned.get("local").?.integer == 2);
    try std.testing.expect(cloned.get("root").?.integer == 1);
}

// ===== Character Type Tests =====

test "value::charValue: creates ASCII char" {
    const v = charValue('A');
    try std.testing.expect(v.type == .character);
    try std.testing.expect(v.character == 65);
}

test "value::charValue: creates zero char" {
    const v = charValue(0);
    try std.testing.expect(v.type == .character);
    try std.testing.expect(v.character == 0);
}

test "value::charValue: creates unicode char" {
    const v = charValue(0x00F6); // ö
    try std.testing.expect(v.type == .character);
    try std.testing.expect(v.character == 0x00F6);
}

test "value::charValue: creates emoji codepoint" {
    const v = charValue(0x1F468); // 👨
    try std.testing.expect(v.type == .character);
    try std.testing.expect(v.character == 0x1F468);
}

test "value::charValue: deinit is no-op" {
    const a = std.heap.page_allocator;
    var v = charValue('A');
    v.deinit(a); // should not crash or leak
}

test "value::equals: chars same" {
    try std.testing.expect(charValue('A').equals(charValue('A')));
    try std.testing.expect(charValue(0x00F6).equals(charValue(0x00F6)));
    try std.testing.expect(charValue(0).equals(charValue(0)));
}

test "value::equals: chars different" {
    try std.testing.expect(!charValue('A').equals(charValue('B')));
    try std.testing.expect(!charValue(0x00F6).equals(charValue(0x00E4)));
}

test "value::equals: char vs other types" {
    try std.testing.expect(!charValue('A').equals(intValue(65)));
    try std.testing.expect(!charValue('A').equals(nilValue()));
    try std.testing.expect(!charValue(0).equals(intValue(0)));
}

test "value::clone: char" {
    const a = std.heap.page_allocator;
    const v = charValue(0x1F468);
    var c = try v.clone(a);
    try std.testing.expect(c.type == .character);
    try std.testing.expect(c.character == 0x1F468);
    c.deinit(a);
}

test "value::isTruthy: char is truthy" {
    try std.testing.expect(charValue('A').isTruthy());
    try std.testing.expect(charValue(0).isTruthy()); // even null char is truthy
    try std.testing.expect(charValue(0x1F468).isTruthy());
}

test "value::fmt: char ASCII" {
    const a = std.heap.page_allocator;
    const s = try charValue('A').fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\A"));
}

test "value::fmt: char lowercase" {
    const a = std.heap.page_allocator;
    const s = try charValue('a').fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\a"));
}

test "value::fmt: char newline" {
    const a = std.heap.page_allocator;
    const s = try charValue(10).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\newline"));
}

test "value::fmt: char tab" {
    const a = std.heap.page_allocator;
    const s = try charValue(9).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\tab"));
}

test "value::fmt: char space" {
    const a = std.heap.page_allocator;
    const s = try charValue(32).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\space"));
}

test "value::fmt: char return" {
    const a = std.heap.page_allocator;
    const s = try charValue(13).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\return"));
}

test "value::fmt: char formfeed" {
    const a = std.heap.page_allocator;
    const s = try charValue(12).fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\formfeed"));
}

test "value::fmt: char special punctuation" {
    const a = std.heap.page_allocator;
    const s = try charValue('!').fmt(a);
    defer a.free(s);
    try std.testing.expect(std.mem.eql(u8, s, "\\!"));
}

test "value::fmt: char unicode ö" {
    const a = std.heap.page_allocator;
    const s = try charValue(0x00F6).fmt(a); // ö
    defer a.free(s);
    // Should be \ö (backslash + UTF-8 bytes for ö)
    try std.testing.expect(s.len == 3); // 1 backslash + 2 bytes for ö
    try std.testing.expect(s[0] == '\\');
}

test "value::fmt: char emoji" {
    const a = std.heap.page_allocator;
    const s = try charValue(0x1F468).fmt(a); // 👨
    defer a.free(s);
    // Should be \👨 (backslash + 4 bytes for emoji)
    try std.testing.expect(s.len == 5); // 1 backslash + 4 bytes for 👨
    try std.testing.expect(s[0] == '\\');
}

test "value::fmt: char zero" {
    const a = std.heap.page_allocator;
    const s = try charValue(0).fmt(a);
    defer a.free(s);
    // Null char is printable ASCII range, formatted as \\0
    try std.testing.expect(s.len == 2);
    try std.testing.expect(s[0] == '\\');
    try std.testing.expect(s[1] == 0);
}

const gc_mod = @import("gc.zig");
const phm = @import("persistent_hash_map.zig");
const gc_scan = @import("gc_scan.zig");
test "value::Env: function closures with captured envs survive GC" {
    const allocator = std.heap.page_allocator;

    var gc = gc_mod.GC.init(allocator);
    defer gc.deinit();
    const prev_gc2 = gc_mod.current_gc;
    gc_mod.current_gc = &gc;
    defer gc_mod.current_gc = prev_gc2;
    const gc_alloc = gc.allocator();

    // Create root env (heap-allocated so GC can discover it)
    const root_env = try gc_alloc.create(Env);
    errdefer { root_env.deinit(gc_alloc); gc_alloc.destroy(root_env); }
    root_env.* = Env.init(gc_alloc);
    gc.setObjectType(@as(*anyopaque, @ptrCast(root_env)), gc_mod.GCObjectType.env);
    gc.addRoot(@as(*anyopaque, @ptrCast(root_env)));

    // Create a function that captures the root env
    // The fn's env is heap-allocated *Env — this is what the GC bug affected
    var arities: std.ArrayListUnmanaged(vm.Arity) = .empty;
    errdefer gc_alloc.free(arities.items);
    try arities.append(gc_alloc, vm.Arity{
        .params = list.empty(),
        .body = list.empty(),
        .rest_name = null,
    });

    const fn_env = try root_env.clone(gc_alloc);
    var fn_val = try vm.fnValue(gc_alloc, arities, fn_env, false);
    errdefer fn_val.deinit(gc_alloc);

    // Store the function in root env
    try root_env.put("my_fn", fn_val);
    fn_val = vm.nilValue(); // transfer ownership

    // Run GC — the fn's captured env must survive
    gc.collect(gc_scan.valueScanFn);

    // Retrieve the function and verify its env is still valid
    const retrieved = root_env.get("my_fn");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.type == .function);

    // The fn's env should still be accessible and not corrupt
    const fn_data = retrieved.?.function orelse unreachable;
    _ = fn_data.env; // accessing the pointer should not crash
    try std.testing.expect(fn_data.env.entries.count == 0); // empty env (clone of empty root)
}

test "value::Env: nested child envs survive GC" {
    const allocator = std.heap.page_allocator;

    // Create a GC instance for this test
    var gc = gc_mod.GC.init(allocator);
    defer gc.deinit();
    // Set global current_gc so HAMT allocation helpers can set obj_type
    const prev_gc = gc_mod.current_gc;
    gc_mod.current_gc = &gc;
    defer gc_mod.current_gc = prev_gc;
    const gc_alloc = gc.allocator();

    // Create root env (heap-allocated so GC can discover it)
    const root_env = try gc_alloc.create(Env);
    errdefer { root_env.deinit(gc_alloc); gc_alloc.destroy(root_env); }
    root_env.* = Env.init(gc_alloc);
    gc.setObjectType(@as(*anyopaque, @ptrCast(root_env)), gc_mod.GCObjectType.env);
    gc.addRoot(@as(*anyopaque, @ptrCast(root_env)));

    // Add 50 values to the root env
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const fname = try std.fmt.allocPrint(gc_alloc, "fn_{d}", .{i});
        errdefer gc_alloc.free(fname);
        const val = intValue(@as(i64, @intCast(i)));
        try root_env.put(fname, val);
    }

    // Verify count before GC
    try std.testing.expectEqual(@as(usize, 5), root_env.entries.count);

    // Create 50 layers of child envs, each adding a local binding
    var current_env_ptr: *Env = root_env;
    var child_envs: std.ArrayList(*Env) = .empty;
    defer {
        for (child_envs.items) |ce| {
            ce.deinit(gc_alloc);
            gc_alloc.destroy(ce);
        }
        child_envs.deinit(allocator);
    }

    i = 0;
    while (i < 5) : (i += 1) {
        const child = try gc_alloc.create(Env);
        child.* = try current_env_ptr.clone(gc_alloc);
        gc.setObjectType(@as(*anyopaque, @ptrCast(child)), gc_mod.GCObjectType.env);
        gc.addRoot(@as(*anyopaque, @ptrCast(child)));
        try child_envs.append(allocator, child);

        const local_name = try std.fmt.allocPrint(gc_alloc, "local_{d}", .{i});
        const local_val = intValue(@as(i64, @intCast(i * 1000)));
        try child.put(local_name, local_val);
        gc_alloc.free(local_name);
        current_env_ptr = child;
    }

    // Run GC twice (generational protection requires 2 cycles)
    gc.verbose = true;
    gc.collect(gc_scan.valueScanFn);
    gc.collect(gc_scan.valueScanFn);

    // Verify root env still has all 50 entries after GC
    try std.testing.expectEqual(@as(usize, 5), root_env.entries.count);

    // Verify all original values are still accessible from root env
    i = 0;
    while (i < 5) : (i += 1) {
        const fname = try std.fmt.allocPrint(allocator, "fn_{d}", .{i});
        defer allocator.free(fname);
        const found = root_env.get(fname);
        try std.testing.expect(found != null);
        try std.testing.expect(found.?.integer == @as(i64, @intCast(i)));
    }

    // Verify values accessible through parent chain from deepest env
    i = 0;
    while (i < 5) : (i += 1) {
        const fname = try std.fmt.allocPrint(allocator, "fn_{d}", .{i});
        defer allocator.free(fname);
        const found = current_env_ptr.get(fname);
        try std.testing.expect(found != null);
    }

    // Verify local bindings from deepest env
    i = 0;
    while (i < 5) : (i += 1) {
        const local_name = try std.fmt.allocPrint(allocator, "local_{d}", .{i});
        defer allocator.free(local_name);
        const found = current_env_ptr.get(local_name);
        try std.testing.expect(found != null);
    }
}
