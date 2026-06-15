// persistent_hash_map.zig — Persistent immutable HashMap using Hash Array Mapped Trie (HAMT).
//
// Based on Phil Bagwell's HAMT algorithm, same design as Clojure's PersistentHashMap.
// Uses path copying for structural sharing — mutations return new maps that share
// unchanged subtrees with the original.
//
// Node types:
//   BitmapIndexedNode — sparse, bitmap tracks occupied slots (up to 16 entries)
//   ArrayNode — dense, fixed 32-slot array (16+ entries)
//   HashCollisionNode — all keys share the same full hash
//
// Nil keys are handled separately (has_null flag + null_value field) since
// the trie structure cannot represent a null key.
//
// All nodes are allocated through the GC allocator. The GC tracks them via
// the GCObjectType.hash_map_node type tag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig");
const gc = @import("gc.zig");
const list = @import("list.zig");

// ============================================================
// GC-aware allocation helpers
// ============================================================

/// Allocate a Node and register it with the GC as hash_map_node.
fn newNode(allocator: Allocator, data: Node) *Node {
    const node = allocator.create(Node) catch @panic("OOM");
    node.* = data;
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(node)), gc.GCObjectType.hash_map_node);
    }
    return node;
}

/// Allocate a Kvp array and register it with the GC.
fn newKvpArray(allocator: Allocator, items: []const Kvp) []Kvp {
    const arr = allocator.dupe(Kvp, items) catch @panic("OOM");
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(arr.ptr)), gc.GCObjectType.hash_map_kvp_array);
    }
    return arr;
}

/// Allocate a sub_nodes array and register it with the GC.
fn newSubNodesArray(allocator: Allocator, items: []const (?*Node)) []?*Node {
    const arr = allocator.dupe(?*Node, items) catch @panic("OOM");
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(arr.ptr)), gc.GCObjectType.hash_map_sub_nodes);
    }
    return arr;
}

/// Allocate a Kvp array of given length and register it with the GC.
fn newKvpArrayLen(allocator: Allocator, len: usize) []Kvp {
    const arr = allocator.alloc(Kvp, len) catch @panic("OOM");
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(arr.ptr)), gc.GCObjectType.hash_map_kvp_array);
    }
    return arr;
}

/// Allocate a sub_nodes array of given length and register it with the GC.
fn newSubNodesArrayLen(allocator: Allocator, len: usize) []?*Node {
    const arr = allocator.alloc(?*Node, len) catch @panic("OOM");
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(arr.ptr)), gc.GCObjectType.hash_map_sub_nodes);
    }
    return arr;
}

// ============================================================
// Hash code computation for Value types
// Mirrors Clojure's hasheq behavior
// ============================================================

/// Compute a 32-bit hash code for a Value, matching Clojure's hasheq semantics.
pub fn valueHash(val: Value) i32 {
    return switch (val.type) {
        .nil => 0,
        .bool => if (val.bool_val) 1 else 0,
        .integer => hashInt(val.int_val),
        .float => hashFloat(val.float_val),
        .bigint => {
            if (val.bigint_val) |bi| return hashBigInt(bi.*);
            return 0;
        },
        .ratio => {
            if (val.ratio_val) |r| {
                return hashBigInt(r.num) ^ hashBigInt(r.den);
            }
            return 0;
        },
        .decimal => {
            if (val.decimal_val) |d| return hashBigInt(d.unscaled);
            return 0;
        },
        .string => hashString(val.str_val),
        .regex => hashString(val.re_pattern),
        .character => @as(i32, @intCast(val.char_val)),
        .symbol => hashString(val.sym_val),
        .keyword => hashKeyword(val.kw_val),
        .list => hashCollection(val.list_val.items),
        .vector => hashCollection(val.vec_val.items),
        .map => hashMapEntries(val.map_val.items),
        .set => hashCollection(val.set_val.items),
        .queue => hashCollection(val.queue_val.items),
        .function => hashIdentity(),
        .builtin_fn => hashIdentity(),
        .lazy_seq => hashIdentity(),
        .cons => hashIdentity(),
        .atom => hashIdentity(),
        .wrapped => @as(i32, @intCast(val.wrapped_val)),
        .reduced => {
            if (val.reduced_val) |data| return valueHash(data.*);
            return 0;
        },
    };
}

fn hashInt(v: i64) i32 {
    const h: i32 = @intCast(v);
    return h ^ (h >> 16);
}

fn hashFloat(v: f64) i32 {
    const bits = @as(u64, @bitCast(v));
    const l: i32 = @intCast(@as(u32, @intCast(bits)));
    const h: i32 = @intCast(@as(u32, @intCast(bits >> 32)));
    return l ^ h;
}

fn hashString(s: []const u8) i32 {
    var h: i32 = 0;
    for (s) |c| {
        const result = @mulWithOverflow(h, 31);
        h = result[0] + @as(i32, @intCast(c));
    }
    return h ^ @as(i32, @intCast(s.len));
}

fn hashKeyword(s: []const u8) i32 {
    var h: i32 = 58; // ':' = 58
    for (s) |c| {
        h = 31 * h + @as(i32, @intCast(c));
    }
    return h ^ @as(i32, @intCast(s.len + 1));
}

fn hashCollection(items: []const Value) i32 {
    var h: i32 = 1;
    for (items) |item| {
        h = h * 31 + valueHash(item);
    }
    return h;
}

fn hashMapEntries(entries: []const Value.MapEntry) i32 {
    var h: i32 = 0;
    for (entries) |entry| {
        h = h + (valueHash(entry.key) ^ valueHash(entry.value));
    }
    return h;
}

fn hashIdentity() i32 {
    return 0;
}

fn hashBigInt(bi: anytype) i32 {
    // Simple hash from BigInt limbs
    var h: i32 = 9;
    const limbs = bi.limbs;
    var i: usize = 0;
    while (i < limbs.len) : (i += 1) {
        h = h * 31 + @as(i32, @intCast(@as(u32, @intCast(limbs[i]))));
    }
    return h;
}

// ============================================================
// Node findPtr dispatch (forward declaration for node types)
// ============================================================

pub fn nodeFindPtr(node: *Node, shift: u5, hash: i32, key: Value) ?*const Value {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.findPtr(shift, hash, key),
        .array => |*n| return n.findPtr(shift, hash, key),
        .hash_collision => |*n| return n.findPtr(hash, key),
    }
}

// ============================================================
// Node types
// ============================================================

/// 5 bits per level, 32-way branching
const SHIFT_BITS: u5 = 5;

/// Extract 5-bit chunk of hash at given shift level.
fn mask(hash: i32, shift: u5) usize {
    const uhash: u32 = @bitCast(hash);
    const result = @as(usize, @intCast((uhash >> shift) & 0x1F));
    return result;
}

/// Compute bitmap bit position from hash and shift.
fn bitpos(hash: i32, shift: u5) u32 {
    const m: u5 = @intCast(mask(hash, shift));
    return @as(u32, 1) << @as(u5, m);
}

/// Count set bits in a u32.
fn popCount(val: u32) usize {
    var v = val;
    v -= ((v >> 1) & 0x55555555);
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
    v = (v + (v >> 4)) & 0x0F0F0F0F;
    v += v >> 8;
    v += v >> 16;
    return @as(usize, @intCast(v & 0x0000003F));
}

/// Count set bits below a given bit position.
fn indexBelow(bitmap: u32, bit: u32) usize {
    return popCount(bitmap & (bit - 1));
}

/// Simple flag to track whether a leaf was added/removed.
const LeafFlag = struct {
    _set: bool = false,
    pub fn set(self: *LeafFlag, val: bool) void { self._set = val; }
    pub fn get(self: *const LeafFlag) bool { return self._set; }
};

/// Node tag for type discrimination.
const NodeTag = enum(u8) {
    bitmap_indexed = 0,
    array = 1,
    hash_collision = 2,
};

/// A single key-value pair stored in a node.
pub const Kvp = struct {
    key: Value,
    val: Value,
};

/// BitmapIndexedNode — sparse node with bitmap tracking occupied slots.
const BitmapIndexedNode = struct {
    bitmap: u32,
    /// Flat array of [key, val, key, val, ...].
    /// key.type == .nil means this slot holds a sub-node (sub_nodes[i] is the node).
    /// key.type != .nil means this slot holds a leaf key-value pair.
    array: []Kvp,
    /// Parallel array: sub_nodes[i] is non-null when array[i].key.type == .nil.
    sub_nodes: []?*Node,

    pub fn findLeaf(self: *const BitmapIndexedNode, shift: u5, hash: i32, key: Value) ?Value {
        const bit = bitpos(hash, shift);
        if (key.type == .symbol) {
        }
        if ((self.bitmap & bit) == 0) return null;

        const idx = indexBelow(self.bitmap, bit);
        const kvp = &self.array[idx];

        if (kvp.key.type == .nil) {
            return nodeFindLeaf(self.sub_nodes[idx].?, shift + SHIFT_BITS, hash, key);
        }
        if (kvp.key.equals(key)) return kvp.val;
        if (key.type == .symbol) {
        }
        return null;
    }

    pub fn findPtr(self: *const BitmapIndexedNode, shift: u5, hash: i32, key: Value) ?*const Value {
        const bit = bitpos(hash, shift);
        if ((self.bitmap & bit) == 0) return null;
        const idx = indexBelow(self.bitmap, bit);
        const kvp = &self.array[idx];
        if (kvp.key.type == .nil) {
            return nodeFindPtr(self.sub_nodes[idx].?, shift + SHIFT_BITS, hash, key);
        }
        if (kvp.key.equals(key)) return &kvp.val;
        return null;
    }

    pub fn doAssoc(self: *const BitmapIndexedNode, allocator: Allocator, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
        const bit = bitpos(hash, shift);
        const exists = (self.bitmap & bit) != 0;

        if (exists) {
            const idx = indexBelow(self.bitmap, bit);
            const existing_kvp = &self.array[idx];

            if (existing_kvp.key.type == .nil) {
                // Sub-node collision — recurse
                const sub_node = self.sub_nodes[idx].?;
                const new_sub = try nodeAssoc(sub_node, allocator, shift + SHIFT_BITS, hash, key, val, addedLeaf);
                if (sub_node == new_sub) return self.cloneNode(allocator);
                return createBitmapWithSub(allocator, self, idx, new_sub);
            }

            if (existing_kvp.key.equals(key)) {
                if (existing_kvp.val.equals(val)) return self.cloneNode(allocator);
                return createBitmapWithValue(allocator, self, idx, val);
            }

            // Key collision at this level — create a sub-node
            // We ARE adding a new leaf (key2), so set the flag
            addedLeaf.set(true);
            const new_sub = try createSubNode(allocator, shift + SHIFT_BITS, existing_kvp.key, existing_kvp.val, hash, key, val, addedLeaf);
            return createBitmapWithSub(allocator, self, idx, new_sub);
        } else {
            const n = popCount(self.bitmap);
            if (n >= 16) {
                return upgradeToArrayAndAssoc(allocator, self, shift, hash, key, val, addedLeaf);
            }
            const idx = indexBelow(self.bitmap, bit);
            addedLeaf.set(true);
            return createBitmapWithLeaf(allocator, self, idx, bit, key, val);
        }
    }

    pub fn doWithout(self: *const BitmapIndexedNode, allocator: Allocator, shift: u5, hash: i32, key: Value, removedLeaf: *LeafFlag) anyerror!?*Node {
        const bit = bitpos(hash, shift);
        if ((self.bitmap & bit) == 0) return self.cloneNode(allocator);

        const idx = indexBelow(self.bitmap, bit);
        const kvp = &self.array[idx];

        if (kvp.key.type == .nil) {
            const sub_node = self.sub_nodes[idx].?;
            const new_sub = try nodeWithout(sub_node, allocator, shift + SHIFT_BITS, hash, key, removedLeaf);
            if (sub_node == new_sub and !removedLeaf.get()) return self.cloneNode(allocator);

            if (new_sub == null) {
                if (self.bitmap == bit) return null;
                return createBitmapWithout(allocator, self, idx);
            }
            return createBitmapWithSub(allocator, self, idx, new_sub.?);
        }

        if (kvp.key.equals(key)) {
            removedLeaf.set(true);
            if (self.bitmap == bit) return null;
            return createBitmapWithout(allocator, self, idx);
        }

        return self.cloneNode(allocator);
    }

    pub fn appendKeys(self: *const BitmapIndexedNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < self.array.len) : (i += 1) {
            if (self.array[i].key.type == .nil) {
                try nodeAppendKeys(self.sub_nodes[i].?, allocator, result);
            } else {
                try result.append(allocator, self.array[i].key);
            }
        }
    }

    pub fn appendVals(self: *const BitmapIndexedNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < self.array.len) : (i += 1) {
            if (self.array[i].key.type == .nil) {
                try nodeAppendVals(self.sub_nodes[i].?, allocator, result);
            } else {
                try result.append(allocator, self.array[i].val);
            }
        }
    }

    pub fn appendEntries(self: *const BitmapIndexedNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < self.array.len) : (i += 1) {
            if (self.array[i].key.type == .nil) {
                try nodeAppendEntries(self.sub_nodes[i].?, allocator, result);
            } else {
                try result.append(allocator, self.array[i].key);
                try result.append(allocator, self.array[i].val);
            }
        }
    }

    fn cloneNode(self: *const BitmapIndexedNode, allocator: Allocator) *Node {
        // Deep clone to avoid sharing Value pointers with the original.
        var new_kvs = newKvpArrayLen(allocator, self.array.len);
        var i: usize = 0;
        while (i < self.array.len) : (i += 1) {
            new_kvs[i] = .{
                .key = self.array[i].key.clone(allocator) catch @panic("OOM"),
                .val = self.array[i].val.clone(allocator) catch @panic("OOM"),
            };
        }
        const new_subs = newSubNodesArray(allocator, self.sub_nodes);
        return newNode(allocator, Node{
            .bitmap_indexed = BitmapIndexedNode{
                .bitmap = self.bitmap,
                .array = new_kvs,
                .sub_nodes = new_subs,
            },
        });
    }

    fn deinitNode(self: *BitmapIndexedNode, allocator: Allocator) void {
        for (self.array) |*kvp| {
            kvp.key.deinit(allocator);
            kvp.val.deinit(allocator);
        }
        allocator.free(self.array);
        allocator.free(self.sub_nodes);
    }
};

/// ArrayNode — dense node with fixed 32 slots.
const ArrayNode = struct {
    count: usize,
    nodes: [32]?*Node,

    pub fn findLeaf(self: *const ArrayNode, shift: u5, hash: i32, key: Value) ?Value {
        const idx = mask(hash, shift);
        if (self.nodes[idx] == null) return null;
        return nodeFindLeaf(self.nodes[idx].?, shift + SHIFT_BITS, hash, key);
    }

    pub fn findPtr(self: *const ArrayNode, shift: u5, hash: i32, key: Value) ?*const Value {
        const idx = mask(hash, shift);
        if (self.nodes[idx] == null) return null;
        return nodeFindPtr(self.nodes[idx].?, shift + SHIFT_BITS, hash, key);
    }

    pub fn doAssoc(self: *const ArrayNode, allocator: Allocator, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
        const idx = mask(hash, shift);
        const existing = self.nodes[idx];

        if (existing == null) {
            const new_sub = try createBitmapLeaf(allocator, shift + SHIFT_BITS, hash, key, val, addedLeaf);
            var new_nodes: [32]?*Node = self.nodes;
            new_nodes[idx] = new_sub;
            return createArrayNode(allocator, self.count + 1, &new_nodes);
        }

        const new_sub = try nodeAssoc(existing.?, allocator, shift + SHIFT_BITS, hash, key, val, addedLeaf);
        if (existing.? == new_sub) return self.cloneNode(allocator);

        var new_nodes: [32]?*Node = self.nodes;
        new_nodes[idx] = new_sub;
        return createArrayNode(allocator, self.count, &new_nodes);
    }

    pub fn doWithout(self: *const ArrayNode, allocator: Allocator, shift: u5, hash: i32, key: Value, removedLeaf: *LeafFlag) anyerror!?*Node {
        const idx = mask(hash, shift);
        const existing = self.nodes[idx];

        if (existing == null) return self.cloneNode(allocator);

        const new_sub = try nodeWithout(existing.?, allocator, shift + SHIFT_BITS, hash, key, removedLeaf);
        if (existing.? == new_sub and !removedLeaf.get()) return self.cloneNode(allocator);

        if (new_sub == null) {
            if (self.count <= 8) {
                return packToBitmap(allocator, self, idx);
            }
            var new_nodes: [32]?*Node = self.nodes;
            new_nodes[idx] = null;
            return createArrayNode(allocator, self.count - 1, &new_nodes);
        }

        var new_nodes: [32]?*Node = self.nodes;
        new_nodes[idx] = new_sub.?;
        return createArrayNode(allocator, self.count, &new_nodes);
    }

    pub fn appendKeys(self: *const ArrayNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (self.nodes[i]) |node| {
                try nodeAppendKeys(node, allocator, result);
            }
        }
    }

    pub fn appendVals(self: *const ArrayNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (self.nodes[i]) |node| {
                try nodeAppendVals(node, allocator, result);
            }
        }
    }

    pub fn appendEntries(self: *const ArrayNode, allocator: Allocator, result: *list.List) anyerror!void {
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (self.nodes[i]) |node| {
                try nodeAppendEntries(node, allocator, result);
            }
        }
    }

    fn cloneNode(self: *const ArrayNode, allocator: Allocator) *Node {
        // Struct copy shares child node pointers (structural sharing for sub-nodes).
        // This is safe because ArrayNode.deinitNode does NOT deinit children.
        return newNode(allocator, Node{
            .array = ArrayNode{
                .count = self.count,
                .nodes = self.nodes,
            },
        });
    }

    fn deinitNode(self: *ArrayNode, allocator: Allocator) void {
        _ = self;
        _ = allocator;
        // Don't deinit children — they're shared across nodes via path copying.
        // The GC tracks all nodes and frees them when unreachable.
    }
};

/// HashCollisionNode — all entries share the same full hash.
const HashCollisionNode = struct {
    hash: i32,
    kvs: []Kvp,

    pub fn findLeaf(self: *const HashCollisionNode, hash: i32, key: Value) ?Value {
        _ = hash;
        var i: usize = 0;
        while (i < self.kvs.len) : (i += 1) {
            if (self.kvs[i].key.equals(key)) return self.kvs[i].val;
        }
        return null;
    }

    pub fn findPtr(self: *const HashCollisionNode, hash: i32, key: Value) ?*const Value {
        _ = hash;
        var i: usize = 0;
        while (i < self.kvs.len) : (i += 1) {
            if (self.kvs[i].key.equals(key)) return &self.kvs[i].val;
        }
        return null;
    }

    pub fn doAssoc(self: *const HashCollisionNode, allocator: Allocator, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
        if (hash == self.hash) {
            var i: usize = 0;
            while (i < self.kvs.len) : (i += 1) {
                if (self.kvs[i].key.equals(key)) {
                    if (self.kvs[i].val.equals(val)) return self.cloneNode(allocator);
                    return createCollisionNodeWithValue(allocator, self, i, val);
                }
            }
            addedLeaf.set(true);
            return createCollisionNodeAppend(allocator, self, key, val);
        }

        // Different hash — wrap in bitmap node, then add new key
        const bit = bitpos(self.hash, shift);
        const bitmap_node = createBitmapWithCollisionSub(allocator, bit, self);
        return nodeAssoc(bitmap_node, allocator, shift, hash, key, val, addedLeaf);
    }

    pub fn doWithout(self: *const HashCollisionNode, allocator: Allocator, shift: u5, hash: i32, key: Value, removedLeaf: *LeafFlag) anyerror!?*Node {
        _ = shift;
        _ = hash;
        var i: usize = 0;
        while (i < self.kvs.len) : (i += 1) {
            if (self.kvs[i].key.equals(key)) {
                removedLeaf.set(true);
                if (self.kvs.len == 1) return null;
                return createCollisionNodeWithout(allocator, self, i);
            }
        }
        return self.cloneNode(allocator);
    }

    pub fn appendKeys(self: *const HashCollisionNode, allocator: Allocator, result: *list.List) anyerror!void {
        for (self.kvs) |kvp| {
            try result.append(allocator, kvp.key);
        }
    }

    pub fn appendVals(self: *const HashCollisionNode, allocator: Allocator, result: *list.List) anyerror!void {
        for (self.kvs) |kvp| {
            try result.append(allocator, kvp.val);
        }
    }

    pub fn appendEntries(self: *const HashCollisionNode, allocator: Allocator, result: *list.List) anyerror!void {
        for (self.kvs) |kvp| {
            try result.append(allocator, kvp.key);
            try result.append(allocator, kvp.val);
        }
    }

    fn cloneNode(self: *const HashCollisionNode, allocator: Allocator) *Node {
        // Deep clone kvs to avoid sharing Value pointers.
        var new_kvs = newKvpArrayLen(allocator, self.kvs.len);
        var i: usize = 0;
        while (i < self.kvs.len) : (i += 1) {
            new_kvs[i] = .{
                .key = self.kvs[i].key.clone(allocator) catch @panic("OOM"),
                .val = self.kvs[i].val.clone(allocator) catch @panic("OOM"),
            };
        }
        return newNode(allocator, Node{
            .hash_collision = HashCollisionNode{
                .hash = self.hash,
                .kvs = new_kvs,
            },
        });
    }

    fn deinitNode(self: *HashCollisionNode, allocator: Allocator) void {
        for (self.kvs) |*kvp| {
            kvp.key.deinit(allocator);
            kvp.val.deinit(allocator);
        }
        allocator.free(self.kvs);
    }
};

/// A node in the hash trie.
pub const Node = union(NodeTag) {
    bitmap_indexed: BitmapIndexedNode,
    array: ArrayNode,
    hash_collision: HashCollisionNode,
};

// Standalone dispatch functions for Node union
pub fn nodeFindLeaf(node: *Node, shift: u5, hash: i32, key: Value) ?Value {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.findLeaf(shift, hash, key),
        .array => |*n| return n.findLeaf(shift, hash, key),
        .hash_collision => |*n| return n.findLeaf(hash, key),
    }
}

pub fn nodeAssoc(node: *Node, allocator: Allocator, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.doAssoc(allocator, shift, hash, key, val, addedLeaf),
        .array => |*n| return n.doAssoc(allocator, shift, hash, key, val, addedLeaf),
        .hash_collision => |*n| return n.doAssoc(allocator, shift, hash, key, val, addedLeaf),
    }
}

pub fn nodeWithout(node: *Node, allocator: Allocator, shift: u5, hash: i32, key: Value, removedLeaf: *LeafFlag) anyerror!?*Node {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.doWithout(allocator, shift, hash, key, removedLeaf),
        .array => |*n| return n.doWithout(allocator, shift, hash, key, removedLeaf),
        .hash_collision => |*n| return n.doWithout(allocator, shift, hash, key, removedLeaf),
    }
}

pub fn nodeAppendKeys(node: *Node, allocator: Allocator, result: *list.List) anyerror!void {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.appendKeys(allocator, result),
        .array => |*n| return n.appendKeys(allocator, result),
        .hash_collision => |*n| return n.appendKeys(allocator, result),
    }
}

pub fn nodeAppendVals(node: *Node, allocator: Allocator, result: *list.List) anyerror!void {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.appendVals(allocator, result),
        .array => |*n| return n.appendVals(allocator, result),
        .hash_collision => |*n| return n.appendVals(allocator, result),
    }
}

pub fn nodeAppendEntries(node: *Node, allocator: Allocator, result: *list.List) anyerror!void {
    switch (node.*) {
        .bitmap_indexed => |*n| return n.appendEntries(allocator, result),
        .array => |*n| return n.appendEntries(allocator, result),
        .hash_collision => |*n| return n.appendEntries(allocator, result),
    }
}

fn deinitNodePtr(node: *Node, allocator: Allocator) void {
    switch (node.*) {
        .bitmap_indexed => |*bnode| bnode.deinitNode(allocator),
        .array => |*anode| anode.deinitNode(allocator),
        .hash_collision => |*hnode| hnode.deinitNode(allocator),
    }
    allocator.destroy(node);
}

// ============================================================
// PersistentHashMap
// ============================================================

pub const PersistentHashMap = struct {
    count: usize,
    root: ?*Node,
    has_null: bool,
    null_value: Value,

    /// Empty map singleton.
    pub const EMPTY: PersistentHashMap = .{
        .count = 0,
        .root = null,
        .has_null = false,
        .null_value = Value.nilValue(),
    };

    /// Create a new empty PersistentHashMap.
    pub fn empty() PersistentHashMap {
        return EMPTY;
    }

    /// Check if the map is empty.
    pub fn isEmpty(self: PersistentHashMap) bool {
        return self.count == 0;
    }

    /// Return the number of entries in the map.
    pub fn mapCount(self: PersistentHashMap) usize {
        return self.count;
    }

    /// Check if the map contains the given key.
    pub fn containsKey(self: PersistentHashMap, key: Value) bool {
        if (key.type == .nil) return self.has_null;
        if (self.root == null) return false;
        const h = valueHash(key);
        return nodeFindLeaf(self.root.?, 0, h, key) != null;
    }

    /// Look up a value by key. Returns the value or null if not found.
    pub fn find(self: PersistentHashMap, key: Value) ?Value {
        if (key.type == .nil) {
            if (self.has_null) return self.null_value;
            return null;
        }
        if (self.root == null) return null;
        const h = valueHash(key);
        const result = nodeFindLeaf(self.root.?, 0, h, key);
        return result;
    }

    /// Look up a value by key, returning default if not found.
    pub fn findDefault(self: PersistentHashMap, key: Value, default_val: Value) Value {
        const result = self.find(key);
        if (result) |v| return v;
        return default_val;
    }

    /// Look up a value by key, returning a pointer to the stored Value.
    /// The pointer is valid as long as the HAMT node containing it is alive.
    pub fn findPtr(self: PersistentHashMap, key: Value) ?*const Value {
        if (key.type == .nil) {
            if (self.has_null) return &self.null_value;
            return null;
        }
        if (self.root == null) return null;
        const h = valueHash(key);
        return nodeFindPtr(self.root.?, 0, h, key);
    }

    /// Associate a key-value pair. Returns a new PersistentHashMap.
    pub fn mapAssoc(self: PersistentHashMap, allocator: Allocator, key: Value, val: Value) anyerror!PersistentHashMap {
        if (key.type == .nil) {
            if (self.has_null and self.null_value.equals(val)) return self;
            return PersistentHashMap{
                .count = if (self.has_null) self.count else self.count + 1,
                .root = self.root,
                .has_null = true,
                .null_value = val,
            };
        }

        const h = valueHash(key);
        var addedLeaf = LeafFlag{};
        const new_root: *Node = if (self.root) |root| blk: {
            break :blk try nodeAssoc(root, allocator, 0, h, key, val, &addedLeaf);
        } else blk: {
            break :blk try createBitmapLeaf(allocator, 0, h, key, val, &addedLeaf);
        };

        const new_count = if (addedLeaf.get()) self.count + 1 else self.count;
        return PersistentHashMap{
            .count = new_count,
            .root = new_root,
            .has_null = self.has_null,
            .null_value = self.null_value,
        };
    }

    /// Remove a key. Returns a new PersistentHashMap.
    pub fn mapWithout(self: PersistentHashMap, allocator: Allocator, key: Value) anyerror!PersistentHashMap {
        if (key.type == .nil) {
            if (!self.has_null) return self;
            var nv = self.null_value;
            defer nv.deinit(allocator);
            return PersistentHashMap{
                .count = self.count - 1,
                .root = self.root,
                .has_null = false,
                .null_value = Value.nilValue(),
            };
        }
        if (self.root == null) return self;

        const h = valueHash(key);
        var removedLeaf = LeafFlag{};
        const new_root = try nodeWithout(self.root.?, allocator, 0, h, key, &removedLeaf);

        if (new_root == null and !removedLeaf.get()) return self;
        const new_count = if (removedLeaf.get()) self.count - 1 else self.count;
        return PersistentHashMap{
            .count = new_count,
            .root = new_root,
            .has_null = self.has_null,
            .null_value = self.null_value,
        };
    }

    /// Return a list of all keys.
    pub fn mapKeys(self: PersistentHashMap, allocator: Allocator) anyerror!list.List {
        var result: list.List = .empty;
        errdefer result.deinit(allocator);

        if (self.has_null) {
            try result.append(allocator, Value.nilValue());
        }

        if (self.root) |root| {
            try nodeAppendKeys(root, allocator, &result);
        }

        return result;
    }

    /// Return a list of all values.
    pub fn mapVals(self: PersistentHashMap, allocator: Allocator) anyerror!list.List {
        var result: list.List = .empty;
        errdefer result.deinit(allocator);

        if (self.has_null) {
            try result.append(allocator, self.null_value);
        }

        if (self.root) |root| {
            try nodeAppendVals(root, allocator, &result);
        }

        return result;
    }

    /// Return a list of all entries as [key, value] pairs.
    pub fn mapEntries(self: PersistentHashMap, allocator: Allocator) anyerror!list.List {
        var result: list.List = .empty;
        errdefer result.deinit(allocator);

        if (self.has_null) {
            try result.append(allocator, Value.nilValue());
            try result.append(allocator, self.null_value);
        }

        if (self.root) |root| {
            try nodeAppendEntries(root, allocator, &result);
        }

        return result;
    }

    /// Check equality with another map.
    pub fn mapEquals(self: PersistentHashMap, other: PersistentHashMap) bool {
        if (self.count != other.count) return false;
        if (self.has_null != other.has_null) return false;
        if (self.has_null and !self.null_value.equals(other.null_value)) return false;

        if (self.count == 0) return true;

        var it = self.entryIterator();
        while (it.next()) |entry| {
            const found = other.find(entry.key);
            if (found == null) return false;
            if (!entry.val.equals(found.?)) return false;
        }
        return true;
    }

    /// Merge another map into this one. Keys from `other` override keys in `self`.
    pub fn mapMerge(self: PersistentHashMap, allocator: Allocator, other: PersistentHashMap) anyerror!PersistentHashMap {
        var result = self;
        var it = other.entryIterator();
        while (it.next()) |entry| {
            result = try result.mapAssoc(allocator, entry.key, entry.val);
        }
        return result;
    }

    /// Deallocate the map and all its nodes.
    pub fn deinit(self: *PersistentHashMap, allocator: Allocator) void {
        if (self.root) |root| {
            deinitNodePtr(root, allocator);
        }
        if (self.has_null) {
            self.null_value.deinit(allocator);
        }
        self.* = EMPTY;
    }

    // Entry iterator
    const EntryIterator = struct {
        map: PersistentHashMap,
        null_done: bool = false,
        root_iter: ?NodeEntryIterator = null,

        pub fn next(self: *EntryIterator) ?Kvp {
            if (!self.null_done and self.map.has_null) {
                self.null_done = true;
                return Kvp{ .key = Value.nilValue(), .val = self.map.null_value };
            }
            if (self.map.root == null) return null;
            if (self.root_iter == null) {
                self.root_iter = NodeEntryIterator.init(self.map.root.?);
            }
            return self.root_iter.?.next();
        }
    };

    pub fn entryIterator(self: PersistentHashMap) EntryIterator {
        return EntryIterator{ .map = self };
    }
};

// ============================================================
// Node entry iterator (recursive traversal)
// ============================================================

const NodePhase = enum { bitmap, array, collision };

const NodeEntryIterator = struct {
    stack: std.ArrayListUnmanaged(NodeIterFrame),

    const NodeIterFrame = struct {
        node: *Node,
        phase: NodePhase,
        idx: usize = 0,
    };

    fn init(root: *Node) NodeEntryIterator {
        var stack: std.ArrayListUnmanaged(NodeIterFrame) = .empty;
        _ = stack.append(std.heap.page_allocator, NodeIterFrame{
            .node = root,
            .phase = getPhase(root),
        }) catch unreachable;
        return .{ .stack = stack };
    }

    fn next(self: *NodeEntryIterator) ?Kvp {
        while (self.stack.items.len > 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            switch (frame.phase) {
                .bitmap => {
                    const bnode: *const BitmapIndexedNode = &frame.node.bitmap_indexed;
                    if (frame.idx >= bnode.array.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const i = frame.idx;
                    frame.idx += 1;
                    if (bnode.array[i].key.type == .nil) {
                        _ = self.stack.append(std.heap.page_allocator, NodeIterFrame{
                            .node = bnode.sub_nodes[i].?,
                            .phase = getPhase(bnode.sub_nodes[i].?),
                        }) catch unreachable;
                        continue;
                    } else {
                        return bnode.array[i];
                    }
                },
                .array => {
                    const anode: *const ArrayNode = &frame.node.array;
                    if (frame.idx >= 32) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const i = frame.idx;
                    frame.idx += 1;
                    if (anode.nodes[i]) |sub| {
                        _ = self.stack.append(std.heap.page_allocator, NodeIterFrame{
                            .node = sub,
                            .phase = getPhase(sub),
                        }) catch unreachable;
                        continue;
                    }
                },
                .collision => {
                    const hnode: *const HashCollisionNode = &frame.node.hash_collision;
                    if (frame.idx >= hnode.kvs.len) {
                        _ = self.stack.pop();
                        continue;
                    }
                    const i = frame.idx;
                    frame.idx += 1;
                    return hnode.kvs[i];
                },
            }
        }
        return null;
    }
};

fn getPhase(node: *const Node) NodePhase {
    switch (node.*) {
        .bitmap_indexed => return .bitmap,
        .array => return .array,
        .hash_collision => return .collision,
    }
}

// ============================================================
// Node construction helpers
// ============================================================

/// Create a BitmapIndexedNode with a single leaf entry.
fn createBitmapLeaf(allocator: Allocator, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
    const bit = bitpos(hash, shift);
    addedLeaf.set(true);

    const cloned_key = try key.clone(allocator);
    const cloned_val = try val.clone(allocator);
    var kvs: [1]Kvp = .{ .{ .key = cloned_key, .val = cloned_val } };
    var subs: [1]?*Node = .{null};

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = bit,
            .array = newKvpArray(allocator, &kvs),
            .sub_nodes = newSubNodesArray(allocator, &subs),
        },
    });
}

/// Create a sub-node to handle two keys that collide at this level.
fn createSubNode(allocator: Allocator, shift: u5, key1: Value, val1: Value, hash2: i32, key2: Value, val2: Value, addedLeaf: *LeafFlag) anyerror!*Node {
    const hash1 = valueHash(key1);
    if (hash1 == hash2) {
        addedLeaf.set(true);
        var kvs: [2]Kvp = .{
            .{ .key = try key1.clone(allocator), .val = try val1.clone(allocator) },
            .{ .key = try key2.clone(allocator), .val = try val2.clone(allocator) },
        };
        return newNode(allocator, Node{
            .hash_collision = HashCollisionNode{
                .hash = hash1,
                .kvs = newKvpArray(allocator, &kvs),
            },
        });
    }

    var bitmap: u32 = 0;
    const bit1 = bitpos(hash1, shift);
    const bit2 = bitpos(hash2, shift);
    bitmap |= bit1;
    bitmap |= bit2;

    const idx1 = indexBelow(bitmap, bit1);
    const idx2 = indexBelow(bitmap, bit2);

    var kvs: [2]Kvp = undefined;
    var subs: [2]?*Node = .{ null, null };

    if (idx1 < idx2) {
        kvs[0] = .{ .key = try key1.clone(allocator), .val = try val1.clone(allocator) };
        kvs[1] = .{ .key = try key2.clone(allocator), .val = try val2.clone(allocator) };
    } else {
        kvs[0] = .{ .key = try key2.clone(allocator), .val = try val2.clone(allocator) };
        kvs[1] = .{ .key = try key1.clone(allocator), .val = try val1.clone(allocator) };
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = bitmap,
            .array = newKvpArray(allocator, &kvs),
            .sub_nodes = newSubNodesArray(allocator, &subs),
        },
    });
}

/// Create a new BitmapIndexedNode with a value updated at index.
fn createBitmapWithValue(allocator: Allocator, src: *const BitmapIndexedNode, idx: usize, new_val: Value) anyerror!*Node {
    // Deep clone all Kvp entries to avoid sharing Value pointers with src.
    const new_len = src.array.len;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }
    _ = newSubNodesArray(allocator, src.sub_nodes); // register with GC

    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        if (i == idx) {
            new_kvs[i] = .{
                .key = try src.array[i].key.clone(allocator),
                .val = try new_val.clone(allocator),
            };
        } else {
            new_kvs[i] = .{
                .key = try src.array[i].key.clone(allocator),
                .val = try src.array[i].val.clone(allocator),
            };
        }
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = src.bitmap,
            .array = new_kvs,
            .sub_nodes = newSubNodesArray(allocator, src.sub_nodes),
        },
    });
}

/// Create a new BitmapIndexedNode with a sub-node at index.
fn createBitmapWithSub(allocator: Allocator, src: *const BitmapIndexedNode, idx: usize, new_sub: *Node) anyerror!*Node {
    // Deep clone all Kvp entries (shallow dupe would share Value pointers,
    // causing double-free when the old node is deinit'd).
    const new_len = src.array.len;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer allocator.free(new_kvs);
    var new_subs = newSubNodesArrayLen(allocator, new_len);
    errdefer allocator.free(new_subs);

    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        if (i == idx) {
            // Replace with nil key (marks this slot as holding a sub-node)
            new_kvs[i] = .{ .key = Value.nilValue(), .val = Value.nilValue() };
            new_subs[i] = new_sub;
            if (src.sub_nodes[i]) |old_sub| deinitNodePtr(old_sub, allocator);
        } else {
            // Deep clone the Kvp
            new_kvs[i] = .{
                .key = try src.array[i].key.clone(allocator),
                .val = try src.array[i].val.clone(allocator),
            };
            new_subs[i] = src.sub_nodes[i];
        }
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = src.bitmap,
            .array = new_kvs,
            .sub_nodes = new_subs,
        },
    });
}

/// Create a new BitmapIndexedNode with a leaf inserted at index.
fn createBitmapWithLeaf(allocator: Allocator, src: *const BitmapIndexedNode, insert_idx: usize, bit: u32, key: Value, val: Value) anyerror!*Node {
    const new_len = src.array.len + 1;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }
    var new_subs = newSubNodesArrayLen(allocator, new_len);
    errdefer allocator.free(new_subs);

    var i: usize = 0;
    while (i < insert_idx) : (i += 1) {
        new_kvs[i] = .{
            .key = try src.array[i].key.clone(allocator),
            .val = try src.array[i].val.clone(allocator),
        };
        new_subs[i] = src.sub_nodes[i];
    }
    new_kvs[insert_idx] = .{ .key = try key.clone(allocator), .val = try val.clone(allocator) };
    new_subs[insert_idx] = null;
    var j: usize = insert_idx + 1;
    while (i < src.array.len) : ({ i += 1; j += 1; }) {
        new_kvs[j] = .{
            .key = try src.array[i].key.clone(allocator),
            .val = try src.array[i].val.clone(allocator),
        };
        new_subs[j] = src.sub_nodes[i];
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = src.bitmap | bit,
            .array = new_kvs,
            .sub_nodes = new_subs,
        },
    });
}

/// Create a new BitmapIndexedNode with an entry removed at index.
fn createBitmapWithout(allocator: Allocator, src: *const BitmapIndexedNode, remove_idx: usize) anyerror!*Node {
    const new_len = src.array.len - 1;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }
    var new_subs = newSubNodesArrayLen(allocator, new_len);
    errdefer allocator.free(new_subs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < src.array.len) : (i += 1) {
        if (i == remove_idx) {
            src.array[i].key.deinit(allocator);
            src.array[i].val.deinit(allocator);
            if (src.sub_nodes[i]) |sub| deinitNodePtr(sub, allocator);
            continue;
        }
        // Deep clone Kvp to avoid sharing Value pointers with src.
        new_kvs[j] = .{
            .key = try src.array[i].key.clone(allocator),
            .val = try src.array[i].val.clone(allocator),
        };
        // Sub-node pointers are shared (both old and new trees reference the same immutable sub-nodes).
        new_subs[j] = src.sub_nodes[i];
        j += 1;
    }

    // Remove the bit corresponding to remove_idx from the bitmap
    var new_bitmap = src.bitmap;
    var bit: u32 = 1;
    var idx: usize = 0;
    while (bit != 0) : ({ bit <<= 1; }) {
        if ((src.bitmap & bit) != 0) {
            if (idx == remove_idx) {
                new_bitmap ^= bit;  // Clear this bit
                break;
            }
            idx += 1;
        }
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = new_bitmap,
            .array = new_kvs,
            .sub_nodes = new_subs,
        },
    });
}

/// Create an ArrayNode from a pointer to a 32-element array.
fn createArrayNode(allocator: Allocator, count: usize, nodes: *[32]?*Node) *Node {
    return newNode(allocator, Node{
        .array = ArrayNode{
            .count = count,
            .nodes = nodes.*,
        },
    });
}

/// Create a BitmapIndexedNode wrapping a HashCollisionNode as a sub-node.
fn createBitmapWithCollisionSub(allocator: Allocator, bit: u32, collision: *const HashCollisionNode) *Node {
    var kvs: [1]Kvp = .{ .{ .key = Value.nilValue(), .val = Value.nilValue() } };
    var subs: [1]?*Node = undefined;

    const coll_node = newNode(allocator, Node{
        .hash_collision = HashCollisionNode{
            .hash = collision.hash,
            .kvs = collision.kvs,
        },
    });
    subs[0] = coll_node;

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = bit,
            .array = newKvpArray(allocator, &kvs),
            .sub_nodes = newSubNodesArray(allocator, &subs),
        },
    });
}

/// Upgrade a BitmapIndexedNode to ArrayNode and add a new entry.
fn upgradeToArrayAndAssoc(allocator: Allocator, src: *const BitmapIndexedNode, shift: u5, hash: i32, key: Value, val: Value, addedLeaf: *LeafFlag) anyerror!*Node {
    var nodes: [32]?*Node = .{null} ** 32;
    var count: usize = 0;

    // Add the new key
    const jdx = mask(hash, shift);
    nodes[jdx] = try createBitmapLeaf(allocator, shift + SHIFT_BITS, hash, key, val, addedLeaf);
    count += 1;

    // Migrate existing entries
    var i: usize = 0;
    while (i < src.array.len) : (i += 1) {
        if (src.array[i].key.type == .nil) {
            // Sub-node — re-insert at the correct slot
            const sub = src.sub_nodes[i].?;
            const sub_slot = getSubNodeSlot(sub, shift);
            if (nodes[sub_slot] == null) {
                nodes[sub_slot] = sub;
            } else {
                nodes[sub_slot] = try mergeIntoSlot(allocator, nodes[sub_slot].?, sub, shift + SHIFT_BITS, addedLeaf);
            }
            count += 1;
        } else {
            const entry_hash = valueHash(src.array[i].key);
            const slot = mask(entry_hash, shift);
            if (nodes[slot] == null) {
                nodes[slot] = try createBitmapLeaf(allocator, shift + SHIFT_BITS, entry_hash, src.array[i].key, src.array[i].val, addedLeaf);
            } else {
                nodes[slot] = try nodeAssoc(nodes[slot].?, allocator, shift + SHIFT_BITS, entry_hash, src.array[i].key, src.array[i].val, addedLeaf);
            }
            count += 1;
        }
    }

    return createArrayNode(allocator, count, &nodes);
}

/// Get the array slot index for a sub-node at a given shift level.
fn getSubNodeSlot(sub: *const Node, shift: u5) usize {
    switch (sub.*) {
        .bitmap_indexed => |*bnode| {
            var b: u32 = 1;
            var s: usize = 0;
            while (b != 0 and s < 32) : ({ b <<= 1; s += 1; }) {
                if ((bnode.bitmap & b) != 0) return s;
            }
            return 0;
        },
        .hash_collision => |*hnode| {
            return mask(hnode.hash, shift);
        },
        .array => |*anode| {
            var s: usize = 0;
            while (s < 32) : (s += 1) {
                if (anode.nodes[s] != null) return s;
            }
            return 0;
        },
    }
}

/// Merge two nodes at the same level.
fn mergeIntoSlot(allocator: Allocator, target: *Node, source: *Node, shift: u5, addedLeaf: *LeafFlag) anyerror!*Node {
    switch (source.*) {
        .bitmap_indexed => |*bnode| {
            var result = target;
            var i: usize = 0;
            while (i < bnode.array.len) : (i += 1) {
                if (bnode.array[i].key.type != .nil) {
                    result = try nodeAssoc(result, allocator, shift, valueHash(bnode.array[i].key), bnode.array[i].key, bnode.array[i].val, addedLeaf);
                }
            }
            return result;
        },
        .hash_collision => |*hnode| {
            var result = target;
            for (hnode.kvs) |kvp| {
                result = try nodeAssoc(result, allocator, shift, hnode.hash, kvp.key, kvp.val, addedLeaf);
            }
            return result;
        },
        .array => |*anode| {
            var result = target;
            var s: usize = 0;
            while (s < 32) : (s += 1) {
                if (anode.nodes[s]) |sub| {
                    result = try mergeIntoSlot(allocator, result, sub, shift + SHIFT_BITS, addedLeaf);
                }
            }
            return result;
        },
    }
}

/// Pack an ArrayNode back to BitmapIndexedNode (after removal).
fn packToBitmap(allocator: Allocator, src: *const ArrayNode, empty_idx: usize) anyerror!*Node {
    var kvs: std.ArrayListUnmanaged(Kvp) = .empty;
    defer {
        for (kvs.items) |*kvp| {
            kvp.key.deinit(allocator);
            kvp.val.deinit(allocator);
        }
        allocator.free(kvs.items);
    }
    var subs: std.ArrayListUnmanaged(?*Node) = .empty;
    defer allocator.free(subs.items);

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (i == empty_idx) continue;
        if (src.nodes[i]) |node| {
            try kvs.append(allocator, .{ .key = Value.nilValue(), .val = Value.nilValue() });
            try subs.append(allocator, node);
        }
    }

    var bitmap: u32 = 0;
    var bit: u32 = 1;
    var slot: usize = 0;
    var arr_idx: usize = 0;
    while (bit != 0 and slot < 32) : ({ bit <<= 1; slot += 1; }) {
        if (slot == empty_idx) continue;
        if (src.nodes[slot] != null) {
            bitmap |= (@as(u32, 1) << @as(u5, @intCast(arr_idx)));
            arr_idx += 1;
        }
    }

    // Register arrays with GC before transferring ownership
    if (gc.current_gc) |gc_inst| {
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(kvs.items.ptr)), gc.GCObjectType.hash_map_kvp_array);
        gc_inst.setObjectType(@as(*anyopaque, @ptrCast(subs.items.ptr)), gc.GCObjectType.hash_map_sub_nodes);
    }

    return newNode(allocator, Node{
        .bitmap_indexed = BitmapIndexedNode{
            .bitmap = bitmap,
            .array = kvs.items,
            .sub_nodes = subs.items,
        },
    });
}

/// Create a HashCollisionNode with a value updated at index.
fn createCollisionNodeWithValue(allocator: Allocator, src: *const HashCollisionNode, idx: usize, new_val: Value) anyerror!*Node {
    // Deep clone all Kvp entries to avoid sharing Value pointers with src.
    const new_len = src.kvs.len;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }

    var i: usize = 0;
    while (i < new_len) : (i += 1) {
        if (i == idx) {
            new_kvs[i] = .{
                .key = try src.kvs[i].key.clone(allocator),
                .val = try new_val.clone(allocator),
            };
        } else {
            new_kvs[i] = .{
                .key = try src.kvs[i].key.clone(allocator),
                .val = try src.kvs[i].val.clone(allocator),
            };
        }
    }

    return newNode(allocator, Node{
        .hash_collision = HashCollisionNode{
            .hash = src.hash,
            .kvs = new_kvs,
        },
    });
}

/// Create a HashCollisionNode with a new entry appended.
fn createCollisionNodeAppend(allocator: Allocator, src: *const HashCollisionNode, key: Value, val: Value) anyerror!*Node {
    const new_len = src.kvs.len + 1;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }

    var i: usize = 0;
    while (i < src.kvs.len) : (i += 1) {
        new_kvs[i] = .{
            .key = try src.kvs[i].key.clone(allocator),
            .val = try src.kvs[i].val.clone(allocator),
        };
    }
    new_kvs[new_len - 1] = .{ .key = try key.clone(allocator), .val = try val.clone(allocator) };

    return newNode(allocator, Node{
        .hash_collision = HashCollisionNode{
            .hash = src.hash,
            .kvs = new_kvs,
        },
    });
}

/// Create a HashCollisionNode with an entry removed at index.
fn createCollisionNodeWithout(allocator: Allocator, src: *const HashCollisionNode, remove_idx: usize) anyerror!*Node {
    const new_len = src.kvs.len - 1;
    var new_kvs = newKvpArrayLen(allocator, new_len);
    errdefer { for (new_kvs) |*kvp| { kvp.key.deinit(allocator); kvp.val.deinit(allocator); } allocator.free(new_kvs); }

    var j: usize = 0;
    var i: usize = 0;
    while (i < src.kvs.len) : (i += 1) {
        if (i == remove_idx) {
            src.kvs[i].key.deinit(allocator);
            src.kvs[i].val.deinit(allocator);
            continue;
        }
        // Deep clone to avoid sharing Value pointers with src.
        new_kvs[j] = .{
            .key = try src.kvs[i].key.clone(allocator),
            .val = try src.kvs[i].val.clone(allocator),
        };
        j += 1;
    }

    return newNode(allocator, Node{
        .hash_collision = HashCollisionNode{
            .hash = src.hash,
            .kvs = new_kvs,
        },
    });
}

// ============================================================
// Memoization cache: string → Value(symbol) for HAMT keys
// ============================================================

var sym_cache: std.StringArrayHashMapUnmanaged(Value) = .empty;

/// Create or retrieve a memoized Value(symbol) for the given string.
/// The returned Value owns a duplicated copy of the string.
pub fn sym(s: []const u8) Value {
    if (sym_cache.get(s)) |cached| {
        return cached;
    }
    const allocator = std.heap.page_allocator;
    const owned = allocator.dupe(u8, s) catch return Value{ .type = .symbol, .sym_val = s };
    const val = Value{ .type = .symbol, .sym_val = owned };
    sym_cache.put(allocator, s, val) catch unreachable;
    return val;
}

/// Scan function for hash map nodes. Called by gc_scan.zig.

/// Scan function for hash map nodes. Called by gc_scan.zig.
pub fn scanHashMapNode(node_ptr: *anyopaque, ctx: *gc.ScanContext) void {
    const node: *Node = @ptrCast(@alignCast(node_ptr));
    switch (node.*) {
        .bitmap_indexed => |*bnode| {
            // Mark the Kvp array buffer itself so it survives sweeps
            if (bnode.array.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(bnode.array.ptr))), ctx);
            }
            // Mark the sub_nodes array buffer itself
            if (bnode.sub_nodes.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(bnode.sub_nodes.ptr))), ctx);
            }
            for (bnode.array) |kvp| {
                if (kvp.key.type != .nil) {
                    ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(&kvp.key))), ctx);
                    ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(&kvp.val))), ctx);
                    // Mark wrapped pointers (e.g., *Env stored in NamespaceManager)
                    if (kvp.val.type == .wrapped and kvp.val.wrapped_val != 0) {
                        const ptr = @as(*anyopaque, @ptrFromInt(kvp.val.wrapped_val));
                        ctx.gc.markRecursive(ptr, ctx);
                    }
                }
            }
            for (bnode.sub_nodes) |sub| {
                if (sub) |s| ctx.gc.markRecursive(s, ctx);
            }
        },
        .array => |*anode| {
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                if (anode.nodes[i]) |sub| {
                    ctx.gc.markRecursive(sub, ctx);
                }
            }
        },
        .hash_collision => |*hnode| {
            // Mark the Kvp array buffer itself so it survives sweeps
            if (hnode.kvs.len > 0) {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(hnode.kvs.ptr))), ctx);
            }
            for (hnode.kvs) |kvp| {
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(&kvp.key))), ctx);
                ctx.gc.markRecursive(@as(*anyopaque, @ptrCast(@constCast(&kvp.val))), ctx);
                // Mark wrapped pointers
                if (kvp.val.type == .wrapped and kvp.val.wrapped_val != 0) {
                    const ptr = @as(*anyopaque, @ptrFromInt(kvp.val.wrapped_val));
                    ctx.gc.markRecursive(ptr, ctx);
                }
            }
        },
    }
}

// ============================================================
// Unit Tests
// ============================================================

test "persistent_hash_map::empty map" {
    const m = PersistentHashMap.empty();
    try std.testing.expect(m.isEmpty());
    try std.testing.expect(m.mapCount() == 0);
    try std.testing.expect(!m.containsKey(Value.intValue(1)));
    try std.testing.expectEqual(null, m.find(Value.intValue(1)));
}

test "persistent_hash_map::assoc and find" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    try std.testing.expect(m.mapCount() == 1);
    try std.testing.expect(m.containsKey(Value.intValue(1)));
    try std.testing.expect(m.find(Value.intValue(1)).?.int_val == 10);

    m = try m.mapAssoc(a, Value.intValue(2), Value.intValue(20));
    try std.testing.expect(m.mapCount() == 2);
    try std.testing.expect(m.find(Value.intValue(1)).?.int_val == 10);
    try std.testing.expect(m.find(Value.intValue(2)).?.int_val == 20);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::assoc updates existing key" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(99));

    try std.testing.expect(m.mapCount() == 1);
    try std.testing.expect(m.find(Value.intValue(1)).?.int_val == 99);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::without" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m = try m.mapAssoc(a, Value.intValue(2), Value.intValue(20));
    m = try m.mapAssoc(a, Value.intValue(3), Value.intValue(30));

    m = try m.mapWithout(a, Value.intValue(2));
    try std.testing.expect(m.mapCount() == 2);
    try std.testing.expect(m.find(Value.intValue(1)).?.int_val == 10);
    try std.testing.expectEqual(null, m.find(Value.intValue(2)));
    try std.testing.expect(m.find(Value.intValue(3)).?.int_val == 30);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::immutability" {
    const a = std.heap.page_allocator;
    var m1 = PersistentHashMap.empty();
    m1 = try m1.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m1 = try m1.mapAssoc(a, Value.intValue(2), Value.intValue(20));

    var m2 = try m1.mapAssoc(a, Value.intValue(2), Value.intValue(99));
    var m3 = try m1.mapWithout(a, Value.intValue(1));

    // m1 should be unchanged
    try std.testing.expect(m1.mapCount() == 2);
    try std.testing.expect(m1.find(Value.intValue(1)).?.int_val == 10);
    try std.testing.expect(m1.find(Value.intValue(2)).?.int_val == 20);

    // m2 has updated value
    try std.testing.expect(m2.find(Value.intValue(2)).?.int_val == 99);

    // m3 has removed key
    try std.testing.expect(m3.mapCount() == 1);
    try std.testing.expectEqual(null, m3.find(Value.intValue(1)));

    // m1.deinit(a);
    // m2.deinit(a);
    // m3.deinit(a);
}

test "persistent_hash_map::nil key" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.nilValue(), Value.intValue(42));
    try std.testing.expect(m.mapCount() == 1);
    try std.testing.expect(m.containsKey(Value.nilValue()));
    try std.testing.expect(m.find(Value.nilValue()).?.int_val == 42);

    m = try m.mapWithout(a, Value.nilValue());
    try std.testing.expect(m.mapCount() == 0);
    try std.testing.expect(!m.containsKey(Value.nilValue()));

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::string keys" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    var key1 = try Value.stringValue(a, "hello");
    var key2 = try Value.stringValue(a, "world");
    defer key1.deinit(a);
    defer key2.deinit(a);

    m = try m.mapAssoc(a, key1, Value.intValue(1));
    m = try m.mapAssoc(a, key2, Value.intValue(2));

    try std.testing.expect(m.mapCount() == 2);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::keyword keys" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    var kw1 = try Value.keywordValue(a, "foo");
    var kw2 = try Value.keywordValue(a, "bar");
    defer kw1.deinit(a);
    defer kw2.deinit(a);

    m = try m.mapAssoc(a, kw1, Value.intValue(100));
    m = try m.mapAssoc(a, kw2, Value.intValue(200));

    try std.testing.expect(m.mapCount() == 2);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::keys and vals" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m = try m.mapAssoc(a, Value.intValue(2), Value.intValue(20));
    m = try m.mapAssoc(a, Value.intValue(3), Value.intValue(30));

    var keys_list = try m.mapKeys(a);
    defer keys_list.deinit(a);
    try std.testing.expect(keys_list.items.len == 3);

    var vals_list = try m.mapVals(a);
    defer vals_list.deinit(a);
    try std.testing.expect(vals_list.items.len == 3);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::entries" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m = try m.mapAssoc(a, Value.intValue(2), Value.intValue(20));

    var entries_list = try m.mapEntries(a);
    defer entries_list.deinit(a);
    try std.testing.expect(entries_list.items.len == 4); // 2 keys + 2 vals

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::equals" {
    const a = std.heap.page_allocator;
    var m1 = PersistentHashMap.empty();
    var m2 = PersistentHashMap.empty();

    m1 = try m1.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m1 = try m1.mapAssoc(a, Value.intValue(2), Value.intValue(20));

    m2 = try m2.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m2 = try m2.mapAssoc(a, Value.intValue(2), Value.intValue(20));

    try std.testing.expect(m1.mapEquals(m2));

    // m1.deinit(a);
    // m2.deinit(a);
}

test "persistent_hash_map::merge" {
    const a = std.heap.page_allocator;
    var m1 = PersistentHashMap.empty();
    var m2 = PersistentHashMap.empty();

    m1 = try m1.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m1 = try m1.mapAssoc(a, Value.intValue(2), Value.intValue(20));

    m2 = try m2.mapAssoc(a, Value.intValue(2), Value.intValue(99));
    m2 = try m2.mapAssoc(a, Value.intValue(3), Value.intValue(30));

    var merged = try m1.mapMerge(a, m2);
    try std.testing.expect(merged.mapCount() == 3);
    try std.testing.expect(merged.find(Value.intValue(1)).?.int_val == 10);
    try std.testing.expect(merged.find(Value.intValue(2)).?.int_val == 99);
    try std.testing.expect(merged.find(Value.intValue(3)).?.int_val == 30);

    // m1.deinit(a);
    // m2.deinit(a);
    // merged.deinit(a);
}

test "persistent_hash_map::many entries (triggers ArrayNode)" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const key = Value.intValue(@as(i64, @intCast(i)));
        const val = Value.intValue(@as(i64, @intCast(i * 10)));
        m = try m.mapAssoc(a, key, val);
    }

    try std.testing.expect(m.mapCount() == 50);

    i = 0;
    while (i < 50) : (i += 1) {
        const key = Value.intValue(@as(i64, @intCast(i)));
        const found = m.find(key);
        try std.testing.expect(found != null);
        try std.testing.expect(found.?.int_val == @as(i64, @intCast(i * 10)));
    }

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::remove all entries" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        m = try m.mapAssoc(a, Value.intValue(@as(i64, @intCast(i))), Value.intValue(@as(i64, @intCast(i * 10))));
    }

    i = 0;
    while (i < 10) : (i += 1) {
        m = try m.mapWithout(a, Value.intValue(@as(i64, @intCast(i))));
    }

    try std.testing.expect(m.isEmpty());
    try std.testing.expect(m.mapCount() == 0);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::hash consistency" {
    const v1 = Value.intValue(42);
    const v2 = Value.intValue(42);
    try std.testing.expect(valueHash(v1) == valueHash(v2));

    const s = "hello";
    const sv1 = try std.heap.page_allocator.dupe(u8, s);
    const sv2 = try std.heap.page_allocator.dupe(u8, s);
    defer std.heap.page_allocator.free(sv1);
    defer std.heap.page_allocator.free(sv2);

    const str1 = Value{ .type = .string, .str_val = sv1 };
    const str2 = Value{ .type = .string, .str_val = sv2 };
    try std.testing.expect(valueHash(str1) == valueHash(str2));
}

test "persistent_hash_map::findDefault" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();
    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));

    try std.testing.expect(m.findDefault(Value.intValue(1), Value.nilValue()).int_val == 10);
    try std.testing.expect(m.findDefault(Value.intValue(99), Value.nilValue()).type == .nil);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::structural sharing" {
    const a = std.heap.page_allocator;
    var m1 = PersistentHashMap.empty();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        m1 = try m1.mapAssoc(a, Value.intValue(@as(i64, @intCast(i))), Value.intValue(@as(i64, @intCast(i * 10))));
    }

    var m2 = try m1.mapAssoc(a, Value.intValue(50), Value.intValue(999));

    try std.testing.expect(m1.find(Value.intValue(50)).?.int_val == 500);
    try std.testing.expect(m2.find(Value.intValue(50)).?.int_val == 999);
    try std.testing.expect(m1.find(Value.intValue(0)).?.int_val == 0);
    try std.testing.expect(m2.find(Value.intValue(0)).?.int_val == 0);

    // m1.deinit(a);
    // m2.deinit(a);
}

test "persistent_hash_map::entry iterator" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));
    m = try m.mapAssoc(a, Value.intValue(2), Value.intValue(20));
    m = try m.mapAssoc(a, Value.intValue(3), Value.intValue(30));

    var it = m.entryIterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count == 3);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}

test "persistent_hash_map::entry iterator with nil key" {
    const a = std.heap.page_allocator;
    var m = PersistentHashMap.empty();

    m = try m.mapAssoc(a, Value.nilValue(), Value.intValue(0));
    m = try m.mapAssoc(a, Value.intValue(1), Value.intValue(10));

    var it = m.entryIterator();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count == 2);

    // m.deinit(a); // skip deinit for standalone test (shallow copy in path copying)
}


