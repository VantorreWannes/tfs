const std = @import("std");
const builtin = @import("builtin");

fn requireUnsigned(comptime T: type, comptime owner: []const u8) std.builtin.Type.Int {
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .unsigned)
        @compileError(owner ++ " requires an unsigned integer, got: " ++ @typeName(T));
    return info.int;
}

fn requireConfig(comptime Config: type) void {
    inline for (.{ "Hash", "Word", "Hasher", "Index", "Root", "Metadata" }) |name| {
        if (!@hasDecl(Config, name))
            @compileError(@typeName(Config) ++ " is not a TreeConfig: missing `" ++ name ++ "`");
    }
}

fn fibonacciMultiplier(comptime bits: comptime_int) comptime_int {
    @setEvalBranchQuota(4 * bits + 1000);
    const target: comptime_int = 5 << (2 * (bits - 1));
    var x: comptime_int = 1 << (bits + 1);
    while (true) {
        const next = (x + target / x) >> 1;
        if (next >= x) break;
        x = next;
    }
    return (x - (1 << (bits - 1))) | 1;
}

fn packPadded(
    comptime To: type,
    comptime From: type,
    gpa: std.mem.Allocator,
    source: []const From,
) std.mem.Allocator.Error![]To {
    const source_bytes = std.mem.sliceAsBytes(source);
    const count = std.math.divCeil(usize, source_bytes.len, @sizeOf(To)) catch unreachable;
    const out = try gpa.alloc(To, count);
    const out_bytes = std.mem.sliceAsBytes(out);
    @memcpy(out_bytes[0..source_bytes.len], source_bytes);
    @memset(out_bytes[source_bytes.len..], 0);
    return out;
}

pub const ContentId = enum(u64) {
    _,

    pub fn fromIndex(position: usize) ContentId {
        return @enumFromInt(position);
    }

    pub fn index(self: ContentId) usize {
        return @intCast(@intFromEnum(self));
    }
};

pub fn NumberHasher(comptime Data: type, comptime Hash: type, comptime seed: Data) type {
    const data_bits = requireUnsigned(Data, "NumberHasher.Data").bits;
    const hash_bits = requireUnsigned(Hash, "NumberHasher.Hash").bits;

    if (data_bits == 0)
        @compileError("NumberHasher.Data must be at least u1");
    if (hash_bits == 0)
        @compileError("NumberHasher.Hash must be at least u1");
    if (hash_bits > data_bits)
        @compileError("NumberHasher.Hash must not be wider than NumberHasher.Data");

    return struct {
        const multiplier: Data = fibonacciMultiplier(data_bits);
        const shift: std.math.Log2Int(Data) = data_bits - hash_bits;

        pub fn hash(data: Data) Hash {
            return @truncate((data *% multiplier +% seed) >> shift);
        }
    };
}

pub fn HashIndex(comptime Hash: type) type {
    _ = requireUnsigned(Hash, "HashIndex");

    return struct {
        const Self = @This();

        map: std.AutoArrayHashMapUnmanaged(Hash, void) = .empty,

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.map.deinit(gpa);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn contains(self: *const Self, hash: Hash) bool {
            return self.map.contains(hash);
        }

        pub fn indexOf(self: *const Self, hash: Hash) ?usize {
            return self.map.getIndex(hash);
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, hash: Hash) std.mem.Allocator.Error!bool {
            const entry = try self.map.getOrPut(gpa, hash);
            return !entry.found_existing;
        }

        pub fn hashes(self: *const Self) []const Hash {
            return self.map.keys();
        }

        pub fn since(self: *const Self, start: usize) []const Hash {
            return self.map.keys()[start..];
        }

        pub fn truncate(self: *Self, len: usize) void {
            std.debug.assert(len <= self.count());
            self.map.shrinkRetainingCapacity(len);
        }
    };
}

pub fn TreeConfig(comptime HashType: type, comptime branching: usize) type {
    const hash_bits = requireUnsigned(HashType, "TreeConfig.Hash").bits;

    if (hash_bits == 0 or hash_bits % 8 != 0)
        @compileError("TreeConfig.Hash width must be a positive multiple of 8");
    if (branching < 2)
        @compileError("TreeConfig fanout must be at least 2");
    if (hash_bits * branching > std.math.maxInt(u16))
        @compileError("TreeConfig word exceeds the maximum integer width");
    if (builtin.cpu.arch.endian() != .little)
        @compileError("TreeConfig reinterprets memory and requires a little-endian target");

    return struct {
        pub const Hash = HashType;
        pub const fanout = branching;
        pub const Word = @Int(.unsigned, hash_bits * branching);
        pub const Hasher = NumberHasher(Word, Hash, 0);
        pub const Index = HashIndex(Hash);

        pub const hash_bytes: usize = hash_bits / 8;
        pub const word_bytes: usize = hash_bytes * branching;

        pub const Root = struct {
            hash: Hash,
            depth: usize,

            pub const empty: Root = .{ .hash = 0, .depth = 0 };

            pub fn isEmpty(self: Root) bool {
                return self.hash == 0;
            }
        };

        pub const Metadata = struct {
            root: Root,
            byte_len: u64,
        };

        pub fn dataBytes(word_count: usize) u64 {
            return @as(u64, word_count) * word_bytes;
        }

        comptime {
            if (@sizeOf(Hash) != hash_bytes or @sizeOf(Word) != word_bytes)
                @compileError("Hash or Word has storage padding, reinterpretation is invalid");
            if (@alignOf(Word) < @alignOf(Hash))
                @compileError("Word must be at least as aligned as Hash");
        }
    };
}

pub fn TreeWords(comptime Config: type) type {
    requireConfig(Config);

    return struct {
        pub fn hash(word: Config.Word) Config.Hash {
            return @max(Config.Hasher.hash(word), 1);
        }

        pub fn fromBytes(gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]Config.Word {
            return packPadded(Config.Word, u8, gpa, bytes);
        }

        pub fn fromHashes(gpa: std.mem.Allocator, hashes: []const Config.Hash) std.mem.Allocator.Error![]Config.Word {
            return packPadded(Config.Word, Config.Hash, gpa, hashes);
        }

        pub fn hashesOf(words: []const Config.Word) []const Config.Hash {
            const hashes = std.mem.bytesAsSlice(Config.Hash, std.mem.sliceAsBytes(words));
            var len = hashes.len;
            while (len > 0 and hashes[len - 1] == 0) len -= 1;
            return hashes[0..len];
        }
    };
}

pub fn TreeWordWriter(comptime Config: type) type {
    requireConfig(Config);
    const Words = TreeWords(Config);

    return struct {
        const Self = @This();

        writer: *std.Io.Writer,
        index: *Config.Index,

        pub fn init(writer: *std.Io.Writer, index: *Config.Index) Self {
            return .{ .writer = writer, .index = index };
        }

        pub fn put(self: *Self, gpa: std.mem.Allocator, word: Config.Word) !Config.Hash {
            const hash = Words.hash(word);
            const position = self.index.count();
            if (!try self.index.insert(gpa, hash)) return hash;
            errdefer self.index.truncate(position);

            try self.writer.writeInt(Config.Word, word, .little);
            return hash;
        }

        pub fn putAll(self: *Self, gpa: std.mem.Allocator, words: []const Config.Word) ![]Config.Hash {
            const hashes = try gpa.alloc(Config.Hash, words.len);
            errdefer gpa.free(hashes);

            for (words, hashes) |word, *hash| hash.* = try self.put(gpa, word);
            return hashes;
        }
    };
}

pub fn TreeWordReader(comptime Config: type) type {
    requireConfig(Config);

    return struct {
        const Self = @This();

        pub const Error = error{ MissingWord, DataTruncated };

        index: *const Config.Index,
        table: []align(1) const Config.Word,

        pub fn init(bytes: []const u8, index: *const Config.Index) Self {
            const usable = bytes.len / Config.word_bytes * Config.word_bytes;
            return .{
                .index = index,
                .table = std.mem.bytesAsSlice(Config.Word, bytes[0..usable]),
            };
        }

        pub fn get(self: *const Self, hash: Config.Hash) Error!Config.Word {
            const slot = self.index.indexOf(hash) orelse return error.MissingWord;
            if (slot >= self.table.len) return error.DataTruncated;
            return self.table[slot];
        }

        pub fn getAll(
            self: *const Self,
            gpa: std.mem.Allocator,
            hashes: []const Config.Hash,
        ) (Error || std.mem.Allocator.Error)![]Config.Word {
            const words = try gpa.alloc(Config.Word, hashes.len);
            errdefer gpa.free(words);

            for (hashes, words) |hash, *word| word.* = try self.get(hash);
            return words;
        }
    };
}

pub fn TreeContentWriter(comptime Config: type) type {
    requireConfig(Config);
    const Words = TreeWords(Config);
    const WordWriter = TreeWordWriter(Config);

    return struct {
        const Self = @This();

        words: WordWriter,

        pub fn init(writer: *std.Io.Writer, index: *Config.Index) Self {
            return .{ .words = WordWriter.init(writer, index) };
        }

        pub fn put(self: *Self, gpa: std.mem.Allocator, leaves: []const Config.Word) !Config.Root {
            if (leaves.len == 0) return .empty;

            var level = try self.words.putAll(gpa, leaves);
            defer gpa.free(level);

            var depth: usize = 0;
            while (level.len > 1) : (depth += 1) {
                const parents = try Words.fromHashes(gpa, level);
                defer gpa.free(parents);

                const next = try self.words.putAll(gpa, parents);
                gpa.free(level);
                level = next;
            }

            return .{ .hash = level[0], .depth = depth };
        }
    };
}

pub fn TreeContentReader(comptime Config: type) type {
    requireConfig(Config);
    const Words = TreeWords(Config);
    const WordReader = TreeWordReader(Config);

    return struct {
        const Self = @This();

        words: WordReader,

        pub fn init(bytes: []const u8, index: *const Config.Index) Self {
            return .{ .words = WordReader.init(bytes, index) };
        }

        pub fn get(self: *const Self, gpa: std.mem.Allocator, root: Config.Root) ![]Config.Word {
            if (root.isEmpty()) return gpa.alloc(Config.Word, 0);

            var level = try self.words.getAll(gpa, &.{root.hash});
            errdefer gpa.free(level);

            for (0..root.depth) |_| {
                const next = try self.words.getAll(gpa, Words.hashesOf(level));
                gpa.free(level);
                level = next;
            }

            return level;
        }
    };
}

pub fn TreeIndexFormat(comptime Config: type) type {
    requireConfig(Config);

    return struct {
        pub const count_bytes: u64 = @sizeOf(u64);
        pub const trailer_bytes: u64 = Config.hash_bytes + 2 * @sizeOf(u64);
        pub const fixed_bytes: u64 = count_bytes + trailer_bytes;

        pub fn hashesBytes(hash_count: u64) ?u64 {
            return std.math.mul(u64, hash_count, Config.hash_bytes) catch null;
        }

        pub fn writeRecord(
            writer: *std.Io.Writer,
            hashes: []const Config.Hash,
            metadata: Config.Metadata,
        ) std.Io.Writer.Error!void {
            try writer.writeInt(u64, hashes.len, .little);
            for (hashes) |hash| try writer.writeInt(Config.Hash, hash, .little);
            try writer.writeInt(Config.Hash, metadata.root.hash, .little);
            try writer.writeInt(u64, metadata.root.depth, .little);
            try writer.writeInt(u64, metadata.byte_len, .little);
        }

        pub fn readCount(reader: *std.Io.Reader) !u64 {
            return reader.takeInt(u64, .little);
        }

        pub fn readTrailer(reader: *std.Io.Reader) !Config.Metadata {
            const hash = try reader.takeInt(Config.Hash, .little);
            const depth = try reader.takeInt(u64, .little);
            const byte_len = try reader.takeInt(u64, .little);

            return .{
                .root = .{
                    .hash = hash,
                    .depth = std.math.cast(usize, depth) orelse return error.InvalidIndex,
                },
                .byte_len = byte_len,
            };
        }

        pub fn parse(
            gpa: std.mem.Allocator,
            bytes: []const u8,
            index: *Config.Index,
            catalog: *std.ArrayList(Config.Metadata),
        ) !void {
            var reader: std.Io.Reader = .fixed(bytes);

            while (reader.seek < bytes.len) {
                var remaining = try readCount(&reader);
                while (remaining > 0) : (remaining -= 1) {
                    const hash = try reader.takeInt(Config.Hash, .little);
                    if (hash == 0) return error.InvalidIndex;
                    if (!try index.insert(gpa, hash)) return error.InvalidIndex;
                }

                const metadata = try readTrailer(&reader);
                if (!metadata.root.isEmpty() and !index.contains(metadata.root.hash))
                    return error.InvalidIndex;

                try catalog.append(gpa, metadata);
            }
        }
    };
}

pub fn TreeIndexFile(comptime Config: type) type {
    requireConfig(Config);
    const Format = TreeIndexFormat(Config);

    return struct {
        pub fn load(
            gpa: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            index: *Config.Index,
            catalog: *std.ArrayList(Config.Metadata),
        ) !u64 {
            var buffer: [4096]u8 = undefined;
            var file_reader = file.reader(io, &buffer);
            const bytes = try file_reader.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(bytes);

            try Format.parse(gpa, bytes, index, catalog);
            return bytes.len;
        }

        pub fn scan(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]Config.Metadata {
            var catalog: std.ArrayList(Config.Metadata) = .empty;
            errdefer catalog.deinit(gpa);

            const size = (try file.stat(io)).size;

            var buffer: [128]u8 = undefined;
            var file_reader = file.reader(io, &buffer);
            const reader = &file_reader.interface;

            var position: u64 = 0;
            while (position < size) {
                const hash_count = try Format.readCount(reader);
                const skip = Format.hashesBytes(hash_count) orelse return error.InvalidIndex;
                const record_len = std.math.add(u64, Format.fixed_bytes, skip) catch
                    return error.InvalidIndex;
                if (record_len > size - position) return error.InvalidIndex;

                try file_reader.seekBy(std.math.cast(i64, skip) orelse return error.InvalidIndex);
                try catalog.append(gpa, try Format.readTrailer(reader));

                position += record_len;
            }

            return catalog.toOwnedSlice(gpa);
        }

        pub fn append(
            io: std.Io,
            file: std.Io.File,
            offset: u64,
            hashes: []const Config.Hash,
            metadata: Config.Metadata,
        ) !u64 {
            var buffer: [4096]u8 = undefined;
            var file_writer = file.writer(io, &buffer);
            try file_writer.seekTo(offset);

            try Format.writeRecord(&file_writer.interface, hashes, metadata);
            try file_writer.interface.flush();

            return file_writer.logicalPos();
        }
    };
}

pub fn TreeFileWriter(comptime Config: type) type {
    requireConfig(Config);
    const Words = TreeWords(Config);
    const IndexFile = TreeIndexFile(Config);
    const ContentWriter = TreeContentWriter(Config);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        index_file: std.Io.File,
        data_file: std.Io.File,
        index: Config.Index,
        catalog: std.ArrayList(Config.Metadata),
        index_end: u64,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            index_file: std.Io.File,
            data_file: std.Io.File,
        ) !Self {
            var index: Config.Index = .{};
            errdefer index.deinit(allocator);

            var catalog: std.ArrayList(Config.Metadata) = .empty;
            errdefer catalog.deinit(allocator);

            const index_end = try IndexFile.load(allocator, io, index_file, &index, &catalog);

            const data_size = (try data_file.stat(io)).size;
            if (data_size != Config.dataBytes(index.count())) return error.DataSizeMismatch;

            return .{
                .allocator = allocator,
                .io = io,
                .index_file = index_file,
                .data_file = data_file,
                .index = index,
                .catalog = catalog,
                .index_end = index_end,
            };
        }

        pub fn deinit(self: *Self) void {
            self.index.deinit(self.allocator);
            self.catalog.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn metadata(self: *const Self, id: ContentId) ?Config.Metadata {
            if (id.index() >= self.catalog.items.len) return null;
            return self.catalog.items[id.index()];
        }

        fn writeContent(self: *Self, words: []const Config.Word) !Config.Root {
            var buffer: [8192]u8 = undefined;
            var writer = self.data_file.writer(self.io, &buffer);
            try writer.seekTo(Config.dataBytes(self.index.count()));

            var content = ContentWriter.init(&writer.interface, &self.index);
            const root = try content.put(self.allocator, words);
            try writer.interface.flush();
            return root;
        }

        pub fn put(self: *Self, bytes: []const u8) !ContentId {
            const words = try Words.fromBytes(self.allocator, bytes);
            defer self.allocator.free(words);

            try self.catalog.ensureUnusedCapacity(self.allocator, 1);

            const checkpoint = self.index.count();
            errdefer self.index.truncate(checkpoint);

            const record: Config.Metadata = .{
                .root = try self.writeContent(words),
                .byte_len = bytes.len,
            };
            self.index_end = try IndexFile.append(
                self.io,
                self.index_file,
                self.index_end,
                self.index.since(checkpoint),
                record,
            );

            self.catalog.appendAssumeCapacity(record);
            return ContentId.fromIndex(self.catalog.items.len - 1);
        }
    };
}

pub fn TreeFileReader(comptime Config: type) type {
    requireConfig(Config);
    const IndexFile = TreeIndexFile(Config);
    const ContentReader = TreeContentReader(Config);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        index: Config.Index,
        catalog: std.ArrayList(Config.Metadata),
        data_map: ?std.Io.File.MemoryMap,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            index_file: std.Io.File,
            data_file: std.Io.File,
        ) !Self {
            var index: Config.Index = .{};
            errdefer index.deinit(allocator);

            var catalog: std.ArrayList(Config.Metadata) = .empty;
            errdefer catalog.deinit(allocator);

            _ = try IndexFile.load(allocator, io, index_file, &index, &catalog);

            const size = (try data_file.stat(io)).size;
            if (size != Config.dataBytes(index.count())) return error.DataSizeMismatch;

            const data_map: ?std.Io.File.MemoryMap = if (size == 0) null else try .create(io, data_file, .{
                .len = std.math.cast(usize, size) orelse return error.DataTooLarge,
                .protection = .{ .read = true },
            });

            return .{
                .allocator = allocator,
                .io = io,
                .index = index,
                .catalog = catalog,
                .data_map = data_map,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.data_map) |*map| map.destroy(self.io);
            self.index.deinit(self.allocator);
            self.catalog.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.catalog.items.len;
        }

        pub fn metadata(self: *const Self, id: ContentId) ?Config.Metadata {
            if (id.index() >= self.catalog.items.len) return null;
            return self.catalog.items[id.index()];
        }

        pub fn get(self: *const Self, gpa: std.mem.Allocator, id: ContentId) ![]u8 {
            const record = self.metadata(id) orelse return error.UnknownContentId;
            const len = std.math.cast(usize, record.byte_len) orelse return error.InvalidIndex;

            const data: []const u8 = if (self.data_map) |map| map.memory else &.{};
            const content: ContentReader = .init(data, &self.index);

            const words = try content.get(gpa, record.root);
            defer gpa.free(words);

            const padded = std.mem.sliceAsBytes(words);
            if (len > padded.len) return error.InvalidIndex;

            return gpa.dupe(u8, padded[0..len]);
        }
    };
}

test "hashes round trip through words" {
    const Config = TreeConfig(u32, 4);
    const Words = TreeWords(Config);
    const gpa = std.testing.allocator;
    const hashes = [_]u32{ 1, 2, 3, 4, 5 };

    const words = try Words.fromHashes(gpa, &hashes);
    defer gpa.free(words);

    try std.testing.expectEqual(2, words.len);
    try std.testing.expectEqualSlices(u32, &hashes, Words.hashesOf(words));
}

test "word hash never yields the reserved zero hash" {
    const Config = TreeConfig(u32, 2);
    try std.testing.expect(TreeWords(Config).hash(0) != 0);
}

test "hash index truncate rolls back insertions" {
    const gpa = std.testing.allocator;
    var index: HashIndex(u32) = .{};
    defer index.deinit(gpa);

    try std.testing.expect(try index.insert(gpa, 7));
    try std.testing.expect(try index.insert(gpa, 9));
    try std.testing.expect(!try index.insert(gpa, 9));

    index.truncate(1);
    try std.testing.expect(!index.contains(9));
    try std.testing.expectEqualSlices(u32, &.{7}, index.hashes());
}

test "index record round trips through the format" {
    const Config = TreeConfig(u32, 2);
    const Format = TreeIndexFormat(Config);
    const gpa = std.testing.allocator;

    const hashes = [_]u32{ 5, 6, 7 };
    const metadata: Config.Metadata = .{
        .root = .{ .hash = 7, .depth = 2 },
        .byte_len = 42,
    };

    var storage: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&storage);
    try Format.writeRecord(&sink, &hashes, metadata);

    var index: Config.Index = .{};
    defer index.deinit(gpa);
    var catalog: std.ArrayList(Config.Metadata) = .empty;
    defer catalog.deinit(gpa);

    try Format.parse(gpa, sink.buffered(), &index, &catalog);

    try std.testing.expectEqualSlices(u32, &hashes, index.hashes());
    try std.testing.expectEqual(1, catalog.items.len);
    try std.testing.expectEqual(metadata, catalog.items[0]);
}

test "format rejects duplicate hashes" {
    const Config = TreeConfig(u32, 2);
    const Format = TreeIndexFormat(Config);
    const gpa = std.testing.allocator;

    const metadata: Config.Metadata = .{ .root = .empty, .byte_len = 0 };

    var storage: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&storage);
    try Format.writeRecord(&sink, &.{ 5, 5 }, metadata);

    var index: Config.Index = .{};
    defer index.deinit(gpa);
    var catalog: std.ArrayList(Config.Metadata) = .empty;
    defer catalog.deinit(gpa);

    try std.testing.expectError(
        error.InvalidIndex,
        Format.parse(gpa, sink.buffered(), &index, &catalog),
    );
}

test "content tree round trips through writer and reader" {
    const Config = TreeConfig(u32, 4);
    const Words = TreeWords(Config);
    const gpa = std.testing.allocator;

    const source = "the quick brown fox jumps over the lazy dog, repeatedly and at length";
    const leaves = try Words.fromBytes(gpa, source);
    defer gpa.free(leaves);

    var index: Config.Index = .{};
    defer index.deinit(gpa);

    var storage: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&storage);

    var content_writer: TreeContentWriter(Config) = .init(&sink, &index);
    const root = try content_writer.put(gpa, leaves);

    const content_reader: TreeContentReader(Config) = .init(sink.buffered(), &index);
    const restored = try content_reader.get(gpa, root);
    defer gpa.free(restored);

    try std.testing.expectEqualSlices(u8, source, std.mem.sliceAsBytes(restored)[0..source.len]);
}
