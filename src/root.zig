const std = @import("std");

pub fn DeduplicationTable(comptime Index: type, comptime Context: type) type {
    comptime {
        if (@typeInfo(Index) != .int or @typeInfo(Index).int.signedness != .unsigned) {
            @compileError("Index must be an unsigned integer");
        }
    }

    return struct {
        const Self = @This();
        pub const EMPTY: Index = std.math.maxInt(Index);

        slots: []Index,
        count: usize,

        pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !Self {
            const cap = if (initial_capacity > 0)
                try std.math.ceilPowerOfTwo(usize, @max(initial_capacity, 16))
            else
                0;

            const slots = try allocator.alloc(Index, cap);
            @memset(slots, EMPTY);

            return .{
                .slots = slots,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn find(self: *const Self, ctx: Context, key: Context.Key) ?Index {
            if (self.slots.len == 0) return null;
            const mask = self.slots.len - 1;
            var idx = @as(usize, @intCast(ctx.hash(key))) & mask;

            while (self.slots[idx] != EMPTY) : (idx = (idx + 1) & mask) {
                const candidate = self.slots[idx];
                if (ctx.eql(key, candidate)) return candidate;
            }
            return null;
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, ctx: Context, key: Context.Key, value: Index) !void {
            if ((self.count + 1) * 2 >= self.slots.len) {
                try self.grow(allocator, ctx);
            }

            const mask = self.slots.len - 1;
            var idx = @as(usize, @intCast(ctx.hash(key))) & mask;

            while (self.slots[idx] != EMPTY) : (idx = (idx + 1) & mask) {
                if (ctx.eql(key, self.slots[idx])) {
                    self.slots[idx] = value;
                    return;
                }
            }

            self.slots[idx] = value;
            self.count += 1;
        }

        fn grow(self: *Self, allocator: std.mem.Allocator, ctx: Context) !void {
            const new_cap = @max(self.slots.len * 2, 32);
            const new_slots = try allocator.alloc(Index, new_cap);
            @memset(new_slots, EMPTY);

            const new_mask = new_cap - 1;
            for (self.slots) |idx| {
                if (idx == EMPTY) continue;
                const key = ctx.getKey(idx);
                var slot = @as(usize, @intCast(ctx.hash(key))) & new_mask;
                while (new_slots[slot] != EMPTY) : (slot = (slot + 1) & new_mask) {}
                new_slots[slot] = idx;
            }

            allocator.free(self.slots);
            self.slots = new_slots;
        }
    };
}

pub fn DenseDag(
    comptime Index: type,
    comptime TargetChunkSize: usize,
) type {
    comptime {
        if (@typeInfo(Index) != .int or @typeInfo(Index).int.signedness != .unsigned) {
            @compileError("Index must be an unsigned integer");
        }
        if (TargetChunkSize < 4) {
            @compileError("TargetChunkSize must be at least 4 bytes");
        }
    }

    return struct {
        const Self = @This();
        pub const I = Index;

        pub const MIN_CHUNK_SIZE: usize = @max(1, TargetChunkSize / 2);
        pub const MAX_CHUNK_SIZE: usize = TargetChunkSize * 4;
        pub const CHUNK_MASK: u32 = (@as(u32, 1) << @intCast(std.math.log2_int(usize, TargetChunkSize))) - 1;

        pub const Ref = packed struct(Index) {
            index: @Int(.unsigned, @bitSizeOf(Index) - 1),
            is_internal: bool,

            pub const null_ref: Ref = @bitCast(@as(Index, std.math.maxInt(Index)));

            pub inline fn isNull(self: Ref) bool {
                return self.raw() == std.math.maxInt(Index);
            }

            pub inline fn initLeaf(idx: usize) Ref {
                return .{ .index = @intCast(idx), .is_internal = false };
            }

            pub inline fn initInternal(idx: usize) Ref {
                return .{ .index = @intCast(idx), .is_internal = true };
            }

            pub inline fn raw(self: Ref) Index {
                return @bitCast(self);
            }

            pub inline fn fromRaw(val: Index) Ref {
                return @bitCast(val);
            }
        };

        pub const Node = extern struct {
            left: Ref,
            right: Ref,
            weight: u64,
        };

        pub const ChunkDescriptor = extern struct {
            offset: u64,
            length: u32,
        };

        const NodeContext = struct {
            pub const Key = struct { left: Ref, right: Ref };
            dag: *const Self,

            pub inline fn hash(_: NodeContext, key: Key) u64 {
                var h: u64 = 0xcbf29ce484222325;
                h = (h ^ key.left.raw()) *% 0x100000001b3;
                h = (h ^ key.right.raw()) *% 0x100000001b3;
                return h;
            }

            pub inline fn eql(self: NodeContext, key: Key, candidate_idx: Index) bool {
                const node = self.dag.nodes.items[candidate_idx];
                return node.left.raw() == key.left.raw() and node.right.raw() == key.right.raw();
            }

            pub inline fn getKey(self: NodeContext, candidate_idx: Index) Key {
                const node = self.dag.nodes.items[candidate_idx];
                return .{ .left = node.left, .right = node.right };
            }
        };

        const ChunkContext = struct {
            pub const Key = []const u8;
            dag: *const Self,

            pub inline fn hash(_: ChunkContext, key: Key) u64 {
                return std.hash.XxHash64.hash(0, key);
            }

            pub inline fn eql(self: ChunkContext, key: Key, candidate_idx: Index) bool {
                const desc = self.dag.chunks.items[candidate_idx];
                const slice = self.dag.chunk_payload.items[desc.offset .. desc.offset + desc.length];
                return std.mem.eql(u8, key, slice);
            }

            pub inline fn getKey(self: ChunkContext, candidate_idx: Index) Key {
                const desc = self.dag.chunks.items[candidate_idx];
                return self.dag.chunk_payload.items[desc.offset .. desc.offset + desc.length];
            }
        };

        pub const NodeMap = DeduplicationTable(Index, NodeContext);
        pub const ChunkMap = DeduplicationTable(Index, ChunkContext);

        pub const GEAR_TABLE: [256]u32 = blk: {
            @setEvalBranchQuota(100000);
            var table: [256]u32 = undefined;
            var state: u64 = 0x2545F4914F6CDD1D;
            for (&table) |*slot| {
                state = state *% 6364136223846793005 +% 1442695040888963407;
                slot.* = @truncate(state >> 16);
            }
            break :blk table;
        };

        nodes: std.ArrayList(Node),
        chunks: std.ArrayList(ChunkDescriptor),
        chunk_payload: std.ArrayList(u8),
        node_index: NodeMap,
        chunk_index: ChunkMap,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .nodes = try std.ArrayList(Node).initCapacity(allocator, 1024),
                .chunks = try std.ArrayList(ChunkDescriptor).initCapacity(allocator, 1024),
                .chunk_payload = try std.ArrayList(u8).initCapacity(allocator, 16384),
                .node_index = try NodeMap.init(allocator, 2048),
                .chunk_index = try ChunkMap.init(allocator, 2048),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.chunk_index.deinit(allocator);
            self.node_index.deinit(allocator);
            self.chunk_payload.deinit(allocator);
            self.chunks.deinit(allocator);
            self.nodes.deinit(allocator);
        }

        pub inline fn weightOf(self: *const Self, ref: Ref) u64 {
            if (ref.isNull()) return 0;
            return if (ref.is_internal)
                self.nodes.items[ref.index].weight
            else
                self.chunks.items[ref.index].length;
        }

        pub fn registerChunk(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !Ref {
            const ctx = ChunkContext{ .dag = self };
            if (self.chunk_index.find(ctx, bytes)) |existing_idx| {
                return Ref.initLeaf(existing_idx);
            }

            const chunk_idx: Index = @intCast(self.chunks.items.len);
            const payload_offset = self.chunk_payload.items.len;

            try self.chunk_payload.appendSlice(allocator, bytes);
            try self.chunks.append(allocator, .{
                .offset = payload_offset,
                .length = @intCast(bytes.len),
            });

            try self.chunk_index.insert(allocator, ctx, bytes, chunk_idx);
            return Ref.initLeaf(chunk_idx);
        }

        pub fn combine(self: *Self, allocator: std.mem.Allocator, left: Ref, right: Ref) !Ref {
            const ctx = NodeContext{ .dag = self };
            const key = NodeContext.Key{ .left = left, .right = right };

            if (self.node_index.find(ctx, key)) |existing_idx| {
                return Ref.initInternal(existing_idx);
            }

            const node_idx: Index = @intCast(self.nodes.items.len);
            const combined_weight = self.weightOf(left) + self.weightOf(right);

            try self.nodes.append(allocator, .{
                .left = left,
                .right = right,
                .weight = combined_weight,
            });

            try self.node_index.insert(allocator, ctx, key, node_idx);
            return Ref.initInternal(node_idx);
        }

        pub fn read(
            self: *const Self,
            root: Ref,
            total_size: u64,
            offset: u64,
            destination: []u8,
        ) usize {
            if (offset >= total_size or destination.len == 0 or root.isNull()) return 0;

            const target_length = @min(destination.len, @as(usize, @intCast(total_size - offset)));
            var cursor: usize = 0;

            const Frame = struct { ref: Ref, offset: u64, length: u64 };
            var stack: [64]Frame = undefined;
            var depth: usize = 1;
            stack[0] = .{ .ref = root, .offset = offset, .length = target_length };

            while (depth > 0) {
                depth -= 1;
                const frame = stack[depth];

                if (!frame.ref.is_internal) {
                    const desc = self.chunks.items[frame.ref.index];
                    const payload = self.chunk_payload.items[desc.offset .. desc.offset + desc.length];
                    const slice = payload[frame.offset .. frame.offset + frame.length];

                    @memcpy(destination[cursor .. cursor + slice.len], slice);
                    cursor += slice.len;
                    if (cursor >= target_length) return cursor;
                    continue;
                }

                const node = self.nodes.items[frame.ref.index];
                const left_size = self.weightOf(node.left);

                if (frame.offset + frame.length > left_size) {
                    const right_start = if (frame.offset > left_size) frame.offset - left_size else 0;
                    const right_len = if (frame.offset > left_size)
                        frame.length
                    else
                        (frame.offset + frame.length) - left_size;
                    stack[depth] = .{ .ref = node.right, .offset = right_start, .length = right_len };
                    depth += 1;
                }

                if (frame.offset < left_size) {
                    const left_read = @min(frame.length, left_size - frame.offset);
                    stack[depth] = .{ .ref = node.left, .offset = frame.offset, .length = left_read };
                    depth += 1;
                }
            }

            return cursor;
        }
    };
}

pub fn FileSystem(
    comptime Index: type,
    comptime TargetChunkSize: usize,
) type {
    return struct {
        const Self = @This();
        pub const Dag = DenseDag(Index, TargetChunkSize);
        pub const Ref = Dag.Ref;
        pub const I = Index;

        pub const PathEntry = struct {
            path: []const u8,
            root: Ref,
            size: u64,
            chunk_buffer: std.ArrayList(u8),
            rolling_hash: u32,
            levels: std.ArrayList(std.ArrayList(Ref)),
            dirty: bool,
        };

        dag: Dag,
        entries: std.ArrayList(PathEntry),
        active_entry: ?*PathEntry,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .dag = try Dag.init(allocator),
                .entries = try std.ArrayList(PathEntry).initCapacity(allocator, 16),
                .active_entry = null,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.entries.items) |*entry| {
                allocator.free(entry.path);
                entry.chunk_buffer.deinit(allocator);
                for (entry.levels.items) |*level| level.deinit(allocator);
                entry.levels.deinit(allocator);
            }
            self.entries.deinit(allocator);
            self.dag.deinit(allocator);
        }

        pub fn prepareForEncode(self: *Self, allocator: std.mem.Allocator, path: []const u8) !void {
            var unique_path = try allocator.dupe(u8, path);
            var version: usize = 0;

            while (self.findEntry(unique_path) != null) {
                allocator.free(unique_path);
                unique_path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, version });
                version += 1;
            }

            try self.entries.append(allocator, .{
                .path = unique_path,
                .root = Ref.null_ref,
                .size = 0,
                .chunk_buffer = try std.ArrayList(u8).initCapacity(allocator, Dag.MAX_CHUNK_SIZE),
                .rolling_hash = 0,
                .levels = try std.ArrayList(std.ArrayList(Ref)).initCapacity(allocator, 16),
                .dirty = true,
            });
            self.active_entry = &self.entries.items[self.entries.items.len - 1];
        }

        pub fn findEntry(self: *const Self, path: []const u8) ?*PathEntry {
            if (self.active_entry) |active| {
                if (std.mem.eql(u8, active.path, path)) return active;
            }
            for (self.entries.items) |*entry| {
                if (std.mem.eql(u8, entry.path, path)) return entry;
            }
            return null;
        }

        pub fn getOrAddEntry(self: *Self, allocator: std.mem.Allocator, path: []const u8) !*PathEntry {
            if (self.findEntry(path)) |entry| {
                self.active_entry = entry;
                return entry;
            }

            try self.entries.append(allocator, .{
                .path = try allocator.dupe(u8, path),
                .root = Ref.null_ref,
                .size = 0,
                .chunk_buffer = try std.ArrayList(u8).initCapacity(allocator, Dag.MAX_CHUNK_SIZE),
                .rolling_hash = 0,
                .levels = try std.ArrayList(std.ArrayList(Ref)).initCapacity(allocator, 16),
                .dirty = false,
            });

            const entry = &self.entries.items[self.entries.items.len - 1];
            self.active_entry = entry;
            return entry;
        }

        inline fn isTreeBoundary(ref: Ref) bool {
            var z = (@as(u64, ref.raw()) ^ 0x9E3779B97F4A7C15);
            z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
            return ((z ^ (z >> 31)) & 0x07) == 0;
        }

        fn foldSlice(self: *Self, allocator: std.mem.Allocator, items: []const Ref) std.mem.Allocator.Error!Ref {
            if (items.len == 0) return Ref.null_ref;
            if (items.len == 1) return items[0];
            const mid = items.len / 2;
            const left = try self.foldSlice(allocator, items[0..mid]);
            const right = try self.foldSlice(allocator, items[mid..]);
            return try self.dag.combine(allocator, left, right);
        }

        fn pushToTree(self: *Self, allocator: std.mem.Allocator, entry: *PathEntry, level: usize, ref: Ref) std.mem.Allocator.Error!void {
            while (entry.levels.items.len <= level) {
                try entry.levels.append(allocator, try std.ArrayList(Ref).initCapacity(allocator, 32));
            }

            var current = &entry.levels.items[level];
            try current.append(allocator, ref);

            if ((isTreeBoundary(ref) and current.items.len >= 2) or current.items.len >= 16) {
                const subtree = try self.foldSlice(allocator, current.items);
                current.clearRetainingCapacity();
                try self.pushToTree(allocator, entry, level + 1, subtree);
            }
        }

        fn flushActiveChunk(self: *Self, allocator: std.mem.Allocator, entry: *PathEntry) !void {
            if (entry.chunk_buffer.items.len == 0) return;
            const leaf_ref = try self.dag.registerChunk(allocator, entry.chunk_buffer.items);
            entry.chunk_buffer.clearRetainingCapacity();
            entry.rolling_hash = 0;
            try self.pushToTree(allocator, entry, 0, leaf_ref);
        }

        pub fn appendSlice(self: *Self, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
            const entry = try self.getOrAddEntry(allocator, path);
            entry.dirty = true;
            entry.size += bytes.len;

            var cursor: usize = 0;
            while (cursor < bytes.len) {
                const b = bytes[cursor];
                cursor += 1;
                try entry.chunk_buffer.append(allocator, b);
                entry.rolling_hash = (entry.rolling_hash << 1) +% Dag.GEAR_TABLE[b];

                if (entry.chunk_buffer.items.len >= Dag.MIN_CHUNK_SIZE) {
                    if ((entry.rolling_hash & Dag.CHUNK_MASK) == 0 or entry.chunk_buffer.items.len >= Dag.MAX_CHUNK_SIZE) {
                        try self.flushActiveChunk(allocator, entry);
                    }
                }
            }
        }

        pub fn syncEntry(self: *Self, allocator: std.mem.Allocator, entry: *PathEntry) !Ref {
            if (!entry.dirty) return entry.root;

            if (entry.chunk_buffer.items.len > 0) {
                try self.flushActiveChunk(allocator, entry);
            }

            var level: usize = 0;
            while (level < entry.levels.items.len) : (level += 1) {
                const current = &entry.levels.items[level];
                if (current.items.len == 0) continue;
                if (current.items.len == 1 and level + 1 >= entry.levels.items.len) break;

                const subtree = try self.foldSlice(allocator, current.items);
                current.clearRetainingCapacity();

                while (entry.levels.items.len <= level + 1) {
                    try entry.levels.append(allocator, try std.ArrayList(Ref).initCapacity(allocator, 32));
                }
                try entry.levels.items[level + 1].append(allocator, subtree);
            }

            var final_root = Ref.null_ref;
            var idx = entry.levels.items.len;
            while (idx > 0) {
                idx -= 1;
                if (entry.levels.items[idx].items.len > 0) {
                    final_root = entry.levels.items[idx].items[0];
                    break;
                }
            }

            entry.root = final_root;
            entry.dirty = false;
            return final_root;
        }

        pub fn read(
            self: *Self,
            allocator: std.mem.Allocator,
            path: []const u8,
            offset: u64,
            destination: []u8,
        ) !usize {
            const entry = self.findEntry(path) orelse return error.FileNotFound;
            const root = try self.syncEntry(allocator, entry);
            return self.dag.read(root, entry.size, offset, destination);
        }

        pub fn size(self: *Self, allocator: std.mem.Allocator, path: []const u8) !?u64 {
            const entry = self.findEntry(path) orelse return null;
            _ = try self.syncEntry(allocator, entry);
            return entry.size;
        }

        pub fn writeTo(self: *Self, io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !void {
            for (self.entries.items) |*entry| {
                _ = try self.syncEntry(allocator, entry);
            }

            var stream_buffer: [65536]u8 = undefined;
            var buffered_writer = file.writer(io, &stream_buffer);
            const w = &buffered_writer.interface;

            const total_payload_bytes: u64 = self.dag.chunk_payload.items.len;
            try w.writeAll(std.mem.asBytes(&total_payload_bytes));
            if (total_payload_bytes > 0) {
                try w.writeAll(self.dag.chunk_payload.items);
            }

            const total_chunks: u64 = self.dag.chunks.items.len;
            try w.writeAll(std.mem.asBytes(&total_chunks));
            for (self.dag.chunks.items) |chunk| {
                try w.writeAll(std.mem.asBytes(&chunk.length));
            }

            const total_nodes: u64 = self.dag.nodes.items.len;
            try w.writeAll(std.mem.asBytes(&total_nodes));
            for (self.dag.nodes.items) |node| {
                const raw_left = node.left.raw();
                const raw_right = node.right.raw();
                try w.writeAll(std.mem.asBytes(&raw_left));
                try w.writeAll(std.mem.asBytes(&raw_right));
            }

            const total_entries: u64 = self.entries.items.len;
            try w.writeAll(std.mem.asBytes(&total_entries));
            for (self.entries.items) |entry| {
                const path_len: u32 = @intCast(entry.path.len);
                try w.writeAll(std.mem.asBytes(&path_len));
                try w.writeAll(entry.path);
                const raw_root = entry.root.raw();
                try w.writeAll(std.mem.asBytes(&raw_root));
                try w.writeAll(std.mem.asBytes(&entry.size));
            }

            try w.flush();
        }

        pub fn loadFrom(self: *Self, io: std.Io, allocator: std.mem.Allocator, file: std.Io.File, rebuild_index: bool) !void {
            const stat = try file.stat(io);
            if (stat.size == 0) return;

            var mapping = try std.Io.File.MemoryMap.create(io, file, .{
                .len = stat.size,
                .protection = .{ .read = true, .write = false },
            });
            defer mapping.destroy(io);

            var cursor: usize = 0;
            const bytes = mapping.memory;

            const total_payload_bytes = std.mem.bytesToValue(u64, bytes[cursor..][0..@sizeOf(u64)]);
            cursor += @sizeOf(u64);

            const payload_base = self.dag.chunk_payload.items.len;
            if (total_payload_bytes > 0) {
                try self.dag.chunk_payload.appendSlice(allocator, bytes[cursor .. cursor + total_payload_bytes]);
                cursor += total_payload_bytes;
            }

            const total_chunks = std.mem.bytesToValue(u64, bytes[cursor..][0..@sizeOf(u64)]);
            cursor += @sizeOf(u64);

            const chunks_base = self.dag.chunks.items.len;
            if (total_chunks > 0) {
                var offset: u64 = payload_base;
                for (0..total_chunks) |i| {
                    const chunk_len = std.mem.bytesToValue(u32, bytes[cursor..][0..@sizeOf(u32)]);
                    cursor += @sizeOf(u32);

                    try self.dag.chunks.append(allocator, .{
                        .offset = offset,
                        .length = chunk_len,
                    });

                    if (rebuild_index) {
                        const chunk_slice = self.dag.chunk_payload.items[offset .. offset + chunk_len];
                        const chunk_idx: Index = @intCast(chunks_base + i);
                        const ctx = Dag.ChunkContext{ .dag = &self.dag };
                        try self.dag.chunk_index.insert(allocator, ctx, chunk_slice, chunk_idx);
                    }

                    offset += chunk_len;
                }
            }

            const total_nodes = std.mem.bytesToValue(u64, bytes[cursor..][0..@sizeOf(u64)]);
            cursor += @sizeOf(u64);

            const nodes_base = self.dag.nodes.items.len;
            if (total_nodes > 0) {
                try self.dag.nodes.resize(allocator, nodes_base + total_nodes);

                for (0..total_nodes) |i| {
                    const node_idx = nodes_base + i;
                    const raw_left = std.mem.bytesToValue(Index, bytes[cursor..][0..@sizeOf(Index)]);
                    cursor += @sizeOf(Index);
                    const raw_right = std.mem.bytesToValue(Index, bytes[cursor..][0..@sizeOf(Index)]);
                    cursor += @sizeOf(Index);

                    const left = Ref.fromRaw(raw_left);
                    const right = Ref.fromRaw(raw_right);
                    const weight = self.dag.weightOf(left) + self.dag.weightOf(right);

                    self.dag.nodes.items[node_idx] = .{
                        .left = left,
                        .right = right,
                        .weight = weight,
                    };

                    if (rebuild_index) {
                        const ctx = Dag.NodeContext{ .dag = &self.dag };
                        const key = Dag.NodeContext.Key{ .left = left, .right = right };
                        try self.dag.node_index.insert(allocator, ctx, key, @intCast(node_idx));
                    }
                }
            }

            const total_entries = std.mem.bytesToValue(u64, bytes[cursor..][0..@sizeOf(u64)]);
            cursor += @sizeOf(u64);

            for (0..total_entries) |_| {
                const name_len = std.mem.bytesToValue(u32, bytes[cursor..][0..@sizeOf(u32)]);
                cursor += @sizeOf(u32);

                const entry_path = bytes[cursor .. cursor + name_len];
                cursor += name_len;

                const raw_root = std.mem.bytesToValue(Index, bytes[cursor..][0..@sizeOf(Index)]);
                cursor += @sizeOf(Index);

                const entry_size = std.mem.bytesToValue(u64, bytes[cursor..][0..@sizeOf(u64)]);
                cursor += @sizeOf(u64);

                try self.entries.append(allocator, .{
                    .path = try allocator.dupe(u8, entry_path),
                    .root = Ref.fromRaw(raw_root),
                    .size = entry_size,
                    .chunk_buffer = try std.ArrayList(u8).initCapacity(allocator, Dag.MAX_CHUNK_SIZE),
                    .rolling_hash = 0,
                    .levels = try std.ArrayList(std.ArrayList(Ref)).initCapacity(allocator, 16),
                    .dirty = false,
                });
            }
        }
    };
}

pub const DefaultFs = FileSystem(u32, 64);

const c_allocator = std.heap.page_allocator;

fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const TFS_OK: c_int = 0;
pub const TFS_ERR_NULL: c_int = -1;
pub const TFS_ERR_IO: c_int = -2;
pub const TFS_ERR_OOM: c_int = -3;
pub const TFS_ERR_NOT_FOUND: c_int = -4;

export fn tfs_create() ?*DefaultFs {
    const fs = c_allocator.create(DefaultFs) catch return null;
    fs.* = DefaultFs.init(c_allocator) catch {
        c_allocator.destroy(fs);
        return null;
    };
    return fs;
}

export fn tfs_destroy(handle: ?*DefaultFs) void {
    const fs = handle orelse return;
    fs.deinit(c_allocator);
    c_allocator.destroy(fs);
}

export fn tfs_prepare_entry(handle: ?*DefaultFs, path: ?[*:0]const u8) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = path orelse return TFS_ERR_NULL;
    fs.prepareForEncode(c_allocator, std.mem.span(raw_path)) catch return TFS_ERR_OOM;
    return TFS_OK;
}

export fn tfs_append(handle: ?*DefaultFs, path: ?[*:0]const u8, data: ?[*]const u8, len: usize) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = path orelse return TFS_ERR_NULL;
    if (len == 0) return TFS_OK;
    const slice = (data orelse return TFS_ERR_NULL)[0..len];
    fs.appendSlice(c_allocator, std.mem.span(raw_path), slice) catch return TFS_ERR_OOM;
    return TFS_OK;
}

export fn tfs_read(
    handle: ?*DefaultFs,
    path: ?[*:0]const u8,
    offset: u64,
    buf: ?[*]u8,
    len: usize,
    out_read: ?*usize,
) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = path orelse return TFS_ERR_NULL;

    if (len == 0) {
        if (out_read) |r| r.* = 0;
        return TFS_OK;
    }

    const dest = (buf orelse return TFS_ERR_NULL)[0..len];

    const bytes_read = fs.read(c_allocator, std.mem.span(raw_path), offset, dest) catch |err| switch (err) {
        error.FileNotFound => return TFS_ERR_NOT_FOUND,
        else => return TFS_ERR_OOM,
    };

    if (out_read) |r| r.* = bytes_read;
    return TFS_OK;
}

export fn tfs_size(handle: ?*DefaultFs, path: ?[*:0]const u8, out_size: ?*u64) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = path orelse return TFS_ERR_NULL;
    const size_val = (fs.size(c_allocator, std.mem.span(raw_path)) catch return TFS_ERR_OOM) orelse return TFS_ERR_NOT_FOUND;
    if (out_size) |s| s.* = size_val;
    return TFS_OK;
}

export fn tfs_save(handle: ?*DefaultFs, archive_path: ?[*:0]const u8) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = archive_path orelse return TFS_ERR_NULL;
    const path_slice = std.mem.span(raw_path);
    const io = getIo();
    const cwd = std.Io.Dir.cwd();

    if (std.fs.path.dirname(path_slice)) |parent| {
        cwd.createDirPath(io, parent) catch {};
    }

    var file = cwd.createFile(io, path_slice, .{ .truncate = true, .lock = .none }) catch return TFS_ERR_IO;
    defer file.close(io);

    fs.writeTo(io, c_allocator, file) catch return TFS_ERR_IO;
    return TFS_OK;
}

export fn tfs_load(handle: ?*DefaultFs, archive_path: ?[*:0]const u8, rebuild_index: bool) c_int {
    const fs = handle orelse return TFS_ERR_NULL;
    const raw_path = archive_path orelse return TFS_ERR_NULL;
    const path_slice = std.mem.span(raw_path);
    const io = getIo();
    const cwd = std.Io.Dir.cwd();

    var file = cwd.openFile(io, path_slice, .{ .mode = .read_only, .lock = .none }) catch return TFS_ERR_IO;
    defer file.close(io);

    fs.loadFrom(io, c_allocator, file, rebuild_index) catch return TFS_ERR_IO;
    return TFS_OK;
}

export fn tfs_entry_count(handle: ?*DefaultFs) usize {
    const fs = handle orelse return 0;
    return fs.entries.items.len;
}

export fn tfs_entry_name(handle: ?*DefaultFs, index: usize) ?[*:0]const u8 {
    const fs = handle orelse return null;
    if (index >= fs.entries.items.len) return null;
    return @ptrCast(fs.entries.items[index].path.ptr);
}
