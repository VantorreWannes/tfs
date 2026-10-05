const std = @import("std");
const tfs = @import("tfs");
const namespace = @import("namespace.zig");

pub const NodeId = namespace.NodeId;
pub const ByteNames = namespace.ByteNames;
pub const Namespace = namespace.Namespace;

pub const max_file_bytes: u64 = 1 << 30;

pub const Error = error{
    UnknownNode,
    NotDirectory,
    IsDirectory,
    InvalidName,
    AlreadyExists,
    NotFound,
    RootImmutable,
    DirectoryNotEmpty,
    Cycle,
    IdExhausted,
    InvalidSnapshot,
    UnknownContentId,
    InvalidIndex,
    MissingWord,
    DataTruncated,
    FileTooLarge,
    OutOfMemory,
    WriteFailed,
    ReadFailed,
    EndOfStream,
    Unexpected,
    AccessDenied,
    Canceled,
    Unseekable,
    FileOpen,
    InvalidHandle,
    HashCollision,
    RollbackFailed,
    WriterPoisoned,
};

pub const Handle = u64;

pub fn Fs(comptime Names: type) type {
    return struct {
        const Self = @This();
        const Ns = Namespace(Names);

        pub const Config = tfs.TreeConfig(u128, 16);

        gpa: std.mem.Allocator,
        io: std.Io,
        ns: Ns,
        writer: tfs.TreeFileWriter(Config),
        data_path: []u8,
        handles: std.AutoHashMapUnmanaged(Handle, NodeId) = .empty,
        open_counts: std.AutoHashMapUnmanaged(NodeId, u32) = .empty,
        next_handle: Handle = 1,

        fn nsPath(gpa: std.mem.Allocator, data_path: []const u8) ![]u8 {
            return std.mem.concat(gpa, u8, &.{ data_path, ".ns" });
        }

        fn openCommon(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8, load_snapshot: bool) !Self {
            const index_path = try tfs.indexPath(gpa, data_path);
            defer gpa.free(index_path);

            const dir = std.Io.Dir.cwd();
            const data = try dir.createFile(io, data_path, .{ .read = true, .truncate = false });
            errdefer data.close(io);
            const index = try dir.createFile(io, index_path, .{ .read = true, .truncate = false });
            errdefer index.close(io);

            var self: Self = .{
                .gpa = gpa,
                .io = io,
                .ns = try Ns.init(gpa),
                .writer = undefined,
                .data_path = undefined,
            };
            errdefer self.ns.deinit();
            self.writer = try tfs.TreeFileWriter(Config).init(gpa, io, index, data);
            errdefer self.writer.deinit();
            self.data_path = try gpa.dupe(u8, data_path);
            errdefer gpa.free(self.data_path);

            if (load_snapshot) {
                const path = try nsPath(gpa, data_path);
                defer gpa.free(path);
                if (dir.openFile(io, path, .{})) |snapshot| {
                    defer snapshot.close(io);
                    const bytes = try readAllFile(gpa, io, snapshot);
                    defer gpa.free(bytes);
                    try self.loadSnapshot(bytes);
                } else |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
            }

            return self;
        }

        pub fn init(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8) !Self {
            return openCommon(gpa, io, data_path, false);
        }

        pub fn open(gpa: std.mem.Allocator, io: std.Io, data_path: []const u8) !Self {
            return openCommon(gpa, io, data_path, true);
        }

        pub fn deinit(self: *Self) void {
            self.handles.deinit(self.gpa);
            self.open_counts.deinit(self.gpa);
            self.writer.data_file.close(self.io);
            self.writer.index_file.close(self.io);
            self.writer.deinit();
            self.ns.deinit();
            self.gpa.free(self.data_path);
            self.* = undefined;
        }

        fn readAllFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
            var buffer: [4096]u8 = undefined;
            var reader = file.reader(io, &buffer);
            return reader.interface.allocRemaining(gpa, .unlimited);
        }

        fn loadSnapshot(self: *Self, bytes: []const u8) Error!void {
            var restored = try Ns.decode(self.gpa, bytes);
            errdefer restored.deinit();
            for (restored.nodes.items) |maybe_entry| {
                const entry = maybe_entry orelse continue;
                if (entry.kind == .file and self.writer.metadata(entry.kind.file) == null)
                    return error.UnknownContentId;
            }
            self.ns.deinit();
            self.ns = restored;
        }

        pub fn stat(self: *const Self, id: NodeId) Error!namespace.Entry {
            return self.ns.stat(id);
        }

        pub fn lookup(self: *const Self, parent: NodeId, name: []const u8) Error!NodeId {
            return self.ns.lookup(parent, name);
        }

        pub fn resolve(self: *const Self, start: NodeId, components: []const []const u8) Error!NodeId {
            return self.ns.resolve(start, components);
        }

        pub fn children(self: *const Self, parent: NodeId) Error!Ns.Iterator {
            return self.ns.children(parent);
        }

        pub fn createDirectory(self: *Self, parent: NodeId, name: []const u8) Error!NodeId {
            return self.ns.createDirectory(parent, name);
        }

        pub fn createFile(self: *Self, parent: NodeId, name: []const u8) Error!NodeId {
            const empty = try self.writer.put(&.{});
            return self.ns.createFile(parent, name, empty);
        }

        pub fn createFileWith(self: *Self, parent: NodeId, name: []const u8, bytes: []const u8) Error!NodeId {
            if (bytes.len > max_file_bytes) return error.FileTooLarge;
            const content = try self.writer.put(bytes);
            return self.ns.createFile(parent, name, content);
        }

        pub fn setContent(self: *Self, id: NodeId, bytes: []const u8) Error!void {
            if (bytes.len > max_file_bytes) return error.FileTooLarge;
            const content = try self.writer.put(bytes);
            try self.ns.setContent(id, content);
        }

        pub fn readFile(self: *Self, id: NodeId) Error![]u8 {
            const entry = try self.ns.stat(id);
            if (entry.kind != .file) return error.IsDirectory;
            return self.writer.get(self.gpa, entry.kind.file);
        }

        pub fn move(self: *Self, id: NodeId, parent: NodeId, name: []const u8) Error!void {
            try self.ns.move(id, parent, name);
        }

        pub fn remove(self: *Self, id: NodeId) Error!void {
            if ((self.open_counts.get(id) orelse 0) > 0) return error.FileOpen;
            try self.ns.remove(id);
        }

        pub fn encode(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            return self.ns.encode(allocator);
        }

        pub fn decode(self: *Self, bytes: []const u8) Error!void {
            try self.loadSnapshot(bytes);
        }

        pub fn size(self: *const Self, id: NodeId) Error!u64 {
            const entry = try self.ns.stat(id);
            if (entry.kind != .file) return error.IsDirectory;
            const metadata = self.writer.metadata(entry.kind.file) orelse return error.UnknownContentId;
            return metadata.byte_len;
        }

        fn fileBytes(self: *Self, id: NodeId) Error![]u8 {
            const entry = try self.ns.stat(id);
            if (entry.kind != .file) return error.IsDirectory;
            return self.writer.get(self.gpa, entry.kind.file);
        }

        fn storeBytes(self: *Self, id: NodeId, bytes: []const u8) Error!void {
            if (bytes.len > max_file_bytes) return error.FileTooLarge;
            const content = try self.writer.put(bytes);
            try self.ns.setContent(id, content);
        }

        pub fn readRange(self: *Self, id: NodeId, offset: u64, buffer: []u8) Error!usize {
            const old = try self.fileBytes(id);
            defer self.gpa.free(old);
            if (offset >= old.len) return 0;
            const start: usize = @intCast(offset);
            const count = @min(buffer.len, old.len - start);
            @memcpy(buffer[0..count], old[start..][0..count]);
            return count;
        }

        pub fn writeRange(self: *Self, id: NodeId, offset: u64, bytes: []const u8) Error!usize {
            const old = try self.fileBytes(id);
            defer self.gpa.free(old);

            const end = std.math.add(u64, offset, bytes.len) catch return error.FileTooLarge;
            const new_len = @max(old.len, end);
            if (new_len > max_file_bytes) return error.FileTooLarge;

            const buffer = try self.gpa.alloc(u8, @intCast(new_len));
            defer self.gpa.free(buffer);

            const start: usize = @intCast(offset);
            @memcpy(buffer[0..old.len], old);
            if (start > old.len) @memset(buffer[old.len..start], 0);
            @memcpy(buffer[start..][0..bytes.len], bytes);

            try self.storeBytes(id, buffer);
            return bytes.len;
        }

        pub fn truncate(self: *Self, id: NodeId, new_len: u64) Error!void {
            if (new_len > max_file_bytes) return error.FileTooLarge;
            const old = try self.fileBytes(id);
            defer self.gpa.free(old);

            if (new_len == old.len) return;
            if (new_len <= old.len) {
                try self.storeBytes(id, old[0..@intCast(new_len)]);
                return;
            }

            const buffer = try self.gpa.alloc(u8, @intCast(new_len));
            defer self.gpa.free(buffer);
            @memcpy(buffer[0..old.len], old);
            @memset(buffer[old.len..], 0);
            try self.storeBytes(id, buffer);
        }

        pub fn commit(self: *Self) !void {
            if (self.writer.poisoned) return error.WriterPoisoned;
            try self.writer.data_file.sync(self.io);
            try self.writer.index_file.sync(self.io);

            const bytes = try self.ns.encode(self.gpa);
            defer self.gpa.free(bytes);

            const dir = std.Io.Dir.cwd();
            const tmp_path = try std.mem.concat(self.gpa, u8, &.{ self.data_path, ".ns.tmp" });
            defer self.gpa.free(tmp_path);
            const path = try nsPath(self.gpa, self.data_path);
            defer self.gpa.free(path);

            {
                const tmp = try dir.createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                defer tmp.close(self.io);
                var buffer: [4096]u8 = undefined;
                var writer = tmp.writer(self.io, &buffer);
                try writer.interface.writeAll(bytes);
                try writer.interface.flush();
                try tmp.sync(self.io);
            }

            try dir.rename(tmp_path, dir, path, self.io);
        }

        pub fn openHandle(self: *Self, id: NodeId) Error!Handle {
            const entry = try self.ns.stat(id);
            if (entry.kind != .file) return error.IsDirectory;

            if (self.next_handle == 0 or (self.open_counts.get(id) orelse 0) == std.math.maxInt(u32))
                return error.IdExhausted;
            const handle = self.next_handle;
            try self.handles.put(self.gpa, handle, id);
            errdefer _ = self.handles.remove(handle);

            const count = try self.open_counts.getOrPut(self.gpa, id);
            if (!count.found_existing) count.value_ptr.* = 0;
            count.value_ptr.* += 1;
            // Zero marks exhaustion; never reuse a previously issued handle.
            self.next_handle +%= 1;
            return handle;
        }

        pub fn closeHandle(self: *Self, handle: Handle) Error!void {
            const id = self.handles.get(handle) orelse return error.InvalidHandle;
            if (!self.handles.remove(handle)) return error.InvalidHandle;

            const count = self.open_counts.getPtr(id) orelse return error.InvalidHandle;
            count.* -= 1;
            if (count.* == 0) _ = self.open_counts.remove(id);
        }

        fn handleId(self: *const Self, handle: Handle) Error!NodeId {
            return self.handles.get(handle) orelse error.InvalidHandle;
        }

        pub fn readHandle(self: *Self, handle: Handle, offset: u64, buffer: []u8) Error!usize {
            return self.readRange(try self.handleId(handle), offset, buffer);
        }

        pub fn writeHandle(self: *Self, handle: Handle, offset: u64, bytes: []const u8) Error!usize {
            return self.writeRange(try self.handleId(handle), offset, bytes);
        }

        pub fn truncateHandle(self: *Self, handle: Handle, new_len: u64) Error!void {
            return self.truncate(try self.handleId(handle), new_len);
        }

        pub fn sizeHandle(self: *const Self, handle: Handle) Error!u64 {
            return self.size(try self.handleId(handle));
        }
    };
}

fn testOpenAllocationFailures(gpa: std.mem.Allocator, path: []const u8, load_snapshot: bool, expected_error: ?anyerror) !void {
    var fs = Fs(ByteNames).openCommon(gpa, std.testing.io, path, load_snapshot) catch |err| {
        if (expected_error != null and err == expected_error.?) return;
        return err;
    };
    defer fs.deinit();
    try std.testing.expect(expected_error == null);
}

fn testLoadAllocationFailures(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, expected_error: anyerror) !void {
    var fs = try Fs(ByteNames).init(gpa, std.testing.io, path);
    defer fs.deinit();
    const keep = try fs.createDirectory(.root, "keep");
    fs.loadSnapshot(bytes) catch |err| {
        try std.testing.expectEqual(keep, try fs.lookup(.root, "keep"));
        if (err == expected_error) return;
        return err;
    };
    return error.TestUnexpectedResult;
}

fn testDataPath(dir: std.Io.Dir) ![:0]u8 {
    const file = try dir.createFile(std.testing.io, "store.data", .{});
    file.close(std.testing.io);
    return dir.realPathFileAlloc(std.testing.io, "store.data", std.testing.allocator);
}

test "fs open and corrupt snapshot loads clean up every allocation failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testDataPath(tmp.dir);
    defer gpa.free(path);

    try std.testing.checkAllAllocationFailures(gpa, testOpenAllocationFailures, .{ path, false, null });
    try std.testing.checkAllAllocationFailures(gpa, testOpenAllocationFailures, .{ path, true, null });
    {
        var fs = try Fs(ByteNames).init(gpa, io, path);
        defer fs.deinit();
        _ = try fs.createFileWith(.root, "file", "persisted content");
        try fs.commit();
    }
    try std.testing.checkAllAllocationFailures(gpa, testOpenAllocationFailures, .{ path, false, null });
    try std.testing.checkAllAllocationFailures(gpa, testOpenAllocationFailures, .{ path, true, null });

    var ns = try Namespace(ByteNames).init(gpa);
    defer ns.deinit();
    _ = try ns.createFile(.root, "missing", .fromIndex(100));
    const unknown = try ns.encode(gpa);
    defer gpa.free(unknown);
    // A trailing byte rejects the snapshot after decoding its allocated entries.
    const corrupt = try std.mem.concat(gpa, u8, &.{ unknown, &.{0} });
    defer gpa.free(corrupt);
    for ([_][]const u8{ unknown, corrupt }, [_]anyerror{ error.UnknownContentId, error.InvalidSnapshot }) |bytes, expected_error| {
        {
            const snapshot = try tmp.dir.createFile(io, "store.data.ns", .{});
            defer snapshot.close(io);
            try snapshot.writeStreamingAll(io, bytes);
        }
        try std.testing.checkAllAllocationFailures(gpa, testOpenAllocationFailures, .{ path, true, expected_error });
        try std.testing.checkAllAllocationFailures(gpa, testLoadAllocationFailures, .{ path, bytes, expected_error });
    }
}

test "fs openHandle rolls back both map allocation failures" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testDataPath(tmp.dir);
    defer gpa.free(path);
    var fs = try Fs(ByteNames).init(gpa, std.testing.io, path);
    defer fs.deinit();
    const file = try fs.createFile(.root, "file");

    // The first allocation grows handles; the second grows open_counts.
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        fs.gpa = failing.allocator();
        {
            defer fs.gpa = gpa;
            defer {
                fs.handles.deinit(fs.gpa);
                fs.handles = .empty;
                fs.open_counts.deinit(fs.gpa);
                fs.open_counts = .empty;
            }
            try std.testing.expectError(error.OutOfMemory, fs.openHandle(file));
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 0), fs.handles.count());
            try std.testing.expectEqual(@as(usize, 0), fs.open_counts.count());
            try std.testing.expectEqual(@as(Handle, 1), fs.next_handle);
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    const handle = try fs.openHandle(file);
    try fs.closeHandle(handle);
    try fs.remove(file);
}

test "fs handle and open count exhaustion leave tracking unchanged" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testDataPath(tmp.dir);
    defer gpa.free(path);
    var fs = try Fs(ByteNames).init(gpa, std.testing.io, path);
    defer fs.deinit();
    const file = try fs.createFile(.root, "file");
    const first = try fs.openHandle(file);
    fs.open_counts.getPtr(file).?.* = std.math.maxInt(u32);
    try std.testing.expectError(error.IdExhausted, fs.openHandle(file));
    try std.testing.expectEqual(@as(Handle, 2), fs.next_handle);
    try std.testing.expectEqual(@as(usize, 1), fs.handles.count());
    try std.testing.expectEqual(std.math.maxInt(u32), fs.open_counts.get(file).?);
    fs.open_counts.getPtr(file).?.* = 1;

    fs.next_handle = std.math.maxInt(Handle);
    const last = try fs.openHandle(file);
    try std.testing.expectEqual(std.math.maxInt(Handle), last);
    try std.testing.expectError(error.IdExhausted, fs.openHandle(file));
    try std.testing.expectEqual(@as(usize, 2), fs.handles.count());
    try std.testing.expectEqual(@as(u32, 2), fs.open_counts.get(file).?);
    try fs.closeHandle(first);
    try fs.closeHandle(last);
    try std.testing.expectError(error.IdExhausted, fs.openHandle(file));
    try fs.remove(file);
}

test "fs poisoned commit does not publish namespace changes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testDataPath(tmp.dir);
    defer gpa.free(path);
    {
        var fs = try Fs(ByteNames).init(gpa, io, path);
        defer fs.deinit();
        _ = try fs.createDirectory(.root, "committed");
        try fs.commit();
        _ = try fs.createDirectory(.root, "uncommitted");
        fs.writer.poisoned = true;
        try std.testing.expectError(error.WriterPoisoned, fs.commit());
        try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "store.data.ns.tmp", .{}));
    }
    var reopened = try Fs(ByteNames).open(gpa, io, path);
    defer reopened.deinit();
    _ = try reopened.lookup(.root, "committed");
    try std.testing.expectError(error.NotFound, reopened.lookup(.root, "uncommitted"));
}

test "fs creates files with initial content and reads them back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try testDataPath(tmp.dir);
    defer gpa.free(data_path);

    {
        var fs = try Fs(ByteNames).init(gpa, io, data_path);
        defer fs.deinit();

        const docs = try fs.createDirectory(.root, "docs");
        const file = try fs.createFileWith(docs, "hello.txt", "hello world");
        const read = try fs.readFile(file);
        defer gpa.free(read);
        try std.testing.expectEqualStrings("hello world", read);

        const empty = try fs.createFile(docs, "empty");
        const empty_read = try fs.readFile(empty);
        defer gpa.free(empty_read);
        try std.testing.expectEqual(@as(usize, 0), empty_read.len);
    }
}

test "fs updates file content in place" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try testDataPath(tmp.dir);
    defer gpa.free(data_path);

    {
        var fs = try Fs(ByteNames).init(gpa, io, data_path);
        defer fs.deinit();

        const file = try fs.createFileWith(.root, "data", "v1");
        try fs.setContent(file, "v2 with more bytes");
        const read = try fs.readFile(file);
        defer gpa.free(read);
        try std.testing.expectEqualStrings("v2 with more bytes", read);
    }
}

test "fs reads and writes ranges with zero-filled gaps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try testDataPath(tmp.dir);
    defer gpa.free(data_path);

    {
        var fs = try Fs(ByteNames).init(gpa, io, data_path);
        defer fs.deinit();

        const file = try fs.createFileWith(.root, "f", "hello world");

        var buffer: [5]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 5), try fs.readRange(file, 6, &buffer));
        try std.testing.expectEqualStrings("world", &buffer);
        try std.testing.expectEqual(@as(usize, 0), try fs.readRange(file, 100, &buffer));

        try std.testing.expectEqual(@as(usize, 6), try fs.writeRange(file, 6, "there!"));
        try std.testing.expectEqual(@as(u64, 12), try fs.size(file));
        const read = try fs.readFile(file);
        defer gpa.free(read);
        try std.testing.expectEqualStrings("hello there!", read);

        try std.testing.expectEqual(@as(usize, 3), try fs.writeRange(file, 20, "end"));
        try std.testing.expectEqual(@as(u64, 23), try fs.size(file));
        const gapped = try fs.readFile(file);
        defer gpa.free(gapped);
        var expected = std.mem.zeroes([23]u8);
        @memcpy(expected[0..12], "hello there!");
        @memcpy(expected[20..23], "end");
        try std.testing.expectEqualSlices(u8, &expected, gapped);

        try fs.truncate(file, 5);
        try std.testing.expectEqual(@as(u64, 5), try fs.size(file));
        const cut = try fs.readFile(file);
        defer gpa.free(cut);
        try std.testing.expectEqualStrings("hello", cut);

        try fs.truncate(file, 8);
        try std.testing.expectEqual(@as(u64, 8), try fs.size(file));
        const grown = try fs.readFile(file);
        defer gpa.free(grown);
        var grown_expected = std.mem.zeroes([8]u8);
        @memcpy(grown_expected[0..5], "hello");
        try std.testing.expectEqualSlices(u8, &grown_expected, grown);
    }
}

test "fs commits and reopens with names and content intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try testDataPath(tmp.dir);
    defer gpa.free(data_path);

    {
        var fs = try Fs(ByteNames).open(gpa, io, data_path);
        defer fs.deinit();

        var children = try fs.children(.root);
        try std.testing.expect(children.next() == null);

        const docs = try fs.createDirectory(.root, "docs");
        const file = try fs.createFileWith(docs, "a.txt", "persisted");
        try fs.commit();

        _ = file;
    }

    {
        var fs = try Fs(ByteNames).open(gpa, io, data_path);
        defer fs.deinit();

        const docs = try fs.lookup(.root, "docs");
        const file = try fs.lookup(docs, "a.txt");
        const read = try fs.readFile(file);
        defer gpa.free(read);
        try std.testing.expectEqualStrings("persisted", read);

        try fs.setContent(file, "updated");
        try fs.commit();
    }

    {
        var fs = try Fs(ByteNames).open(gpa, io, data_path);
        defer fs.deinit();

        const docs = try fs.lookup(.root, "docs");
        const file = try fs.lookup(docs, "a.txt");
        const read = try fs.readFile(file);
        defer gpa.free(read);
        try std.testing.expectEqualStrings("updated", read);
    }
}

test "fs handles survive renames and block removal while open" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try testDataPath(tmp.dir);
    defer gpa.free(data_path);

    {
        var fs = try Fs(ByteNames).init(gpa, io, data_path);
        defer fs.deinit();

        const file = try fs.createFileWith(.root, "f", "handle data");
        const handle = try fs.openHandle(file);

        try fs.move(file, .root, "g");
        var buffer: [6]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 6), try fs.readHandle(handle, 0, &buffer));
        try std.testing.expectEqualStrings("handle", &buffer);

        try std.testing.expectEqual(@as(usize, 5), try fs.writeHandle(handle, 7, "bytes"));
        try std.testing.expectEqual(@as(u64, 12), try fs.sizeHandle(handle));

        try std.testing.expectError(error.FileOpen, fs.remove(file));
        try std.testing.expectError(error.FileOpen, fs.remove(try fs.lookup(.root, "g")));

        try fs.closeHandle(handle);
        try fs.remove(try fs.lookup(.root, "g"));

        try std.testing.expectError(error.InvalidHandle, fs.readHandle(handle, 0, &buffer));
    }
}
