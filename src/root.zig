const std = @import("std");

pub fn ShiftRegister(comptime Int: type) type {
    const info = @typeInfo(Int);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("Int must be an unsigned integer");
    }

    return struct {
        const Self = @This();

        table: [256]Int,
        state: Int,

        pub inline fn init(seed: u64) Self {
            var prng = std.Random.DefaultPrng.init(seed);
            var table: [256]Int = undefined;
            prng.random().bytes(std.mem.sliceAsBytes(&table));
            return .{
                .table = table,
                .state = 0,
            };
        }

        pub inline fn step(self: *Self, byte: u8) void {
            self.state = (self.state << 1) +% self.table[byte];
        }

        pub inline fn read(self: *const Self) Int {
            return self.state;
        }
    };
}

pub fn SpanBuffer(comptime Index: type) type {
    const info = @typeInfo(Index);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("Index must be an unsigned integer");
    }

    return struct {
        const Self = @This();

        pub const FLAG: Index = @as(Index, 1) << (@typeInfo(Index).int.bits - 1);
        pub const MASK: Index = ~FLAG;

        bytes: std.ArrayListUnmanaged(u8) = .empty,
        offsets: std.ArrayListUnmanaged(Index) = .empty,
        pairs: std.ArrayListUnmanaged([2]Index) = .empty,

        pub inline fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.bytes.deinit(allocator);
            self.offsets.deinit(allocator);
            self.pairs.deinit(allocator);
        }

        pub inline fn isPair(index: Index) bool {
            return (index & FLAG) != 0;
        }

        pub fn appendBytes(self: *Self, allocator: std.mem.Allocator, slice: []const u8) !Index {
            const index: Index = @intCast(self.offsets.items.len);
            try self.offsets.append(allocator, @intCast(self.bytes.items.len));
            try self.bytes.appendSlice(allocator, slice);
            return index;
        }

        pub fn appendPair(self: *Self, allocator: std.mem.Allocator, left: Index, right: Index) !Index {
            const index: Index = @intCast(self.pairs.items.len);
            try self.pairs.append(allocator, .{ left, right });
            return index | FLAG;
        }

        pub inline fn readBytes(self: *const Self, index: Index) []const u8 {
            const raw = index & MASK;
            const start = self.offsets.items[raw];
            const end = if (raw + 1 < self.offsets.items.len)
                self.offsets.items[raw + 1]
            else
                self.bytes.items.len;
            return self.bytes.items[start..end];
        }

        pub inline fn readPair(self: *const Self, index: Index) [2]Index {
            return self.pairs.items[index & MASK];
        }
    };
}

pub fn ContentIndex(comptime Index: type) type {
    const info = @typeInfo(Index);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("Index must be an unsigned integer");
    }

    const EMPTY: Index = std.math.maxInt(Index);

    const Entry = extern struct {
        hash: u64,
        index: Index,
    };

    return struct {
        const Self = @This();

        entries: []Entry,
        mask: usize,
        count: usize,

        pub fn init(allocator: std.mem.Allocator, capacity_pow2: usize) !Self {
            const cap = if (capacity_pow2 == 0)
                1024
            else
                @max(1024, try std.math.ceilPowerOfTwo(usize, capacity_pow2));

            const entries = try allocator.alloc(Entry, cap);
            for (entries) |*e| e.index = EMPTY;
            return .{
                .entries = entries,
                .mask = cap - 1,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
        }

        pub inline fn get(self: *const Self, buffer: *const SpanBuffer(Index), hash: u64, slice: []const u8) ?Index {
            var idx = @as(usize, @truncate(hash)) & self.mask;
            while (self.entries[idx].index != EMPTY) : (idx = (idx + 1) & self.mask) {
                if (self.entries[idx].hash == hash) {
                    const id = self.entries[idx].index;
                    if (std.mem.eql(u8, slice, buffer.readBytes(id))) return id;
                }
            }
            return null;
        }

        pub inline fn getPair(self: *const Self, left: Index, right: Index) ?Index {
            const hash = (@as(u64, left) << 32) | right;
            var idx = @as(usize, @truncate(hash)) & self.mask;
            while (self.entries[idx].index != EMPTY) : (idx = (idx + 1) & self.mask) {
                if (self.entries[idx].hash == hash) return self.entries[idx].index;
            }
            return null;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, hash: u64, index: Index) !void {
            if ((self.count + 1) * 2 >= self.entries.len) try self.grow(allocator);

            var idx = @as(usize, @truncate(hash)) & self.mask;
            while (self.entries[idx].index != EMPTY) : (idx = (idx + 1) & self.mask) {
                if (self.entries[idx].hash == hash and self.entries[idx].index == index) return;
            }

            self.entries[idx] = .{ .hash = hash, .index = index };
            self.count += 1;
        }

        fn grow(self: *Self, allocator: std.mem.Allocator) !void {
            const new_cap = self.entries.len * 2;
            const new_entries = try allocator.alloc(Entry, new_cap);
            for (new_entries) |*e| e.index = EMPTY;
            const new_mask = new_cap - 1;

            for (self.entries) |e| {
                if (e.index == EMPTY) continue;
                var idx = @as(usize, @truncate(e.hash)) & new_mask;
                while (new_entries[idx].index != EMPTY) : (idx = (idx + 1) & new_mask) {}
                new_entries[idx] = e;
            }

            allocator.free(self.entries);
            self.entries = new_entries;
            self.mask = new_mask;
        }
    };
}

pub fn CarryLadder(comptime Index: type, comptime depth: usize) type {
    const info = @typeInfo(Index);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("Index must be an unsigned integer");
    }

    const EMPTY: Index = std.math.maxInt(Index);

    return struct {
        const Self = @This();

        slots: [depth]Index = [_]Index{EMPTY} ** depth,

        pub inline fn init() Self {
            return .{};
        }

        pub fn insert(
            self: *Self,
            allocator: std.mem.Allocator,
            buffer: *SpanBuffer(Index),
            dedup: ?*ContentIndex(Index),
            index: Index,
            height: usize,
        ) !void {
            var current = index;
            var h = @min(height, depth - 1);

            for (self.slots[0..h]) |*slot| {
                if (slot.* != EMPTY) {
                    current = try combine(allocator, buffer, dedup, slot.*, current);
                    slot.* = EMPTY;
                }
            }

            while (h < depth and self.slots[h] != EMPTY) : (h += 1) {
                current = try combine(allocator, buffer, dedup, self.slots[h], current);
                self.slots[h] = EMPTY;
            }

            if (h < depth) {
                self.slots[h] = current;
            }
        }

        pub fn collapse(
            self: *Self,
            allocator: std.mem.Allocator,
            buffer: *SpanBuffer(Index),
            dedup: ?*ContentIndex(Index),
        ) !Index {
            var root: Index = EMPTY;
            var i: usize = depth;
            while (i > 0) {
                i -= 1;
                const slot = self.slots[i];
                if (slot == EMPTY) continue;
                root = if (root == EMPTY)
                    slot
                else
                    try combine(allocator, buffer, dedup, root, slot);
            }
            return root;
        }

        inline fn combine(
            allocator: std.mem.Allocator,
            buffer: *SpanBuffer(Index),
            dedup: ?*ContentIndex(Index),
            left: Index,
            right: Index,
        ) !Index {
            if (dedup) |d| {
                if (d.getPair(left, right)) |id| return id;
                const id = try buffer.appendPair(allocator, left, right);
                try d.put(allocator, (@as(u64, left) << 32) | right, id);
                return id;
            }
            return buffer.appendPair(allocator, left, right);
        }
    };
}

pub fn streamToIndex(
    comptime Int: type,
    comptime target_span: usize,
    comptime Index: type,
    _: std.Io,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    seed: u64,
    buffer: *SpanBuffer(Index),
    dedup: ?*ContentIndex(Index),
) !struct { root: Index, byte_count: u64 } {
    comptime {
        if (!std.math.isPowerOfTwo(target_span)) @compileError("target_span must be power of two");
        if (target_span < 32) @compileError("target_span must be at least 32");
    }

    const min_span: usize = target_span / 2;
    const max_span: usize = target_span * 4;
    const mask: Int = @as(Int, @intCast(target_span - 1));

    var reg = ShiftRegister(Int).init(seed);
    var ladder = CarryLadder(Index, 32).init();

    var window: [max_span * 2]u8 = undefined;
    var filled: usize = 0;
    var total_bytes: u64 = 0;
    var is_eof = false;

    while (true) {
        if (!is_eof and filled < max_span) {
            const n = try reader.readSliceShort(window[filled..]);
            if (n == 0) {
                is_eof = true;
            } else {
                filled += n;
                total_bytes += n;
            }
        }

        if (filled == 0) break;

        var cursor = min_span;
        const limit = @min(filled, max_span);

        reg.state = 0;
        while (cursor < limit) : (cursor += 1) {
            reg.step(window[cursor]);
            if ((reg.read() & mask) == 0) {
                cursor += 1;
                break;
            }
        }

        const at_boundary = (cursor >= max_span) or (reg.read() & mask == 0 and cursor > min_span);
        if (!at_boundary and !is_eof) continue;

        const cut_len = if (at_boundary) cursor else filled;
        const chunk = window[0..cut_len];
        const digest = std.hash.XxHash64.hash(0, chunk);

        const index = if (dedup) |d| blk: {
            if (d.get(buffer, digest, chunk)) |id| break :blk id;
            const id = try buffer.appendBytes(allocator, chunk);
            try d.put(allocator, digest, id);
            break :blk id;
        } else try buffer.appendBytes(allocator, chunk);

        try ladder.insert(allocator, buffer, dedup, index, @min(31, @ctz(digest)));

        filled -= cut_len;
        std.mem.copyForwards(u8, window[0..filled], window[cut_len .. cut_len + filled]);

        if (is_eof and filled == 0) break;
    }

    const root = try ladder.collapse(allocator, buffer, dedup);
    return .{ .root = root, .byte_count = total_bytes };
}

pub fn indexToStream(
    comptime Index: type,
    buffer: *const SpanBuffer(Index),
    root: Index,
    writer: *std.Io.Writer,
) anyerror!void {
    if (root == std.math.maxInt(Index)) return;

    if (SpanBuffer(Index).isPair(root)) {
        const pair = buffer.readPair(root);
        try indexToStream(Index, buffer, pair[0], writer);
        try indexToStream(Index, buffer, pair[1], writer);
    } else {
        try writer.writeAll(buffer.readBytes(root));
    }
}

test "roundtrip with content index deduplication" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const seed: u64 = 0x9ABC_DEF0;

    var input: [65536]u8 = undefined;
    for (&input, 0..) |*byte, i| {
        byte.* = @truncate((i *% 17) ^ (i >> 5));
    }

    var buffer = SpanBuffer(u32).init();
    defer buffer.deinit(allocator);

    var dedup = try ContentIndex(u32).init(allocator, 1024);
    defer dedup.deinit(allocator);

    var reader1 = std.Io.Reader.fixed(&input);
    const res1 = try streamToIndex(u32, 128, u32, io, allocator, &reader1, seed, &buffer, &dedup);

    var output_buf: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output_buf);

    try indexToStream(u32, &buffer, res1.root, &writer);
    try std.testing.expectEqualSlices(u8, &input, writer.buffered());

    const byte_count = buffer.bytes.items.len;
    const pair_count = buffer.pairs.items.len;

    var reader2 = std.Io.Reader.fixed(&input);
    const res2 = try streamToIndex(u32, 128, u32, io, allocator, &reader2, seed, &buffer, &dedup);

    try std.testing.expectEqual(res1.root, res2.root);
    try std.testing.expectEqual(res1.byte_count, res2.byte_count);
    try std.testing.expectEqual(byte_count, buffer.bytes.items.len);
    try std.testing.expectEqual(pair_count, buffer.pairs.items.len);
}
