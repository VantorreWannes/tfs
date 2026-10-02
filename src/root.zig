const std = @import("std");

pub const target_span: usize = 1 * 1024;

fn requireUnsigned(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .int) {
        @compileError("expected an unsigned integer");
    }
    if (info.int.signedness != .unsigned) {
        @compileError("expected an unsigned integer");
    }
}

fn requireIndex(comptime Index: type) void {
    requireUnsigned(Index);

    const bits = @bitSizeOf(Index);
    if (bits < 8 or
        bits > @bitSizeOf(usize) or
        bits > 64 or
        !std.math.isPowerOfTwo(bits))
    {
        @compileError("Index must be u8, u16, u32, or u64 and fit usize");
    }
}

fn IdTable(comptime Index: type) type {
    return struct {
        const Self = @This();

        const Probe = union(enum) {
            found: Index,
            vacant: usize,
        };

        controls: []u8 = &.{},
        ids: []Index = &.{},

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.controls);
            allocator.free(self.ids);
            self.* = .{};
        }

        fn fingerprint(hash: u64) u8 {
            return @as(u8, @truncate(hash >> 56)) | 1;
        }

        fn bucket(hash: u64, capacity: usize) usize {
            return @as(usize, @truncate(hash)) & (capacity - 1);
        }

        fn probe(
            self: *const Self,
            hash: u64,
            key: anytype,
            context: anytype,
        ) Probe {
            if (self.controls.len == 0) return .{ .vacant = 0 };

            const tag = fingerprint(hash);
            const mask = self.controls.len - 1;
            var slot = bucket(hash, self.controls.len);

            while (self.controls[slot] != 0) {
                if (self.controls[slot] == tag and
                    context.matches(self.ids[slot], key))
                {
                    return .{ .found = self.ids[slot] };
                }

                slot = (slot + 1) & mask;
            }

            return .{ .vacant = slot };
        }

        fn insert(self: *Self, slot: usize, hash: u64, id: Index) void {
            self.ids[slot] = id;
            self.controls[slot] = fingerprint(hash);
        }

        fn reserve(
            self: *Self,
            allocator: std.mem.Allocator,
            needed: usize,
            context: anytype,
        ) !bool {
            if (needed <= self.controls.len / 2) return false;

            var capacity = @max(@as(usize, 16), self.controls.len);
            while (needed > capacity / 2) {
                if (capacity > std.math.maxInt(usize) / 2) {
                    return error.OutOfMemory;
                }
                capacity *= 2;
            }

            const controls = try allocator.alloc(u8, capacity);
            errdefer allocator.free(controls);

            const ids = try allocator.alloc(Index, capacity);
            errdefer allocator.free(ids);

            @memset(controls, 0);

            const mask = capacity - 1;
            for (self.controls, 0..) |control, old_slot| {
                if (control == 0) continue;

                const id = self.ids[old_slot];
                const hash = context.hash(id);
                var slot = bucket(hash, capacity);

                while (controls[slot] != 0) {
                    slot = (slot + 1) & mask;
                }

                ids[slot] = id;
                controls[slot] = fingerprint(hash);
            }

            allocator.free(self.controls);
            allocator.free(self.ids);

            self.controls = controls;
            self.ids = ids;
            return true;
        }

        fn allocatedBytes(self: *const Self) usize {
            return self.controls.len + self.ids.len * @sizeOf(Index);
        }
    };
}

pub fn SpanStore(comptime Index: type) type {
    comptime requireIndex(Index);

    return struct {
        const Self = @This();
        const Table = IdTable(Index);

        const pair_flag: Index = @as(Index, 1) << (@bitSizeOf(Index) - 1);
        const index_mask: Index = pair_flag - 1;

        pub const InternedBytes = struct {
            id: Index,
            hash: u64,
        };

        pub const Usage = struct {
            payload_bytes: usize,
            leaf_count: usize,
            pair_count: usize,
            lookup_bytes: usize,
        };

        allocator: std.mem.Allocator,
        bytes: std.ArrayListUnmanaged(u8) = .empty,
        offsets: std.ArrayListUnmanaged(usize) = .empty,
        pairs: std.ArrayListUnmanaged([2]Index) = .empty,
        byte_index: Table = .{},
        pair_index: Table = .{},

        const ByteContext = struct {
            store: *const Self,

            fn hash(self: @This(), id: Index) u64 {
                return hashBytes(self.store.readBytes(id));
            }

            fn matches(self: @This(), id: Index, bytes: []const u8) bool {
                return std.mem.eql(u8, self.store.readBytes(id), bytes);
            }
        };

        const PairContext = struct {
            store: *const Self,

            fn hash(self: @This(), id: Index) u64 {
                return hashPair(self.store.readPair(id));
            }

            fn matches(self: @This(), id: Index, pair: [2]Index) bool {
                const existing = self.store.readPair(id);
                return existing[0] == pair[0] and existing[1] == pair[1];
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.byte_index.deinit(self.allocator);
            self.pair_index.deinit(self.allocator);
            self.bytes.deinit(self.allocator);
            self.offsets.deinit(self.allocator);
            self.pairs.deinit(self.allocator);
        }

        pub fn usage(self: *const Self) Usage {
            return .{
                .payload_bytes = self.bytes.items.len,
                .leaf_count = self.offsets.items.len,
                .pair_count = self.pairs.items.len,
                .lookup_bytes = self.byte_index.allocatedBytes() +
                    self.pair_index.allocatedBytes(),
            };
        }

        fn hashBytes(bytes: []const u8) u64 {
            return std.hash.XxHash64.hash(0, bytes);
        }

        fn hashPair(pair: [2]Index) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&pair));
        }

        fn nextIndex(count: usize) !Index {
            if (count > @as(usize, index_mask)) {
                return error.IndexExhausted;
            }
            return @intCast(count);
        }

        pub fn isPair(id: Index) bool {
            return id & pair_flag != 0;
        }

        pub fn pairIndex(id: Index) Index {
            return id & index_mask;
        }

        pub fn readBytes(self: *const Self, id: Index) []const u8 {
            std.debug.assert(!isPair(id));

            const index: usize = @intCast(id);
            const start = self.offsets.items[index];
            const end = if (index + 1 < self.offsets.items.len)
                self.offsets.items[index + 1]
            else
                self.bytes.items.len;

            return self.bytes.items[start..end];
        }

        pub fn readPair(self: *const Self, id: Index) [2]Index {
            std.debug.assert(isPair(id));
            return self.pairs.items[@as(usize, id & index_mask)];
        }

        pub fn findBytes(self: *const Self, bytes: []const u8) ?Index {
            return switch (self.byte_index.probe(
                hashBytes(bytes),
                bytes,
                ByteContext{ .store = self },
            )) {
                .found => |id| id,
                .vacant => null,
            };
        }

        pub fn findPair(self: *const Self, left: Index, right: Index) ?Index {
            const pair = [2]Index{ left, right };

            return switch (self.pair_index.probe(
                hashPair(pair),
                pair,
                PairContext{ .store = self },
            )) {
                .found => |id| id,
                .vacant => null,
            };
        }

        pub fn internBytes(self: *Self, bytes: []const u8) !InternedBytes {
            const hash = hashBytes(bytes);
            const context = ByteContext{ .store = self };

            var slot = switch (self.byte_index.probe(hash, bytes, context)) {
                .found => |id| return .{ .id = id, .hash = hash },
                .vacant => |vacant| vacant,
            };

            const id = try nextIndex(self.offsets.items.len);

            if (try self.byte_index.reserve(
                self.allocator,
                self.offsets.items.len + 1,
                context,
            )) {
                slot = switch (self.byte_index.probe(hash, bytes, context)) {
                    .found => unreachable,
                    .vacant => |vacant| vacant,
                };
            }

            try self.offsets.ensureUnusedCapacity(self.allocator, 1);
            try self.bytes.ensureUnusedCapacity(self.allocator, bytes.len);

            self.offsets.appendAssumeCapacity(self.bytes.items.len);
            self.bytes.appendSliceAssumeCapacity(bytes);
            self.byte_index.insert(slot, hash, id);

            return .{ .id = id, .hash = hash };
        }

        pub fn internPair(self: *Self, left: Index, right: Index) !Index {
            const pair = [2]Index{ left, right };
            const hash = hashPair(pair);
            const context = PairContext{ .store = self };

            var slot = switch (self.pair_index.probe(hash, pair, context)) {
                .found => |id| return id,
                .vacant => |vacant| vacant,
            };

            const id = (try nextIndex(self.pairs.items.len)) | pair_flag;

            if (try self.pair_index.reserve(
                self.allocator,
                self.pairs.items.len + 1,
                context,
            )) {
                slot = switch (self.pair_index.probe(hash, pair, context)) {
                    .found => unreachable,
                    .vacant => |vacant| vacant,
                };
            }

            try self.pairs.ensureUnusedCapacity(self.allocator, 1);

            self.pairs.appendAssumeCapacity(pair);
            self.pair_index.insert(slot, hash, id);

            return id;
        }

        pub fn reindex(self: *Self) !void {
            const byte_context = ByteContext{ .store = self };

            _ = try self.byte_index.reserve(
                self.allocator,
                self.offsets.items.len + 1,
                byte_context,
            );

            for (0..self.offsets.items.len) |i| {
                const id: Index = @intCast(i);
                const bytes = self.readBytes(id);
                const hash = hashBytes(bytes);

                const slot = switch (self.byte_index.probe(hash, bytes, byte_context)) {
                    .found => continue,
                    .vacant => |vacant| vacant,
                };

                self.byte_index.insert(slot, hash, id);
            }

            const pair_context = PairContext{ .store = self };

            _ = try self.pair_index.reserve(
                self.allocator,
                self.pairs.items.len + 1,
                pair_context,
            );

            for (0..self.pairs.items.len) |i| {
                const id = @as(Index, @intCast(i)) | pair_flag;
                const pair = self.pairs.items[i];
                const hash = hashPair(pair);

                const slot = switch (self.pair_index.probe(hash, pair, pair_context)) {
                    .found => continue,
                    .vacant => |vacant| vacant,
                };

                self.pair_index.insert(slot, hash, id);
            }
        }

        pub const LeafIterator = struct {
            store: *const Self,
            current: ?Index,
            pending: std.ArrayListUnmanaged(Index) = .empty,

            pub fn deinit(self: *@This()) void {
                self.pending.deinit(self.store.allocator);
            }

            pub fn next(self: *@This()) !?[]const u8 {
                while (self.current) |id| {
                    if (isPair(id)) {
                        const pair = self.store.readPair(id);
                        try self.pending.append(self.store.allocator, pair[1]);
                        self.current = pair[0];
                    } else {
                        self.current = self.pending.pop();
                        return self.store.readBytes(id);
                    }
                }

                return null;
            }
        };

        pub fn leaves(self: *const Self, root: ?Index) LeafIterator {
            return .{ .store = self, .current = root };
        }

        pub fn write(
            self: *const Self,
            root: ?Index,
            writer: *std.Io.Writer,
        ) !void {
            var iterator = self.leaves(root);
            defer iterator.deinit();

            while (try iterator.next()) |bytes| {
                try writer.writeAll(bytes);
            }
        }
    };
}

pub fn BufferChunker(comptime Int: type, comptime span: usize) type {
    comptime {
        requireUnsigned(Int);

        if (span < 32 or !std.math.isPowerOfTwo(span)) {
            @compileError("span must be a power of two and at least 32");
        }
        if (span > std.math.maxInt(usize) / 4) {
            @compileError("span is too large");
        }
        if (@bitSizeOf(Int) < 8 or @bitSizeOf(Int) % 8 != 0) {
            @compileError("Int must have a positive whole-byte width");
        }
        if (@bitSizeOf(Int) != @sizeOf(Int) * 8) {
            @compileError("Int must not have storage padding");
        }
        if (span - 1 > std.math.maxInt(Int)) {
            @compileError("Int is too small for the boundary mask");
        }
    }

    return struct {
        const Self = @This();

        pub const min_span = span / 2;
        pub const max_span = span * 4;
        const mask: Int = @intCast(span - 1);

        pub const Scan = struct {
            consumed: usize,
            boundary: bool,
        };

        table: [256]Int,
        state: Int = 0,
        length: usize = 0,

        pub fn init(seed: u64) Self {
            var prng = std.Random.DefaultPrng.init(seed);
            var self = Self{ .table = undefined };
            prng.random().bytes(std.mem.sliceAsBytes(&self.table));
            return self;
        }

        pub fn reset(self: *Self) void {
            self.state = 0;
            self.length = 0;
        }

        pub fn scan(self: *Self, bytes: []const u8) Scan {
            var consumed: usize = 0;

            if (self.length < min_span) {
                const skipped = @min(min_span - self.length, bytes.len);
                self.length += skipped;
                consumed += skipped;
            }

            while (consumed < bytes.len) {
                self.state = (self.state << 1) +% self.table[bytes[consumed]];
                self.length += 1;
                consumed += 1;

                if ((self.state & mask) == 0 or self.length == max_span) {
                    self.reset();
                    return .{ .consumed = consumed, .boundary = true };
                }
            }

            return .{ .consumed = consumed, .boundary = false };
        }
    };
}

pub fn CarryLadder(comptime Index: type) type {
    comptime requireIndex(Index);

    return struct {
        const Self = @This();

        slots: std.ArrayListUnmanaged(?Index) = .empty,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.* = .{};
        }

        pub fn clear(self: *Self) void {
            self.slots.clearRetainingCapacity();
        }

        pub fn insert(
            self: *Self,
            store: *SpanStore(Index),
            id: Index,
            height: usize,
        ) !void {
            var destination = height;

            while (destination < self.slots.items.len and
                self.slots.items[destination] != null)
            {
                destination += 1;
            }

            const required = std.math.add(
                usize,
                destination,
                1,
            ) catch return error.InputTooLarge;

            try self.slots.ensureTotalCapacity(store.allocator, required);

            var current = id;
            const occupied_end = @min(destination, self.slots.items.len);

            for (self.slots.items[0..occupied_end]) |slot| {
                if (slot) |held| {
                    current = try store.internPair(held, current);
                }
            }

            if (required > self.slots.items.len) {
                const previous_len = self.slots.items.len;
                self.slots.items.len = required;
                @memset(self.slots.items[previous_len..], null);
            }

            @memset(self.slots.items[0..destination], null);
            self.slots.items[destination] = current;
        }

        pub fn collapse(self: *const Self, store: *SpanStore(Index)) !?Index {
            var root: ?Index = null;
            var level = self.slots.items.len;

            while (level != 0) {
                level -= 1;
                if (self.slots.items[level]) |id| {
                    root = if (root) |left|
                        try store.internPair(left, id)
                    else
                        id;
                }
            }

            return root;
        }
    };
}

pub fn BuildResult(comptime Index: type) type {
    return struct {
        root: ?Index,
        byte_count: u64,
    };
}

pub fn BufferIndexer(comptime Int: type, comptime Index: type) type {
    return struct {
        const Self = @This();
        const Chunker = BufferChunker(Int, target_span);

        store: *SpanStore(Index),
        chunker: Chunker,
        ladder: CarryLadder(Index) = .{},
        pending: [Chunker.max_span]u8 = undefined,
        byte_count: u64 = 0,

        pub fn init(store: *SpanStore(Index), seed: u64) Self {
            return .{
                .store = store,
                .chunker = Chunker.init(seed),
            };
        }

        pub fn deinit(self: *Self) void {
            self.ladder.deinit(self.store.allocator);
        }

        fn appendChunk(self: *Self, bytes: []const u8) !void {
            const leaf = try self.store.internBytes(bytes);
            try self.ladder.insert(self.store, leaf.id, @ctz(leaf.hash));
        }

        pub fn append(self: *Self, bytes: []const u8) !void {
            const total = std.math.add(
                u64,
                self.byte_count,
                @as(u64, @intCast(bytes.len)),
            ) catch return error.InputTooLarge;

            var remaining = bytes;

            while (remaining.len != 0) {
                const buffered = self.chunker.length;
                const scan = self.chunker.scan(remaining);
                const consumed = remaining[0..scan.consumed];

                if (buffered == 0 and scan.boundary) {
                    try self.appendChunk(consumed);
                } else {
                    @memcpy(
                        self.pending[buffered .. buffered + consumed.len],
                        consumed,
                    );

                    if (scan.boundary) {
                        try self.appendChunk(
                            self.pending[0 .. buffered + consumed.len],
                        );
                    }
                }

                remaining = remaining[scan.consumed..];
            }

            self.byte_count = total;
        }

        pub fn finish(self: *Self) !BuildResult(Index) {
            if (self.chunker.length != 0) {
                try self.appendChunk(self.pending[0..self.chunker.length]);
                self.chunker.reset();
            }

            const result = BuildResult(Index){
                .root = try self.ladder.collapse(self.store),
                .byte_count = self.byte_count,
            };

            self.ladder.clear();
            self.byte_count = 0;

            return result;
        }
    };
}

pub fn indexReader(
    comptime Int: type,
    comptime Index: type,
    store: *SpanStore(Index),
    reader: *std.Io.Reader,
    seed: u64,
) !BuildResult(Index) {
    var indexer = BufferIndexer(Int, Index).init(store, seed);
    defer indexer.deinit();

    var input: [16 * 1024]u8 = undefined;

    while (true) {
        const count = try reader.readSliceShort(&input);
        if (count == 0) break;

        try indexer.append(input[0..count]);
    }

    return indexer.finish();
}

test "IdTable" {
    const allocator = std.testing.allocator;

    const Context = struct {
        fn hash(_: @This(), _: u32) u64 {
            return 7;
        }

        fn matches(_: @This(), id: u32, key: u32) bool {
            return id == key;
        }
    };

    {
        var table: IdTable(u32) = .{};
        defer table.deinit(allocator);

        switch (table.probe(7, @as(u32, 0), Context{})) {
            .found => return error.UnexpectedExistingId,
            .vacant => {},
        }

        try std.testing.expectEqual(@as(usize, 0), table.allocatedBytes());
    }

    {
        const context = Context{};
        var table: IdTable(u32) = .{};
        defer table.deinit(allocator);

        for (0..40) |i| {
            const id: u32 = @intCast(i);
            _ = try table.reserve(allocator, i + 1, context);

            const slot = switch (table.probe(7, id, context)) {
                .found => return error.UnexpectedExistingId,
                .vacant => |vacant| vacant,
            };

            table.insert(slot, 7, id);
        }

        for (0..40) |i| {
            const id: u32 = @intCast(i);

            switch (table.probe(7, id, context)) {
                .found => |found| try std.testing.expectEqual(id, found),
                .vacant => return error.MissingId,
            }
        }

        switch (table.probe(7, @as(u32, 100), context)) {
            .found => return error.UnexpectedExistingId,
            .vacant => {},
        }
    }
}

test "SpanStore" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        try std.testing.expect(store.findBytes("") == null);

        const empty = try store.internBytes("");
        const text = try store.internBytes("text");

        try std.testing.expectEqualSlices(u8, "", store.readBytes(empty.id));
        try std.testing.expectEqualSlices(u8, "text", store.readBytes(text.id));
        try std.testing.expectEqual(
            @as(?u32, empty.id),
            store.findBytes(""),
        );
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        const left = try store.internBytes("left");
        const right = try store.internBytes("right");
        const pair = try store.internPair(left.id, right.id);

        try std.testing.expect(!SpanStore(u32).isPair(left.id));
        try std.testing.expect(SpanStore(u32).isPair(pair));

        try std.testing.expectEqualSlices(
            u8,
            "left",
            store.readBytes(left.id),
        );

        const children = store.readPair(pair);
        try std.testing.expectEqual(left.id, children[0]);
        try std.testing.expectEqual(right.id, children[1]);

        try std.testing.expectEqual(
            @as(?u32, left.id),
            store.findBytes("left"),
        );
        try std.testing.expectEqual(
            @as(?u32, pair),
            store.findPair(left.id, right.id),
        );
        try std.testing.expect(store.findBytes("missing") == null);
        try std.testing.expect(store.findPair(right.id, left.id) == null);

        const before = store.usage();

        const repeated_leaf = try store.internBytes("left");
        const repeated_pair = try store.internPair(left.id, right.id);

        try std.testing.expectEqual(left.id, repeated_leaf.id);
        try std.testing.expectEqual(left.hash, repeated_leaf.hash);
        try std.testing.expectEqual(pair, repeated_pair);
        try std.testing.expectEqualDeep(before, store.usage());
    }

    {
        var store = SpanStore(u8).init(allocator);
        defer store.deinit();

        for (0..128) |i| {
            const byte = [_]u8{@intCast(i)};
            _ = try store.internBytes(&byte);
        }

        const extra = [_]u8{128};
        try std.testing.expectError(
            error.IndexExhausted,
            store.internBytes(&extra),
        );

        for (0..128) |i| {
            const byte = [_]u8{@intCast(i)};
            const id = store.findBytes(&byte) orelse return error.MissingLeaf;
            try std.testing.expectEqualSlices(u8, &byte, store.readBytes(id));
        }

        for (0..128) |i| {
            _ = try store.internPair(0, @intCast(i));
        }

        try std.testing.expectError(
            error.IndexExhausted,
            store.internPair(1, 0),
        );

        for (0..128) |i| {
            const right: u8 = @intCast(i);
            const id = store.findPair(0, right) orelse return error.MissingPair;
            const pair = store.readPair(id);

            try std.testing.expectEqual(@as(u8, 0), pair[0]);
            try std.testing.expectEqual(right, pair[1]);
        }
    }
}

test "LeafIterator" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var iterator = store.leaves(null);
        defer iterator.deinit();

        try std.testing.expect((try iterator.next()) == null);
        try std.testing.expect((try iterator.next()) == null);
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        const a = try store.internBytes("a");
        const b = try store.internBytes("bc");
        const root = try store.internPair(a.id, b.id);

        var iterator = store.leaves(root);
        defer iterator.deinit();

        try std.testing.expectEqualSlices(
            u8,
            "a",
            (try iterator.next()) orelse return error.MissingLeaf,
        );
        try std.testing.expectEqualSlices(
            u8,
            "bc",
            (try iterator.next()) orelse return error.MissingLeaf,
        );
        try std.testing.expect((try iterator.next()) == null);
        try std.testing.expect((try iterator.next()) == null);
    }
}

test "SpanStore.write" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var output: [0]u8 = .{};
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(null, &writer);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        const a = try store.internBytes("a");
        const b = try store.internBytes("bc");
        const root = try store.internPair(a.id, b.id);

        var output: [3]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(root, &writer);
        try std.testing.expectEqualSlices(u8, "abc", writer.buffered());
    }
}

test "BufferChunker" {
    const Chunker = BufferChunker(u32, 32);

    {
        const first = Chunker.init(123);
        const second = Chunker.init(123);

        try std.testing.expectEqualSlices(
            u32,
            &first.table,
            &second.table,
        );
    }

    {
        var chunker = Chunker.init(1);
        for (&chunker.table, 0..) |*entry, i| {
            entry.* = @intCast(i);
        }

        const prefix: [Chunker.min_span]u8 = @splat(0);
        const skipped = chunker.scan(&prefix);

        try std.testing.expectEqual(prefix.len, skipped.consumed);
        try std.testing.expect(!skipped.boundary);
        try std.testing.expectEqual(@as(u32, 0), chunker.state);

        const sample = [_]u8{ 1, 2, 3, 4 };
        const expected = [_]u32{ 1, 4, 11, 26 };

        for (sample, expected) |byte, state| {
            const bytes = [_]u8{byte};
            const scan = chunker.scan(&bytes);

            try std.testing.expectEqual(@as(usize, 1), scan.consumed);
            try std.testing.expect(!scan.boundary);
            try std.testing.expectEqual(state, chunker.state);
        }

        chunker.reset();

        try std.testing.expectEqual(@as(usize, 0), chunker.length);
        try std.testing.expectEqual(@as(u32, 0), chunker.state);
    }

    {
        var chunker = Chunker.init(1);
        @memset(&chunker.table, 1);

        const input: [Chunker.max_span]u8 = @splat(0);
        const scan = chunker.scan(&input);

        try std.testing.expect(scan.boundary);
        try std.testing.expectEqual(Chunker.max_span, scan.consumed);
        try std.testing.expectEqual(@as(usize, 0), chunker.length);
        try std.testing.expectEqual(@as(u32, 0), chunker.state);
    }

    {
        var chunker = Chunker.init(1);
        @memset(&chunker.table, 0);

        const input: [Chunker.max_span]u8 = @splat(0);
        const scan = chunker.scan(&input);

        try std.testing.expect(scan.boundary);
        try std.testing.expectEqual(Chunker.min_span + 1, scan.consumed);

        const empty = chunker.scan("");

        try std.testing.expectEqual(@as(usize, 0), empty.consumed);
        try std.testing.expect(!empty.boundary);
    }
}

test "CarryLadder" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var ladder: CarryLadder(u32) = .{};
        defer ladder.deinit(allocator);

        try std.testing.expect((try ladder.collapse(&store)) == null);

        const heights = [_]usize{ 0, 1, 0, 3, 1, 64 };
        const input = "abcdef";

        for (heights, 0..) |height, i| {
            const leaf = try store.internBytes(input[i .. i + 1]);
            try ladder.insert(&store, leaf.id, height);
        }

        var output: [input.len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(try ladder.collapse(&store), &writer);
        try std.testing.expectEqualSlices(u8, input, writer.buffered());

        ladder.clear();
        try std.testing.expect((try ladder.collapse(&store)) == null);
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var ladder: CarryLadder(u32) = .{};
        defer ladder.deinit(allocator);

        const leaf = try store.internBytes("x");
        const repetitions = 1024;

        for (0..repetitions) |_| {
            try ladder.insert(&store, leaf.id, 64);
        }

        const root = try ladder.collapse(&store);
        const stored = store.usage();

        try std.testing.expectEqual(@as(usize, 1), stored.payload_bytes);
        try std.testing.expectEqual(@as(usize, 1), stored.leaf_count);
        try std.testing.expectEqual(@as(usize, 10), stored.pair_count);

        var output: [repetitions]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(root, &writer);

        const expected: [repetitions]u8 = @splat('x');
        try std.testing.expectEqualSlices(u8, &expected, writer.buffered());

        ladder.clear();

        for (0..repetitions) |_| {
            try ladder.insert(&store, leaf.id, 64);
        }

        try std.testing.expectEqual(root, try ladder.collapse(&store));
        try std.testing.expectEqualDeep(stored, store.usage());
    }
}

test "BufferIndexer" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var indexer = BufferIndexer(u32, u32).init(&store, 123);
        defer indexer.deinit();

        try indexer.append("");
        const result = try indexer.finish();

        try std.testing.expect(result.root == null);
        try std.testing.expectEqual(@as(u64, 0), result.byte_count);
        try std.testing.expectEqual(
            @as(usize, 0),
            store.usage().lookup_bytes,
        );
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var indexer = BufferIndexer(u32, u32).init(&store, 123);
        defer indexer.deinit();

        try indexer.append("hel");
        try indexer.append("lo");

        const result = try indexer.finish();

        var output: [5]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(result.root, &writer);
        try std.testing.expectEqualSlices(u8, "hello", writer.buffered());
        try std.testing.expectEqual(@as(u64, 5), result.byte_count);

        const empty = try indexer.finish();
        try std.testing.expect(empty.root == null);
        try std.testing.expectEqual(@as(u64, 0), empty.byte_count);
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var indexer = BufferIndexer(u32, u32).init(&store, 123);
        defer indexer.deinit();

        var input: [65536]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(456);
        prng.random().bytes(&input);

        try indexer.append(&input);
        const whole = try indexer.finish();
        const stored = store.usage();

        var position: usize = 0;
        while (position < input.len) {
            const end = @min(input.len, position + 1 + position % 71);
            try indexer.append(input[position..end]);
            position = end;
        }

        const fragmented = try indexer.finish();

        try std.testing.expectEqual(whole.root, fragmented.root);
        try std.testing.expectEqual(@as(u64, input.len), whole.byte_count);
        try std.testing.expectEqual(whole.byte_count, fragmented.byte_count);
        try std.testing.expectEqualDeep(stored, store.usage());

        var output: [input.len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(fragmented.root, &writer);
        try std.testing.expectEqualSlices(u8, &input, writer.buffered());
    }

    {
        const Exercise = struct {
            fn run(failing_allocator: std.mem.Allocator) !void {
                var store = SpanStore(u32).init(failing_allocator);
                defer store.deinit();

                var input: [target_span * 8 + 1]u8 = undefined;
                var prng = std.Random.DefaultPrng.init(91);
                prng.random().bytes(&input);

                var indexer = BufferIndexer(u32, u32).init(&store, 17);
                defer indexer.deinit();

                const split = input.len / 3;
                try indexer.append(input[0..split]);
                try indexer.append(input[split..]);

                const result = try indexer.finish();

                var output: [input.len]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&output);

                try store.write(result.root, &writer);
                try std.testing.expectEqualSlices(
                    u8,
                    &input,
                    writer.buffered(),
                );
            }
        };

        try std.testing.checkAllAllocationFailures(
            allocator,
            Exercise.run,
            .{},
        );
    }
}

test "indexReader" {
    const allocator = std.testing.allocator;

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        var reader = std.Io.Reader.fixed("");
        const result = try indexReader(u32, u32, &store, &reader, 42);

        try std.testing.expect(result.root == null);
        try std.testing.expectEqual(@as(u64, 0), result.byte_count);
    }

    {
        var store = SpanStore(u32).init(allocator);
        defer store.deinit();

        const Chunker = BufferChunker(u32, target_span);
        var input: [Chunker.max_span * 2 + 17]u8 = undefined;

        var prng = std.Random.DefaultPrng.init(789);
        prng.random().bytes(&input);

        var indexer = BufferIndexer(u32, u32).init(&store, 42);
        defer indexer.deinit();

        try indexer.append(&input);
        const buffered = try indexer.finish();
        const stored = store.usage();

        var reader = std.Io.Reader.fixed(&input);
        const streamed = try indexReader(u32, u32, &store, &reader, 42);

        try std.testing.expectEqual(buffered.root, streamed.root);
        try std.testing.expectEqual(buffered.byte_count, streamed.byte_count);
        try std.testing.expectEqualDeep(stored, store.usage());

        var output: [input.len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&output);

        try store.write(streamed.root, &writer);
        try std.testing.expectEqualSlices(u8, &input, writer.buffered());
    }
}

test "SpanStore.reindex" {
    const allocator = std.testing.allocator;

    var store = SpanStore(u32).init(allocator);
    defer store.deinit();

    const a = try store.internBytes("alpha");
    const b = try store.internBytes("beta");
    const pair = try store.internPair(a.id, b.id);

    store.byte_index.deinit(allocator);
    store.pair_index.deinit(allocator);

    try store.reindex();

    try std.testing.expectEqual(@as(?u32, a.id), store.findBytes("alpha"));
    try std.testing.expectEqual(@as(?u32, b.id), store.findBytes("beta"));
    try std.testing.expectEqual(@as(?u32, pair), store.findPair(a.id, b.id));

    const deduped = try store.internBytes("alpha");
    try std.testing.expectEqual(a.id, deduped.id);
}
