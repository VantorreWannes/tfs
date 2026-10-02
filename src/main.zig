const std = @import("std");
const builtin = @import("builtin");
const tfs = @import("root.zig");
const projfs = @import("projfs.zig");

const Store = tfs.SpanStore(u32);
const FileContent = tfs.BuildResult(u32);
const io_buffer_size = 128 * 1024;

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn readInt(reader: *std.Io.Reader, comptime T: type) !T {
    var bytes: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    try reader.readSliceAll(&bytes);
    return std.mem.readInt(T, &bytes, .little);
}

fn skipBytes(reader: *std.Io.Reader, count: u64) !void {
    var remaining = count;
    var discarded: [64 * 1024]u8 = undefined;

    while (remaining != 0) {
        const amount: usize = @intCast(@min(remaining, discarded.len));
        const read = try reader.readSliceShort(discarded[0..amount]);

        if (read == 0) return error.UnexpectedEof;
        remaining -= read;
    }
}

const Names = struct {
    const max_utf16_units = 32767;

    extern "kernel32" fn CompareStringOrdinal(
        left: [*]const u16,
        left_len: i32,
        right: [*]const u16,
        right_len: i32,
        ignore_case: i32,
    ) callconv(.winapi) i32;

    fn equal(left: []const u8, right: []const u8) bool {
        if (std.mem.eql(u8, left, right)) return true;

        if (builtin.os.tag == .windows) {
            var left_buffer: [max_utf16_units]u16 = undefined;
            var right_buffer: [max_utf16_units]u16 = undefined;

            const left_len = std.unicode.utf8ToUtf16Le(
                &left_buffer,
                left,
            ) catch return false;

            const right_len = std.unicode.utf8ToUtf16Le(
                &right_buffer,
                right,
            ) catch return false;

            return CompareStringOrdinal(
                &left_buffer,
                @intCast(left_len),
                &right_buffer,
                @intCast(right_len),
                1,
            ) == 2;
        }

        return false;
    }

    fn relative(path: []const u8, directory: []const u8) ?[]const u8 {
        if (equal(path, directory)) return "";

        for (path, 0..) |byte, index| {
            if (byte == '/' and equal(path[0..index], directory)) {
                return path[index + 1 ..];
            }
        }

        return null;
    }

    fn conflicts(left: []const u8, right: []const u8) bool {
        return relative(left, right) != null or
            relative(right, left) != null;
    }

    fn validate(path: []const u8) !void {
        if (path.len == 0 or path.len > std.math.maxInt(u16)) {
            return error.InvalidEntryPath;
        }

        if (!std.unicode.utf8ValidateSlice(path)) {
            return error.InvalidEntryPath;
        }

        var utf16: [max_utf16_units]u16 = undefined;
        _ = std.unicode.utf8ToUtf16Le(&utf16, path) catch {
            return error.InvalidEntryPath;
        };

        var components = std.mem.splitScalar(u8, path, '/');

        while (components.next()) |component| {
            if (component.len == 0 or
                std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, "..") or
                component[component.len - 1] == '.' or
                component[component.len - 1] == ' ')
            {
                return error.InvalidEntryPath;
            }

            for (component) |byte| {
                if (byte < 32 or
                    std.mem.indexOfScalar(u8, "\\:*?\"<>|", byte) != null)
                {
                    return error.InvalidEntryPath;
                }
            }

            const stem_end = std.mem.indexOfScalar(
                u8,
                component,
                '.',
            ) orelse component.len;

            const stem = component[0..stem_end];

            inline for (.{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
                if (std.ascii.eqlIgnoreCase(stem, reserved)) {
                    return error.InvalidEntryPath;
                }
            }

            if (stem.len == 4 and stem[3] >= '1' and stem[3] <= '9') {
                if (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or
                    std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))
                {
                    return error.InvalidEntryPath;
                }
            }
        }
    }
};
pub const Archive = struct {
    const magic = "TFS5";
    const footer_size = magic.len + @sizeOf(u64);

    const Frame = struct {
        ref: u32,
        skip: u64,
    };

    pub const Entry = struct {
        path: []const u8,
        content: FileContent,
        timestamp: i96,
    };

    store: Store,
    io: std.Io,
    seed: u64 = 0x5EED_0000,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    file_path: ?[]u8 = null,
    file: ?std.Io.File = null,
    read_buffer: ?[]u8 = null,
    read_reader: ?std.Io.File.Reader = null,

    base_offsets: std.ArrayListUnmanaged(u64) = .empty,
    base_pairs: std.ArrayListUnmanaged([2]u32) = .empty,
    sizes: std.ArrayListUnmanaged(u64) = .empty,
    payload_len: u64 = 0,
    dirty: bool = false,
    stack: std.ArrayListUnmanaged(u32) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Archive {
        return .{
            .store = Store.init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *Archive) void {
        const allocator = self.store.allocator;

        self.resetFile();

        for (self.entries.items) |entry| allocator.free(entry.path);
        self.entries.deinit(allocator);
        self.base_offsets.deinit(allocator);
        self.base_pairs.deinit(allocator);
        self.sizes.deinit(allocator);
        self.stack.deinit(allocator);
        self.frames.deinit(allocator);

        if (self.file_path) |path| allocator.free(path);
        self.store.deinit();
    }

    fn indexOf(self: *const Archive, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (Names.equal(entry.path, path)) return index;
        }

        return null;
    }

    pub fn find(self: *const Archive, path: []const u8) ?FileContent {
        const index = self.indexOf(path) orelse return null;
        return self.entries.items[index].content;
    }

    pub fn entryAt(self: *const Archive, index: usize) ?projfs.Entry {
        if (index >= self.entries.items.len) return null;

        const entry = self.entries.items[index];

        return .{
            .path = entry.path,
            .content = entry.content,
        };
    }

    fn putAt(
        self: *Archive,
        path: []const u8,
        value: FileContent,
        timestamp: i96,
    ) !void {
        try Names.validate(path);

        const existing = self.indexOf(path);

        for (self.entries.items, 0..) |entry, index| {
            if (existing != null and index == existing.?) continue;
            if (Names.conflicts(entry.path, path)) {
                return error.NamespaceConflict;
            }
        }

        const allocator = self.store.allocator;

        if (existing) |index| {
            self.entries.items[index].content = value;
            self.entries.items[index].timestamp = timestamp;
            self.dirty = true;
            return;
        }

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        try self.entries.append(allocator, .{
            .path = owned_path,
            .content = value,
            .timestamp = timestamp,
        });

        self.dirty = true;
    }

    pub fn put(
        self: *Archive,
        path: []const u8,
        value: FileContent,
    ) !void {
        const timestamp = std.Io.Clock.now(.real, self.io).nanoseconds;
        try self.putAt(path, value, timestamp);
    }

    pub fn remove(
        self: *Archive,
        path: []const u8,
        is_directory: bool,
    ) !void {
        try Names.validate(path);

        var index = self.entries.items.len;
        var removed = false;

        while (index != 0) {
            index -= 1;
            const entry = self.entries.items[index];

            const matches = if (is_directory)
                Names.relative(entry.path, path) != null
            else
                Names.equal(entry.path, path);

            if (matches) {
                self.store.allocator.free(entry.path);
                _ = self.entries.swapRemove(index);
                removed = true;
            }
        }

        if (removed) self.dirty = true;
    }

    pub fn rename(
        self: *Archive,
        from: []const u8,
        to: []const u8,
        is_directory: bool,
    ) !void {
        try Names.validate(from);
        try Names.validate(to);

        if (is_directory and
            !Names.equal(from, to) and
            Names.relative(to, from) != null)
        {
            return error.NamespaceConflict;
        }

        const Change = struct {
            index: usize,
            path: []u8,
        };

        const allocator = self.store.allocator;
        var changes: std.ArrayListUnmanaged(Change) = .empty;

        defer {
            for (changes.items) |change| allocator.free(change.path);
            changes.deinit(allocator);
        }

        for (self.entries.items, 0..) |entry, index| {
            const suffix = if (is_directory)
                Names.relative(entry.path, from) orelse continue
            else if (Names.equal(entry.path, from))
                ""
            else
                continue;

            const replacement = if (suffix.len == 0)
                try allocator.dupe(u8, to)
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{s}/{s}",
                    .{ to, suffix },
                );
            errdefer allocator.free(replacement);

            try Names.validate(replacement);
            try changes.append(allocator, .{
                .index = index,
                .path = replacement,
            });
        }

        if (changes.items.len == 0) {
            if (is_directory) return;
            return error.FileNotFound;
        }

        var replaced_file: ?usize = null;

        if (!is_directory) {
            if (self.indexOf(to)) |index| {
                if (index != changes.items[0].index) {
                    replaced_file = index;
                }
            }
        }

        for (changes.items, 0..) |change, change_index| {
            for (changes.items[0..change_index]) |previous| {
                if (Names.conflicts(change.path, previous.path)) {
                    return error.NamespaceConflict;
                }
            }

            for (self.entries.items, 0..) |entry, index| {
                if (replaced_file != null and index == replaced_file.?) {
                    continue;
                }

                var moving = false;
                for (changes.items) |other| {
                    if (other.index == index) {
                        moving = true;
                        break;
                    }
                }

                if (!moving and Names.conflicts(change.path, entry.path)) {
                    return error.NamespaceConflict;
                }
            }
        }

        for (changes.items) |change| {
            const entry = &self.entries.items[change.index];
            allocator.free(entry.path);
            entry.path = change.path;
        }

        changes.clearRetainingCapacity();

        if (replaced_file) |index| {
            allocator.free(self.entries.items[index].path);
            _ = self.entries.swapRemove(index);
        }

        self.dirty = true;
    }

    fn ensureOpen(self: *Archive) !void {
        if (self.file != null) return;

        const path = self.file_path orelse {
            return error.ArchiveFileUnavailable;
        };

        self.file = try std.Io.Dir.cwd().openFile(
            self.io,
            path,
            .{ .mode = .read_only, .lock = .none },
        );
    }

    fn resetFile(self: *Archive) void {
        self.read_reader = null;

        if (self.read_buffer) |buffer| {
            self.store.allocator.free(buffer);
            self.read_buffer = null;
        }

        if (self.file) |file| {
            file.close(self.io);
            self.file = null;
        }
    }

    fn pread(self: *Archive, offset: u64, out: []u8) !void {
        try self.ensureOpen();
        const file = self.file.?;

        if (self.read_reader == null) {
            const buffer = try self.store.allocator.alloc(
                u8,
                io_buffer_size,
            );

            self.read_buffer = buffer;
            self.read_reader = file.reader(self.io, buffer);
        }

        const reader = &self.read_reader.?;

        try reader.seekTo(offset);
        try reader.interface.readSliceAll(out);
    }

    fn refSize(
        id: u32,
        leaf_count: u32,
        pairs_so_far: usize,
        sizes: []const u64,
    ) !u64 {
        if (!Store.isPair(id)) {
            if (id >= leaf_count) return error.InvalidArchiveFormat;
            return sizes[id];
        }

        const index: usize = Store.pairIndex(id);

        if (index >= pairs_so_far) return error.InvalidArchiveFormat;
        return sizes[leaf_count + index];
    }

    fn nodeSize(self: *const Archive, id: u32) !u64 {
        return refSize(
            id,
            @intCast(self.base_offsets.items.len),
            self.base_pairs.items.len,
            self.sizes.items,
        );
    }

    pub fn readRange(
        self: *Archive,
        root: u32,
        offset: u64,
        buffer: []u8,
    ) !usize {
        if (buffer.len == 0) return 0;

        if (self.store.offsets.items.len != 0) {
            return self.readResidentRange(root, offset, buffer);
        }

        return self.readFileRange(root, offset, buffer);
    }

    fn readResidentRange(
        self: *Archive,
        root: u32,
        offset: u64,
        out: []u8,
    ) !usize {
        const allocator = self.store.allocator;
        var written: usize = 0;
        var skip = offset;

        self.stack.clearRetainingCapacity();
        try self.stack.append(allocator, root);

        while (self.stack.pop()) |id| {
            if (Store.isPair(id)) {
                const pair = self.store.readPair(id);

                try self.stack.append(allocator, pair[1]);
                try self.stack.append(allocator, pair[0]);
                continue;
            }

            const bytes = self.store.readBytes(id);

            if (skip >= bytes.len) {
                skip -= bytes.len;
                continue;
            }

            const chunk = bytes[skip..];
            skip = 0;

            const n = @min(out.len - written, chunk.len);

            @memcpy(out[written..][0..n], chunk[0..n]);
            written += n;

            if (written == out.len) {
                self.stack.clearRetainingCapacity();
                break;
            }
        }

        return written;
    }

    fn readFileRange(
        self: *Archive,
        root: u32,
        offset: u64,
        out: []u8,
    ) !usize {
        const allocator = self.store.allocator;
        var written: usize = 0;

        self.frames.clearRetainingCapacity();
        try self.frames.append(allocator, .{ .ref = root, .skip = offset });

        while (self.frames.pop()) |frame| {
            const size = try self.nodeSize(frame.ref);

            if (frame.skip >= size) continue;

            if (Store.isPair(frame.ref)) {
                const children =
                    self.base_pairs.items[Store.pairIndex(frame.ref)];
                const left_size = try self.nodeSize(children[0]);

                if (frame.skip >= left_size) {
                    try self.frames.append(allocator, .{
                        .ref = children[1],
                        .skip = frame.skip - left_size,
                    });
                } else {
                    try self.frames.append(allocator, .{
                        .ref = children[1],
                        .skip = 0,
                    });
                    try self.frames.append(allocator, .{
                        .ref = children[0],
                        .skip = frame.skip,
                    });
                }

                continue;
            }

            const absolute = self.base_offsets.items[frame.ref] + frame.skip;
            const take: usize = @intCast(@min(
                size - frame.skip,
                @as(u64, out.len - written),
            ));

            try self.pread(absolute, out[written..][0..take]);
            written += take;

            if (written == out.len) {
                self.frames.clearRetainingCapacity();
                break;
            }
        }

        return written;
    }

    pub fn prepareWrite(self: *Archive) !void {
        if (self.store.offsets.items.len != 0) return;
        if (self.base_offsets.items.len == 0 and
            self.base_pairs.items.len == 0)
        {
            return;
        }

        const allocator = self.store.allocator;

        try self.store.bytes.resize(allocator, @intCast(self.payload_len));
        try self.ensureOpen();

        var buffer: [io_buffer_size]u8 = undefined;
        var reader = self.file.?.reader(self.io, &buffer);

        try reader.seekTo(0);
        try reader.interface.readSliceAll(self.store.bytes.items);

        try self.store.offsets.appendSlice(allocator, self.base_offsets.items);
        try self.store.pairs.appendSlice(allocator, self.base_pairs.items);
        try self.store.reindex();

        self.base_offsets.clearAndFree(allocator);
        self.base_pairs.clearAndFree(allocator);
        self.sizes.clearAndFree(allocator);
    }

    pub fn writeFile(self: *Archive, path: []const u8, bytes: []const u8) !void {
        try self.prepareWrite();

        var indexer = tfs.BufferIndexer(u32, u32).init(
            &self.store,
            self.seed,
        );
        defer indexer.deinit();

        try indexer.append(bytes);
        try self.put(path, try indexer.finish());
    }

    fn trailerSize(
        self: *const Archive,
        offsets_len: usize,
        pairs_len: usize,
    ) u64 {
        var size: u64 = 4 + 8 + 8 + 8 + 4 + 4 + 4;

        size += @as(u64, offsets_len) * 8;
        size += @as(u64, pairs_len) * 8;

        for (self.entries.items) |entry| {
            size += 2 + @as(u64, entry.path.len) + 1 + 8 +
                @divExact(@bitSizeOf(i96), 8);

            if (entry.content.root != null) size += 4;
        }

        return size;
    }

    fn writeTrailer(
        self: *const Archive,
        writer: *std.Io.Writer,
        offsets: []const u64,
        pairs: []const [2]u32,
        payload_len: u64,
    ) !u64 {
        const trailer_size = self.trailerSize(offsets.len, pairs.len);
        const leaf_count: u32 = @intCast(offsets.len);
        const pair_count: u32 = @intCast(pairs.len);

        try writer.writeAll(magic);
        try writeInt(writer, u64, self.seed);
        try writeInt(writer, u64, tfs.target_span);
        try writeInt(writer, u64, payload_len);
        try writeInt(writer, u32, leaf_count);
        try writeInt(writer, u32, pair_count);
        try writeInt(writer, u32, @intCast(self.entries.items.len));

        for (offsets) |offset| {
            try writeInt(writer, u64, offset);
        }

        for (pairs) |pair| {
            try writeInt(writer, u32, pair[0]);
            try writeInt(writer, u32, pair[1]);
        }

        for (self.entries.items) |entry| {
            try writeInt(writer, u16, @intCast(entry.path.len));
            try writer.writeAll(entry.path);

            if (entry.content.root) |root| {
                try writeInt(writer, u8, 1);
                try writeInt(writer, u32, root);
            } else {
                try writeInt(writer, u8, 0);
            }

            try writeInt(writer, u64, entry.content.byte_count);
            try writeInt(writer, i96, entry.timestamp);
        }

        return trailer_size;
    }

    pub fn writeImage(self: *const Archive, writer: *std.Io.Writer) !void {
        const payload_len: u64 = self.store.bytes.items.len;

        try writer.writeAll(self.store.bytes.items);

        const trailer_size = try self.writeTrailer(
            writer,
            self.store.offsets.items,
            self.store.pairs.items,
            payload_len,
        );

        try writeInt(writer, u64, trailer_size);
        try writer.writeAll(magic);
    }

    pub fn parseTrailer(self: *Archive, bytes: []const u8) !void {
        var reader = std.Io.Reader.fixed(bytes);
        const allocator = self.store.allocator;

        var signature: [magic.len]u8 = undefined;
        try reader.readSliceAll(&signature);

        if (!std.mem.eql(u8, &signature, magic)) {
            return error.InvalidArchiveFormat;
        }

        self.seed = try readInt(&reader, u64);

        if (try readInt(&reader, u64) != tfs.target_span) {
            return error.UnsupportedChunkPolicy;
        }

        self.payload_len = try readInt(&reader, u64);

        const leaf_count = try readInt(&reader, u32);
        const pair_count = try readInt(&reader, u32);
        const entry_count = try readInt(&reader, u32);

        try self.base_offsets.ensureTotalCapacity(allocator, leaf_count);

        var previous: u64 = 0;

        for (0..leaf_count) |_| {
            const start = try readInt(&reader, u64);

            if (start < previous or start > self.payload_len) {
                return error.InvalidArchiveFormat;
            }

            previous = start;
            try self.base_offsets.append(allocator, start);
        }

        try self.sizes.ensureTotalCapacity(allocator, leaf_count + pair_count);

        for (0..leaf_count) |i| {
            const start = self.base_offsets.items[i];
            const end = if (i + 1 < leaf_count)
                self.base_offsets.items[i + 1]
            else
                self.payload_len;

            if (end < start) return error.InvalidArchiveFormat;
            try self.sizes.append(allocator, end - start);
        }

        try self.base_pairs.ensureTotalCapacity(allocator, pair_count);

        for (0..pair_count) |p| {
            const left = try readInt(&reader, u32);
            const right = try readInt(&reader, u32);

            const left_size = try refSize(left, leaf_count, p, self.sizes.items);
            const right_size = try refSize(right, leaf_count, p, self.sizes.items);

            const size = std.math.add(u64, left_size, right_size) catch {
                return error.InvalidArchiveFormat;
            };

            try self.sizes.append(allocator, size);
            try self.base_pairs.append(allocator, .{ left, right });
        }

        try self.entries.ensureTotalCapacity(allocator, entry_count);

        for (0..entry_count) |_| {
            const path_len = try readInt(&reader, u16);

            {
                const path = try allocator.alloc(u8, path_len);
                errdefer allocator.free(path);

                try reader.readSliceAll(path);

                const present = try readInt(&reader, u8);
                if (present > 1) return error.InvalidArchiveFormat;

                var value: FileContent = .{ .root = null, .byte_count = 0 };

                if (present == 1) {
                    const root = try readInt(&reader, u32);
                    const size = try refSize(
                        root,
                        leaf_count,
                        pair_count,
                        self.sizes.items,
                    );

                    if (try readInt(&reader, u64) != size) {
                        return error.InvalidArchiveFormat;
                    }

                    value = .{ .root = root, .byte_count = size };
                } else {
                    if (try readInt(&reader, u64) != 0) {
                        return error.InvalidArchiveFormat;
                    }
                }

                const timestamp = try readInt(&reader, i96);

                try Names.validate(path);
                if (self.find(path) != null) return error.InvalidArchiveFormat;

                try self.entries.append(allocator, .{
                    .path = path,
                    .content = value,
                    .timestamp = timestamp,
                });
            }
        }

        var extra: [1]u8 = undefined;
        if (try reader.readSliceShort(&extra) != 0) {
            return error.InvalidArchiveFormat;
        }
    }

    fn loadFromFile(self: *Archive, file: std.Io.File) !void {
        const stat = try file.stat(self.io);
        const length = stat.size;

        if (length < footer_size) return error.InvalidArchiveFormat;

        var buffer: [io_buffer_size]u8 = undefined;
        var reader = file.reader(self.io, &buffer);

        var footer: [footer_size]u8 = undefined;

        try reader.seekTo(length - footer_size);
        try reader.interface.readSliceAll(&footer);

        const trailer_size = std.mem.readInt(
            u64,
            footer[0..@sizeOf(u64)],
            .little,
        );

        if (!std.mem.eql(u8, footer[@sizeOf(u64)..], magic)) {
            return error.InvalidArchiveFormat;
        }

        if (trailer_size > length - footer_size) {
            return error.InvalidArchiveFormat;
        }

        const trailer = try self.store.allocator.alloc(u8, trailer_size);
        defer self.store.allocator.free(trailer);

        try reader.seekTo(length - footer_size - trailer_size);
        try reader.interface.readSliceAll(trailer);

        try self.parseTrailer(trailer);
    }
};

pub const Options = union(enum) {
    encode: struct {
        archive: []const u8,
        input: []const u8,
        name: []const u8,
    },

    decode: struct {
        archive: []const u8,
        name: []const u8,
        output: []const u8,
    },

    list: struct {
        archive: []const u8,
    },

    mount: struct {
        archive: []const u8,
        directory: []const u8,
    },

    pub fn archivePath(self: Options) []const u8 {
        return switch (self) {
            inline else => |command| command.archive,
        };
    }

    pub fn parse(args: []const [:0]const u8) !Options {
        var positional: [4][]const u8 = undefined;
        var count: usize = 0;
        var name: ?[]const u8 = null;
        var parse_flags = true;

        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const argument = args[index];

            if (parse_flags and std.mem.eql(u8, argument, "--")) {
                parse_flags = false;
                continue;
            }

            if (parse_flags and
                (std.mem.eql(u8, argument, "--name") or
                    std.mem.eql(u8, argument, "-n")))
            {
                if (name != null) return error.DuplicateOption;
                index += 1;
                if (index == args.len) return error.MissingArgumentValue;
                name = args[index];
                continue;
            }

            if (parse_flags and argument.len > 1 and argument[0] == '-') {
                return error.UnknownOption;
            }

            if (count == positional.len) return error.TooManyArguments;
            positional[count] = argument;
            count += 1;
        }

        if (count < 2) return error.InsufficientArguments;

        const command = positional[0];
        const archive = positional[1];

        if (std.mem.eql(u8, command, "encode")) {
            if (count > 3) return error.TooManyArguments;

            const input = if (count == 3) positional[2] else "-";
            const entry_name = name orelse if (std.mem.eql(u8, input, "-"))
                "stdin"
            else
                std.fs.path.basename(input);

            try Names.validate(entry_name);

            return .{ .encode = .{
                .archive = archive,
                .input = input,
                .name = entry_name,
            } };
        }

        if (std.mem.eql(u8, command, "decode")) {
            if (name) |entry_name| {
                if (count > 3) return error.TooManyArguments;
                try Names.validate(entry_name);

                return .{ .decode = .{
                    .archive = archive,
                    .name = entry_name,
                    .output = if (count == 3) positional[2] else entry_name,
                } };
            }

            if (count < 3) return error.MissingEntryName;
            try Names.validate(positional[2]);

            return .{ .decode = .{
                .archive = archive,
                .name = positional[2],
                .output = if (count == 4) positional[3] else positional[2],
            } };
        }

        if (name != null) return error.UnexpectedOption;

        if (std.mem.eql(u8, command, "list")) {
            if (count != 2) return error.TooManyArguments;
            return .{ .list = .{ .archive = archive } };
        }

        if (std.mem.eql(u8, command, "mount")) {
            if (count < 3) return error.MissingMountDirectory;
            if (count > 3) return error.TooManyArguments;

            return .{ .mount = .{
                .archive = archive,
                .directory = positional[2],
            } };
        }

        return error.InvalidCommand;
    }
};

fn loadArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    allow_missing: bool,
) !Archive {
    var archive = Archive.init(allocator, io);
    errdefer archive.deinit();

    const file = std.Io.Dir.cwd().openFile(
        io,
        path,
        .{ .mode = .read_only, .lock = .none },
    ) catch |err| {
        if (allow_missing and err == error.FileNotFound) return archive;
        return err;
    };

    archive.file = file;
    archive.file_path = try allocator.dupe(u8, path);

    try archive.loadFromFile(file);
    return archive;
}

fn saveArchive(
    io: std.Io,
    archive: *Archive,
    path: []const u8,
) !void {
    if (!archive.dirty) {
        std.debug.print(
            "[save] No changes; '{s}' left untouched.\n",
            .{path},
        );
        return;
    }

    const cwd = std.Io.Dir.cwd();
    const allocator = archive.store.allocator;

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) try cwd.createDirPath(io, parent);
    }

    archive.resetFile();

    var nonce: [16]u8 = undefined;
    io.random(&nonce);

    const temporary = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}.tmp",
        .{ path, std.fmt.bytesToHex(nonce, .lower) },
    );
    defer allocator.free(temporary);

    const file = try cwd.createFile(io, temporary, .{
        .exclusive = true,
        .truncate = true,
        .lock = .none,
    });

    var closed = false;
    defer if (!closed) file.close(io);
    errdefer cwd.deleteFile(io, temporary) catch {};

    var buffer: [io_buffer_size]u8 = undefined;
    var writer = file.writer(io, &buffer);

    if (archive.store.offsets.items.len != 0 or archive.payload_len == 0) {
        try archive.writeImage(&writer.interface);
    } else {
        try archive.ensureOpen();

        var source = archive.file.?.reader(io, &buffer);
        var chunk: [io_buffer_size]u8 = undefined;
        var remaining = archive.payload_len;

        while (remaining != 0) {
            const want: usize = @intCast(@min(remaining, chunk.len));

            try source.interface.readSliceAll(chunk[0..want]);
            try writer.interface.writeAll(chunk[0..want]);

            remaining -= want;
        }

        const trailer_size = try archive.writeTrailer(
            &writer.interface,
            archive.base_offsets.items,
            archive.base_pairs.items,
            archive.payload_len,
        );

        try writeInt(&writer.interface, u64, trailer_size);
        try writer.interface.writeAll(Archive.magic);
    }

    try writer.interface.flush();
    try file.sync(io);

    file.close(io);
    closed = true;

    try cwd.rename(temporary, cwd, path, io);

    archive.dirty = false;
}

fn listArchive(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var archive = try loadArchive(io, allocator, path, false);
    defer archive.deinit();

    std.mem.sort(Archive.Entry, archive.entries.items, {}, pathLessThan);

    var name_width: usize = 0;
    var size_width: usize = 0;

    for (archive.entries.items) |entry| {
        name_width = @max(name_width, entry.path.len);

        var size_buffer: [16]u8 = undefined;
        const size = try formatSize(entry.content.byte_count, &size_buffer);
        size_width = @max(size_width, size.len);
    }

    var buffer: [io_buffer_size]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);

    for (archive.entries.items) |entry| {
        var size_buffer: [16]u8 = undefined;
        const size = try formatSize(entry.content.byte_count, &size_buffer);

        var timestamp_buffer: [64]u8 = undefined;
        const timestamp = try formatTimestamp(
            entry.timestamp,
            &timestamp_buffer,
        );

        try output.interface.print("{s}", .{entry.path});

        var pad = name_width - entry.path.len + 2;
        while (pad != 0) : (pad -= 1) {
            try output.interface.writeAll(" ");
        }

        pad = size_width - size.len;
        while (pad != 0) : (pad -= 1) {
            try output.interface.writeAll(" ");
        }

        try output.interface.print("{s}  {s}\n", .{ size, timestamp });
    }

    var total: u64 = 0;
    for (archive.entries.items) |entry| {
        total += entry.content.byte_count;
    }

    var size_buffer: [16]u8 = undefined;
    const size = try formatSize(total, &size_buffer);

    try output.interface.print(
        "\n{d} entries, {s}\n",
        .{ archive.entries.items.len, size },
    );
    try output.interface.flush();
}

fn formatTimestamp(nanoseconds: i96, buffer: []u8) ![]const u8 {
    const seconds: i64 = @intCast(
        @divFloor(nanoseconds, std.time.ns_per_s),
    );

    const days = @divFloor(seconds, 86400);
    const day_seconds = @mod(seconds, 86400);

    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const year_base = @as(i64, yoe) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = doy - (153 * mp + 2) / 5 + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = if (month <= 2) year_base + 1 else year_base;
    const hours: u32 = @intCast(@divFloor(day_seconds, 3600));
    const minutes: u32 = @intCast(@divFloor(@mod(day_seconds, 3600), 60));
    const seconds_in_minute: u32 = @intCast(@mod(day_seconds, 60));

    return std.fmt.bufPrint(
        buffer,
        "{s}{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{
            if (year < 0) "-" else "",
            @abs(year),
            month,
            day,
            hours,
            minutes,
            seconds_in_minute,
        },
    );
}

fn formatSize(size: u64, buffer: []u8) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };

    var value: f64 = @floatFromInt(size);
    var unit: usize = 0;

    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }

    if (unit == 0) {
        return std.fmt.bufPrint(buffer, "{d} B", .{size});
    }

    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] });
}

fn pathLessThan(_: void, left: Archive.Entry, right: Archive.Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

const WindowsFiles = struct {
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        sharing: u32,
        security: ?*anyopaque,
        disposition: u32,
        flags: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn ReadFile(
        file: *anyopaque,
        buffer: [*]u8,
        length: u32,
        read: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;

    extern "kernel32" fn CloseHandle(
        handle: *anyopaque,
    ) callconv(.winapi) i32;

    fn load(
        allocator: std.mem.Allocator,
        path: [:0]const u16,
    ) ![]u8 {
        if (builtin.os.tag != .windows) {
            return error.UnsupportedPlatform;
        }

        const handle = CreateFileW(
            path.ptr,
            0x80000000,
            0x00000001,
            null,
            3,
            0x08000080,
            null,
        ) orelse return error.FileOpenFailed;

        if (@intFromPtr(handle) == std.math.maxInt(usize)) {
            return error.FileOpenFailed;
        }
        defer _ = CloseHandle(handle);

        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer bytes.deinit(allocator);

        var buffer: [64 * 1024]u8 = undefined;

        while (true) {
            var count: u32 = 0;

            if (ReadFile(
                handle,
                &buffer,
                buffer.len,
                &count,
                null,
            ) == 0) {
                return error.FileReadFailed;
            }

            if (count == 0) break;
            try bytes.appendSlice(allocator, buffer[0..count]);
        }

        return bytes.toOwnedSlice(allocator);
    }
};

fn mountArchive(
    io: std.Io,
    archive: *Archive,
    archive_path: []const u8,
    directory: []const u8,
) !void {
    if (builtin.os.tag != .windows) {
        return error.UnsupportedPlatform;
    }

    const allocator = archive.store.allocator;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDir(
        io,
        directory,
        @enumFromInt(0x00000080),
    );

    var instance_id: projfs.InstanceId = undefined;
    io.random(std.mem.asBytes(&instance_id));

    try projfs.markDirectory(allocator, directory, &instance_id);

    const mounted = try projfs.Mount(Archive).start(
        allocator,
        archive,
        directory,
        WindowsFiles.load,
    );

    var active = true;
    defer if (active) {
        _ = mounted.stop();
    };

    std.debug.print(
        "Mounted '{s}' on '{s}'.\nPress Enter to stop, save, and remove the mount directory.\n",
        .{ archive_path, directory },
    );

    var input_buffer: [128]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &input_buffer);
    var byte: [1]u8 = undefined;

    const wait_result = input.interface.readSliceShort(&byte);

    const notification_error = mounted.stop();
    active = false;

    try saveArchive(io, archive, archive_path);

    const read_error: ?anyerror = if (wait_result) |_| null else |err| err;

    if (read_error == null and notification_error == null) {
        if (cwd.deleteTree(io, directory)) {
            std.debug.print(
                "[unmount] Removed mount directory '{s}'.\n",
                .{directory},
            );
        } else |err| {
            std.debug.print(
                "[warn] Could not remove '{s}' ({s}). A background process (Defender/Explorer) may still hold it; delete it manually once handles release.\n",
                .{ directory, @errorName(err) },
            );
        }
    } else {
        std.debug.print(
            "[unmount] Archive saved; kept '{s}' because the session ended with errors.\n",
            .{directory},
        );
    }

    std.debug.print(
        "[unmount] Complete. {d} entries saved to '{s}'.\n",
        .{ archive.entries.items.len, archive_path },
    );

    if (notification_error) |err| return err;
    if (read_error) |err| return err;
}

pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
) !void {
    if (options == .mount and builtin.os.tag != .windows) {
        return error.UnsupportedPlatform;
    }

    switch (options) {
        .list => |command| {
            return listArchive(io, allocator, command.archive);
        },
        else => {},
    }

    const archive_path = options.archivePath();
    const allow_missing = switch (options) {
        .encode, .mount => true,
        else => false,
    };

    var archive = try loadArchive(
        io,
        allocator,
        archive_path,
        allow_missing,
    );
    defer archive.deinit();

    const cwd = std.Io.Dir.cwd();

    switch (options) {
        .list => unreachable,
        .encode => |command| {
            try archive.prepareWrite();

            const is_stdin = std.mem.eql(u8, command.input, "-");

            const input_file = if (is_stdin)
                std.Io.File.stdin()
            else
                try cwd.openFile(io, command.input, .{
                    .mode = .read_only,
                    .lock = .none,
                });
            defer if (!is_stdin) input_file.close(io);

            var buffer: [io_buffer_size]u8 = undefined;
            var reader = input_file.reader(io, &buffer);

            const result = try tfs.indexReader(
                u32,
                u32,
                &archive.store,
                &reader.interface,
                archive.seed,
            );

            try archive.put(command.name, result);
            try saveArchive(io, &archive, archive_path);
        },

        .decode => |command| {
            const entry = archive.find(command.name) orelse {
                return error.FileNotFound;
            };

            const is_stdout = std.mem.eql(u8, command.output, "-");

            if (!is_stdout) {
                if (std.fs.path.dirname(command.output)) |parent| {
                    if (parent.len != 0) try cwd.createDirPath(io, parent);
                }
            }

            const output_file = if (is_stdout)
                std.Io.File.stdout()
            else
                try cwd.createFile(io, command.output, .{
                    .truncate = true,
                    .lock = .none,
                });
            defer if (!is_stdout) output_file.close(io);

            var buffer: [io_buffer_size]u8 = undefined;
            var writer = output_file.writer(io, &buffer);

            var chunk: [64 * 1024]u8 = undefined;
            var offset: u64 = 0;

            while (offset < entry.byte_count) {
                const want: usize = @intCast(@min(
                    chunk.len,
                    entry.byte_count - offset,
                ));

                const got = try archive.readRange(
                    entry.root.?,
                    offset,
                    chunk[0..want],
                );

                if (got != want) return error.UnexpectedEndOfContent;

                try writer.interface.writeAll(chunk[0..want]);
                offset += want;
            }

            try writer.interface.flush();
        },
        .mount => |command| {
            try mountArchive(
                io,
                &archive,
                archive_path,
                command.directory,
            );
        },
    }
}

pub fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage:
        \\  tfs encode <archive> [input|-] [--name <entry>]
        \\  tfs decode <archive> <entry> [output|-]
        \\  tfs decode <archive> [output|-] --name <entry>
        \\  tfs list   <archive>
        \\  tfs mount  <archive> <new-directory>
        \\
        \\Mount requires Windows ProjFS.
        \\Press Enter to stop a mount, save, and remove the mount directory.
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const options = Options.parse(args) catch |err| {
        try printUsage(init.io);
        return err;
    };

    try execute(init.io, std.heap.smp_allocator, options);
}

test "Names" {
    {
        try Names.validate("directory/file.txt");

        try std.testing.expectError(
            error.InvalidEntryPath,
            Names.validate("../file"),
        );

        try std.testing.expectError(
            error.InvalidEntryPath,
            Names.validate("directory//file"),
        );

        try std.testing.expectError(
            error.InvalidEntryPath,
            Names.validate("CON.txt"),
        );

        try std.testing.expectError(
            error.InvalidEntryPath,
            Names.validate("file:stream"),
        );
    }

    {
        try std.testing.expectEqualSlices(
            u8,
            "child/file",
            Names.relative("parent/child/file", "parent").?,
        );

        try std.testing.expect(
            Names.relative("parental/file", "parent") == null,
        );

        try std.testing.expect(Names.conflicts("a", "a/b"));
        try std.testing.expect(!Names.conflicts("a", "ab"));
    }
}

test "Options" {
    {
        const args = [_][:0]const u8{
            "tfs",
            "encode",
            "archive.tfs",
            "-",
            "--name",
            "input.txt",
        };

        const options = try Options.parse(&args);

        try std.testing.expectEqualStrings(
            "archive.tfs",
            options.archivePath(),
        );
        try std.testing.expectEqualStrings("input.txt", options.encode.name);
        try std.testing.expectEqualStrings("-", options.encode.input);
    }

    {
        const args = [_][:0]const u8{
            "tfs",
            "decode",
            "archive.tfs",
            "input.txt",
            "-",
        };

        const options = try Options.parse(&args);

        try std.testing.expectEqualStrings("input.txt", options.decode.name);
        try std.testing.expectEqualStrings("-", options.decode.output);
    }

    {
        const args = [_][:0]const u8{
            "tfs",
            "list",
            "archive.tfs",
            "unexpected",
        };

        try std.testing.expectError(
            error.TooManyArguments,
            Options.parse(&args),
        );
    }

    {
        const args = [_][:0]const u8{
            "tfs",
            "encode",
            "archive.tfs",
            "--unknown",
        };

        try std.testing.expectError(
            error.UnknownOption,
            Options.parse(&args),
        );
    }
}

test "Archive" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    {
        var archive = Archive.init(allocator, io);
        defer archive.deinit();

        const first = try archive.store.internBytes("first");
        const second = try archive.store.internBytes("second");

        try archive.putAt(
            "file",
            .{ .root = first.id, .byte_count = 5 },
            1,
        );

        try archive.putAt(
            "file",
            .{ .root = second.id, .byte_count = 6 },
            2,
        );

        try std.testing.expectEqual(
            @as(usize, 1),
            archive.entries.items.len,
        );
        try std.testing.expectEqual(
            @as(?u32, second.id),
            archive.find("file").?.root,
        );

        try std.testing.expectError(
            error.NamespaceConflict,
            archive.putAt(
                "file/child",
                .{ .root = null, .byte_count = 0 },
                3,
            ),
        );
    }

    {
        var archive = Archive.init(allocator, io);
        defer archive.deinit();

        const empty: FileContent = .{ .root = null, .byte_count = 0 };

        try archive.putAt("a/one", empty, 1);
        try archive.putAt("a/two", empty, 2);
        try archive.putAt("keep", empty, 3);

        try archive.rename("a", "b", true);

        try std.testing.expect(archive.find("a/one") == null);
        try std.testing.expect(archive.find("b/one") != null);
        try std.testing.expect(archive.find("b/two") != null);

        try std.testing.expectError(
            error.NamespaceConflict,
            archive.rename("b", "keep", true),
        );

        try std.testing.expect(archive.find("b/one") != null);

        try archive.remove("b", true);

        try std.testing.expect(archive.find("b/one") == null);
        try std.testing.expect(archive.find("keep") != null);
    }

    {
        var original = Archive.init(allocator, io);
        defer original.deinit();

        var indexer = tfs.BufferIndexer(u32, u32).init(
            &original.store,
            original.seed,
        );
        defer indexer.deinit();

        try indexer.append("shared bytes");
        const value = try indexer.finish();

        try original.putAt("first", value, 123);
        try original.putAt("second", value, 456);
        try original.putAt(
            "empty",
            .{ .root = null, .byte_count = 0 },
            789,
        );

        var serialized: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&serialized);
        try original.writeImage(&writer);

        const image = writer.buffered();
        const trailer_size = std.mem.readInt(
            u64,
            image[image.len - Archive.footer_size ..][0..8],
            .little,
        );

        const trailer = image[image.len - Archive.footer_size -
            @as(usize, @intCast(trailer_size)) ..][0..@intCast(trailer_size)];

        var loaded = Archive.init(allocator, io);
        defer loaded.deinit();
        try loaded.parseTrailer(trailer);

        try std.testing.expectEqual(original.seed, loaded.seed);
        try std.testing.expectEqual(@as(usize, 3), loaded.entries.items.len);
        try std.testing.expectEqual(
            loaded.find("first").?.root,
            loaded.find("second").?.root,
        );
        try std.testing.expect(loaded.find("empty").?.root == null);
        try std.testing.expectEqual(
            @as(u64, 12),
            loaded.find("first").?.byte_count,
        );

        var output: [12]u8 = undefined;

        try std.testing.expectEqual(
            @as(usize, 12),
            try original.readRange(value.root.?, 0, &output),
        );
        try std.testing.expectEqualSlices(u8, "shared bytes", &output);

        try std.testing.expectEqual(
            @as(usize, 5),
            try original.readRange(value.root.?, 7, output[0..5]),
        );
        try std.testing.expectEqualSlices(u8, "bytes", output[0..5]);
    }

    {
        var loaded = Archive.init(allocator, io);
        defer loaded.deinit();

        try std.testing.expectError(
            error.InvalidArchiveFormat,
            loaded.parseTrailer("TFS4 garbage"),
        );
    }
}

test "formatTimestamp" {
    {
        var buffer: [64]u8 = undefined;

        try std.testing.expectEqualStrings(
            "1970-01-01 00:00:00 UTC",
            try formatTimestamp(0, &buffer),
        );
    }

    {
        var buffer: [64]u8 = undefined;

        try std.testing.expectEqualStrings(
            "1969-12-31 23:59:59 UTC",
            try formatTimestamp(-std.time.ns_per_s, &buffer),
        );
    }
}

test "formatSize" {
    var buffer: [16]u8 = undefined;

    try std.testing.expectEqualStrings("0 B", try formatSize(0, &buffer));
    try std.testing.expectEqualStrings("1023 B", try formatSize(1023, &buffer));
    try std.testing.expectEqualStrings("1.0 KiB", try formatSize(1024, &buffer));
    try std.testing.expectEqualStrings("4.6 MiB", try formatSize(4862985, &buffer));
    try std.testing.expectEqualStrings("886.4 MiB", try formatSize(929451412, &buffer));
    try std.testing.expectEqualStrings("953.7 MiB", try formatSize(1000000000, &buffer));
}
