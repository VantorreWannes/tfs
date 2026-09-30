const std = @import("std");
const Io = std.Io;
const File = Io.File;

inline fn readInt(r: *std.Io.Reader, comptime T: type) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try r.readSliceAll(&buf);
    return std.mem.readInt(T, &buf, .little);
}

inline fn writeInt(w: *std.Io.Writer, comptime T: type, val: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, val, .little);
    try w.writeAll(&buf);
}

pub fn DenseDAG(comptime Index: type, comptime Leaf: type) type {
    comptime {
        const idx_info = @typeInfo(Index);
        if (idx_info != .int or idx_info.int.signedness != .unsigned) {
            @compileError("Index must be an unsigned integer");
        }
        const leaf_info = @typeInfo(Leaf);
        if (leaf_info != .int or leaf_info.int.signedness != .unsigned) {
            @compileError("Leaf must be an unsigned integer");
        }
    }

    return struct {
        const Self = @This();
        pub const I = Index;
        pub const L = Leaf;
        pub const LEAF_LIMIT: I = @as(I, 1) << @typeInfo(L).int.bits;

        pub const NUM_TIERS: usize = @sizeOf(I) - 1;

        pub const Pair = extern struct {
            l: I,
            r: I,
        };

        pub fn TierPair(comptime byte_width: usize) type {
            const IntT = @Int(.unsigned, byte_width * 8);

            return extern struct {
                l: [byte_width]u8,
                r: [byte_width]u8,

                pub const Int = IntT;
                pub const width = byte_width;

                pub inline fn pack(l_val: I, r_val: I) @This() {
                    var pair: @This() = undefined;
                    std.mem.writeInt(IntT, &pair.l, @truncate(l_val), .little);
                    std.mem.writeInt(IntT, &pair.r, @truncate(r_val), .little);
                    return pair;
                }

                pub inline fn unpackL(self: @This()) I {
                    return @as(I, std.mem.readInt(IntT, &self.l, .little));
                }

                pub inline fn unpackR(self: @This()) I {
                    return @as(I, std.mem.readInt(IntT, &self.r, .little));
                }
            };
        }

        const Key = struct {
            l: I,
            r: I,

            pub fn hash(self: Key) u64 {
                var h = std.hash.Wyhash.init(0);
                h.update(std.mem.asBytes(&self.l));
                h.update(std.mem.asBytes(&self.r));
                return h.final();
            }

            pub fn eql(a: Key, b: Key) bool {
                return a.l == b.l and a.r == b.r;
            }
        };

        const KeyContext = struct {
            pub fn hash(_: @This(), k: Key) u64 {
                return k.hash();
            }
            pub fn eql(_: @This(), a: Key, b: Key) bool {
                return a.eql(b);
            }
        };

        nodes: std.ArrayList(Pair),
        lookup: std.HashMap(Key, I, KeyContext, 80),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .nodes = try std.ArrayList(Pair).initCapacity(allocator, 65536),
                .lookup = std.HashMap(Key, I, KeyContext, 80).init(allocator),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.lookup.deinit();
            self.nodes.deinit(allocator);
        }

        pub fn rebuildIndex(self: *Self) !void {
            try self.lookup.ensureTotalCapacity(@intCast(self.nodes.items.len));
            for (self.nodes.items, 0..) |p, idx| {
                const id: I = @intCast(LEAF_LIMIT + idx);
                self.lookup.putAssumeCapacity(.{ .l = p.l, .r = p.r }, id);
            }
        }

        pub fn combine(self: *Self, allocator: std.mem.Allocator, l: I, r: I) !I {
            const key = Key{ .l = l, .r = r };
            if (self.lookup.get(key)) |id| {
                return id;
            }

            const id: I = @intCast(LEAF_LIMIT + self.nodes.items.len);
            try self.nodes.append(allocator, .{ .l = l, .r = r });
            try self.lookup.put(key, id);
            return id;
        }

        /// High-speed Fast-BPE Ingestion
        fn ingestChunk(self: *Self, allocator: std.mem.Allocator, input_symbols: []const I) !I {
            if (input_symbols.len == 0) return 0;
            if (input_symbols.len == 1) return input_symbols[0];

            const buf_a = try allocator.alloc(I, input_symbols.len);
            defer allocator.free(buf_a);
            const buf_b = try allocator.alloc(I, input_symbols.len);
            defer allocator.free(buf_b);

            @memcpy(buf_a, input_symbols);

            var src = buf_a;
            var dst = buf_b;
            var src_len = input_symbols.len;

            // Phase 1: Sliding Greedy Match against existing rules (Technique #1)
            while (src_len > 1) {
                var matched_any = false;
                var dst_idx: usize = 0;
                var i: usize = 0;

                while (i < src_len) {
                    if (i + 1 < src_len) {
                        const k = Key{ .l = src[i], .r = src[i + 1] };
                        if (self.lookup.get(k)) |existing_id| {
                            dst[dst_idx] = existing_id;
                            dst_idx += 1;
                            i += 2;
                            matched_any = true;
                            continue;
                        }
                    }
                    dst[dst_idx] = src[i];
                    dst_idx += 1;
                    i += 1;
                }

                src_len = dst_idx;
                const tmp = src;
                src = dst;
                dst = tmp;

                if (!matched_any) break;
            }

            // Phase 2: Multi-Pair Geometric BPE (Techniques #2 & #4)
            var counts = std.HashMap(Key, u32, KeyContext, 80).init(allocator);
            defer counts.deinit();

            while (src_len > 1) {
                counts.clearRetainingCapacity();

                // 1. Count frequencies across the chunk
                var max_freq: u32 = 0;
                for (0..src_len - 1) |i| {
                    const k = Key{ .l = src[i], .r = src[i + 1] };
                    const entry = try counts.getOrPut(k);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = 1;
                    } else {
                        entry.value_ptr.* += 1;
                    }
                    if (entry.value_ptr.* > max_freq) {
                        max_freq = entry.value_ptr.*;
                    }
                }

                // Technique #4: Stop if no pair repeats
                if (max_freq < 2) break;

                // Technique #2: Dynamic Top-Tier Threshold
                // Batch replace all pairs in the upper frequency half in ONE pass
                const threshold = @max(2, max_freq / 2);

                var dst_idx: usize = 0;
                var i: usize = 0;
                var replaced_any = false;

                while (i < src_len) {
                    if (i + 1 < src_len) {
                        const k = Key{ .l = src[i], .r = src[i + 1] };
                        if (counts.get(k)) |c| {
                            if (c >= threshold) {
                                const new_id = try self.combine(allocator, src[i], src[i + 1]);
                                dst[dst_idx] = new_id;
                                dst_idx += 1;
                                i += 2;
                                replaced_any = true;
                                continue;
                            }
                        }
                    }
                    dst[dst_idx] = src[i];
                    dst_idx += 1;
                    i += 1;
                }

                src_len = dst_idx;
                const tmp = src;
                src = dst;
                dst = tmp;

                if (!replaced_any) break;
            }

            // Phase 3: Final tree reduction to a single root node
            while (src_len > 1) {
                var dst_idx: usize = 0;
                var i: usize = 0;
                while (i < src_len) {
                    if (i + 1 < src_len) {
                        dst[dst_idx] = try self.combine(allocator, src[i], src[i + 1]);
                        dst_idx += 1;
                        i += 2;
                    } else {
                        dst[dst_idx] = src[i];
                        dst_idx += 1;
                        i += 1;
                    }
                }
                src_len = dst_idx;
                const tmp = src;
                src = dst;
                dst = tmp;
            }

            return src[0];
        }

        pub fn ingestLeaves(self: *Self, allocator: std.mem.Allocator, leaves: []const L) !I {
            if (leaves.len == 0) return 0;
            if (leaves.len == 1) return @as(I, leaves[0]);

            const CHUNK_SIZE: usize = 64 * 1024;
            const num_chunks = (leaves.len + CHUNK_SIZE - 1) / CHUNK_SIZE;

            if (num_chunks == 1) {
                var chunk_leaves = try allocator.alloc(I, leaves.len);
                defer allocator.free(chunk_leaves);
                for (leaves, 0..) |sym, i| {
                    chunk_leaves[i] = @as(I, sym);
                }
                return self.ingestChunk(allocator, chunk_leaves);
            }

            var chunk_roots = try allocator.alloc(I, num_chunks);
            defer allocator.free(chunk_roots);

            var chunk_buf = try allocator.alloc(I, CHUNK_SIZE);
            defer allocator.free(chunk_buf);

            for (0..num_chunks) |ci| {
                const start = ci * CHUNK_SIZE;
                const end = @min(start + CHUNK_SIZE, leaves.len);
                const len = end - start;

                for (leaves[start..end], 0..) |sym, i| {
                    chunk_buf[i] = @as(I, sym);
                }

                chunk_roots[ci] = try self.ingestChunk(allocator, chunk_buf[0..len]);
            }

            return self.ingestChunk(allocator, chunk_roots);
        }

        pub fn reconstruct(self: *const Self, allocator: std.mem.Allocator, root_id: I, writer: *std.Io.Writer) !void {
            if (root_id == 0) return;

            var stack = try std.ArrayList(I).initCapacity(allocator, 4096);
            defer stack.deinit(allocator);
            try stack.append(allocator, root_id);

            var out_buf: [8192]u8 = undefined;
            var buf_pos: usize = 0;

            while (stack.items.len > 0) {
                const curr = stack.pop().?;
                if (curr < LEAF_LIMIT) {
                    const leaf_val: L = @intCast(curr);
                    const leaf_bytes = std.mem.asBytes(&leaf_val);
                    for (leaf_bytes) |b| {
                        out_buf[buf_pos] = b;
                        buf_pos += 1;
                        if (buf_pos == out_buf.len) {
                            try writer.writeAll(&out_buf);
                            buf_pos = 0;
                        }
                    }
                } else {
                    const idx = curr - LEAF_LIMIT;
                    if (idx >= self.nodes.items.len) return error.CorruptNode;
                    const p = self.nodes.items[idx];

                    try stack.append(allocator, p.r);
                    try stack.append(allocator, p.l);
                }
            }

            if (buf_pos > 0) {
                try writer.writeAll(out_buf[0..buf_pos]);
            }
        }
    };
}

pub fn Catalog(comptime Index: type) type {
    return struct {
        const Self = @This();
        pub const I = Index;

        pub const Entry = struct {
            name: []const u8,
            root_id: I,
        };

        entries: std.ArrayList(Entry),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{ .entries = try std.ArrayList(Entry).initCapacity(allocator, 16) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.entries.items) |e| allocator.free(e.name);
            self.entries.deinit(allocator);
        }

        pub fn readFrom(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Self {
            const entry_count = try readInt(reader, u64);
            var self = try Self.init(allocator);

            for (0..entry_count) |_| {
                const name_len = try readInt(reader, u64);
                const name_buf = try allocator.alloc(u8, name_len);
                try reader.readSliceAll(name_buf);
                const root_id = try readInt(reader, I);
                try self.entries.append(allocator, .{ .name = name_buf, .root_id = root_id });
            }
            return self;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, name: []const u8, root_id: I) !void {
            for (self.entries.items) |*e| {
                if (std.mem.eql(u8, e.name, name)) {
                    e.root_id = root_id;
                    return;
                }
            }
            try self.entries.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .root_id = root_id,
            });
        }

        pub fn get(self: *const Self, name: []const u8) ?I {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.name, name)) return e.root_id;
            }
            return null;
        }
    };
}

pub fn Archive(comptime Index: type, comptime Leaf: type) type {
    return struct {
        const Self = @This();
        pub const Dag = DenseDAG(Index, Leaf);
        pub const Cat = Catalog(Index);
        pub const I = Index;
        pub const L = Leaf;
        pub const MAGIC: [4]u8 = "TFSD".*;

        dag: Dag,
        catalog: Cat,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .dag = try Dag.init(allocator),
                .catalog = try Cat.init(allocator),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.catalog.deinit(allocator);
            self.dag.deinit(allocator);
        }

        pub fn readCatalogOnly(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Cat {
            var magic: [4]u8 = undefined;
            try reader.readSliceAll(&magic);
            if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidArchiveFormat;
            return try Cat.readFrom(allocator, reader);
        }

        pub fn readFrom(allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime rebuild_hash_index: bool) !Self {
            var magic: [4]u8 = undefined;
            try reader.readSliceAll(&magic);
            if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidArchiveFormat;

            const catalog = try Cat.readFrom(allocator, reader);
            const total_nodes = try readInt(reader, u64);

            var tier_counts: [Dag.NUM_TIERS]u64 = undefined;
            for (&tier_counts) |*tc| {
                tc.* = try readInt(reader, u64);
            }

            var dag = try Dag.init(allocator);
            try dag.nodes.resize(allocator, total_nodes);

            var offset: usize = 0;
            inline for (0..Dag.NUM_TIERS) |tier_idx| {
                const bw = tier_idx + 2;
                const PairT = Dag.TierPair(bw);
                const count = tier_counts[tier_idx];

                var read_items: usize = 0;
                var chunk_buf: [2048]PairT = undefined;

                while (read_items < count) {
                    const to_read = @min(count - read_items, chunk_buf.len);
                    const byte_slice = std.mem.sliceAsBytes(chunk_buf[0..to_read]);
                    try reader.readSliceAll(byte_slice);

                    for (0..to_read) |idx| {
                        dag.nodes.items[offset + read_items + idx] = .{
                            .l = chunk_buf[idx].unpackL(),
                            .r = chunk_buf[idx].unpackR(),
                        };
                    }
                    read_items += to_read;
                }
                offset += count;
            }

            if (rebuild_hash_index) {
                try dag.rebuildIndex();
            }

            return .{ .dag = dag, .catalog = catalog };
        }

        pub fn writeTo(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.writeAll(&MAGIC);
            try writeInt(writer, u64, self.catalog.entries.items.len);
            for (self.catalog.entries.items) |e| {
                try writeInt(writer, u64, e.name.len);
                try writer.writeAll(e.name);
                try writeInt(writer, I, e.root_id);
            }

            const total: u64 = self.dag.nodes.items.len;
            try writeInt(writer, u64, total);

            var tier_counts: [Dag.NUM_TIERS]u64 = undefined;
            var remaining: u64 = total;
            var prev_limit: u64 = Dag.LEAF_LIMIT;

            inline for (0..Dag.NUM_TIERS) |tier_idx| {
                const bw = tier_idx + 2;
                const limit: u64 = if (bw >= @sizeOf(I)) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bw * 8));
                const tier_capacity = if (limit > prev_limit) limit - prev_limit else 0;
                const count = @min(remaining, tier_capacity);
                tier_counts[tier_idx] = count;
                remaining -= count;
                prev_limit = limit;
            }

            for (tier_counts) |tc| {
                try writeInt(writer, u64, tc);
            }

            var offset: usize = 0;
            inline for (0..Dag.NUM_TIERS) |tier_idx| {
                const bw = tier_idx + 2;
                const PairT = Dag.TierPair(bw);
                const count = tier_counts[tier_idx];

                var written: usize = 0;
                var chunk_buf: [2048]PairT = undefined;

                while (written < count) {
                    const to_write = @min(count - written, chunk_buf.len);
                    for (0..to_write) |idx| {
                        const p = self.dag.nodes.items[offset + written + idx];
                        chunk_buf[idx] = PairT.pack(p.l, p.r);
                    }
                    try writer.writeAll(std.mem.sliceAsBytes(chunk_buf[0..to_write]));
                    written += to_write;
                }
                offset += count;
            }
        }

        pub fn encodeLeaves(self: *Self, allocator: std.mem.Allocator, name: []const u8, leaves: []const L) !I {
            const root_id = try self.dag.ingestLeaves(allocator, leaves);
            try self.catalog.put(allocator, name, root_id);
            return root_id;
        }

        pub fn decodeStream(self: *const Self, allocator: std.mem.Allocator, name: []const u8, writer: *std.Io.Writer) !void {
            const root_id = self.catalog.get(name) orelse return error.EntryNotFound;
            try self.dag.reconstruct(allocator, root_id, writer);
        }
    };
}
