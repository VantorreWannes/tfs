const std = @import("std");
const builtin = @import("builtin");
const tfs = @import("root.zig");
const projfs = if (builtin.os.tag == .windows) @import("projfs.zig") else struct {};

inline fn writeInt(writer: *std.Io.Writer, comptime T: type, val: T) !void {
    const len = @divExact(@typeInfo(T).int.bits, 8);
    var b: [len]u8 = undefined;
    std.mem.writeInt(T, &b, val, .little);
    try writer.writeAll(&b);
}

inline fn readInt(reader: *std.Io.Reader, comptime T: type) !T {
    const len = @divExact(@typeInfo(T).int.bits, 8);
    var b: [len]u8 = undefined;
    try reader.readSliceAll(&b);
    return std.mem.readInt(T, &b, .little);
}

fn formatTimestamp(nanos: i96, buf: *[32]u8) []const u8 {
    const total_secs: i64 = @intCast(@divFloor(nanos, std.time.ns_per_s));
    const days: i64 = @divFloor(total_secs, 86400);
    const day_secs: i64 = @mod(total_secs, 86400);

    const hours: u32 = @intCast(@divFloor(day_secs, 3600));
    const minutes: u32 = @intCast(@divFloor(@mod(day_secs, 3600), 60));
    const seconds: u32 = @intCast(@mod(day_secs, 60));

    const z = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year, m, d, hours, minutes, seconds,
    }) catch "invalid-time";
}

pub fn Cli(
    comptime Index: type,
    comptime TargetChunkSize: usize,
    comptime IoBufferSize: usize,
) type {
    return struct {
        pub const Buffer = tfs.SpanBuffer(Index);
        pub const Dedup = tfs.ContentIndex(Index);

        pub const Entry = struct {
            path: []const u8,
            root: Index,
            size: u64,
            timestamp: i96,
        };

        pub const Archive = struct {
            const MAGIC = "TFS3";

            buffer: Buffer,
            entries: std.ArrayListUnmanaged(Entry),

            pub fn init() Archive {
                return .{
                    .buffer = Buffer.init(),
                    .entries = .empty,
                };
            }

            pub fn deinit(self: *Archive, allocator: std.mem.Allocator) void {
                for (self.entries.items) |entry| allocator.free(entry.path);
                self.entries.deinit(allocator);
                self.buffer.deinit(allocator);
            }

            pub fn populateDedup(self: *const Archive, allocator: std.mem.Allocator, dedup: *Dedup) !void {
                var i: Index = 0;
                while (i < self.buffer.offsets.items.len) : (i += 1) {
                    const chunk = self.buffer.readBytes(i);
                    const hash = std.hash.XxHash64.hash(0, chunk);
                    try dedup.put(allocator, hash, i);
                }
                var p: Index = 0;
                while (p < self.buffer.pairs.items.len) : (p += 1) {
                    const id = p | Buffer.FLAG;
                    const pair = self.buffer.readPair(id);
                    const hash = (@as(u64, pair[0]) << 32) | pair[1];
                    try dedup.put(allocator, hash, id);
                }
            }

            pub fn load(self: *Archive, io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !void {
                var stream_buf: [IoBufferSize]u8 = undefined;
                var reader = file.reader(io, &stream_buf);

                var magic: [4]u8 = undefined;
                try reader.interface.readSliceAll(&magic);
                if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidArchiveFormat;

                const bytes_len = try readInt(&reader.interface, u32);
                try self.buffer.bytes.resize(allocator, bytes_len);
                try reader.interface.readSliceAll(self.buffer.bytes.items);

                const offsets_len = try readInt(&reader.interface, u32);
                try self.buffer.offsets.resize(allocator, offsets_len);
                try reader.interface.readSliceAll(std.mem.sliceAsBytes(self.buffer.offsets.items));

                const pairs_len = try readInt(&reader.interface, u32);
                try self.buffer.pairs.resize(allocator, pairs_len);
                try reader.interface.readSliceAll(std.mem.sliceAsBytes(self.buffer.pairs.items));

                const entries_len = try readInt(&reader.interface, u32);
                for (self.entries.items) |entry| allocator.free(entry.path);
                self.entries.clearRetainingCapacity();
                try self.entries.ensureTotalCapacity(allocator, entries_len);

                for (0..entries_len) |_| {
                    const path_len = try readInt(&reader.interface, u16);
                    const path = try allocator.alloc(u8, path_len);
                    try reader.interface.readSliceAll(path);
                    const root = try readInt(&reader.interface, Index);
                    const size = try readInt(&reader.interface, u64);
                    const timestamp = try readInt(&reader.interface, i96);
                    self.entries.appendAssumeCapacity(.{
                        .path = path,
                        .root = root,
                        .size = size,
                        .timestamp = timestamp,
                    });
                }
            }

            pub fn save(self: *const Archive, io: std.Io, file: std.Io.File) !void {
                var stream_buf: [IoBufferSize]u8 = undefined;
                var writer = file.writer(io, &stream_buf);

                try writer.interface.writeAll(MAGIC);

                try writeInt(&writer.interface, u32, @intCast(self.buffer.bytes.items.len));
                try writer.interface.writeAll(self.buffer.bytes.items);

                try writeInt(&writer.interface, u32, @intCast(self.buffer.offsets.items.len));
                try writer.interface.writeAll(std.mem.sliceAsBytes(self.buffer.offsets.items));

                try writeInt(&writer.interface, u32, @intCast(self.buffer.pairs.items.len));
                try writer.interface.writeAll(std.mem.sliceAsBytes(self.buffer.pairs.items));

                try writeInt(&writer.interface, u32, @intCast(self.entries.items.len));
                for (self.entries.items) |entry| {
                    try writeInt(&writer.interface, u16, @intCast(entry.path.len));
                    try writer.interface.writeAll(entry.path);
                    try writeInt(&writer.interface, Index, entry.root);
                    try writeInt(&writer.interface, u64, entry.size);
                    try writeInt(&writer.interface, i96, entry.timestamp);
                }
                try writer.interface.flush();
            }

            pub fn find(self: *const Archive, path: []const u8) ?Entry {
                var i = self.entries.items.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, self.entries.items[i].path, path)) {
                        return self.entries.items[i];
                    }
                }
                return null;
            }

            pub fn put(self: *Archive, allocator: std.mem.Allocator, path: []const u8, root: Index, size: u64, timestamp: i96) !void {
                const owned_path = try allocator.dupe(u8, path);
                try self.entries.append(allocator, .{
                    .path = owned_path,
                    .root = root,
                    .size = size,
                    .timestamp = timestamp,
                });
            }

            pub fn remove(self: *Archive, allocator: std.mem.Allocator, path: []const u8) bool {
                var i = self.entries.items.len;
                var removed = false;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, self.entries.items[i].path, path)) {
                        allocator.free(self.entries.items[i].path);
                        _ = self.entries.swapRemove(i);
                        removed = true;
                    }
                }
                return removed;
            }
        };

        pub const Command = enum {
            encode,
            decode,
            list,
            mount,
        };

        pub const Options = struct {
            command: Command,
            archive_path: []const u8,
            entry_name: []const u8,
            input_path: ?[]const u8,
            output_path: ?[]const u8,

            pub fn parse(args: []const [:0]const u8) !Options {
                if (args.len < 3) return error.InsufficientArguments;

                var positional: [4]?[]const u8 = @splat(null);
                var pos_count: usize = 0;
                var explicit_name: ?[]const u8 = null;

                var idx: usize = 1;
                while (idx < args.len) : (idx += 1) {
                    const arg = args[idx];
                    if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
                        if (idx + 1 >= args.len) return error.MissingArgumentValue;
                        idx += 1;
                        explicit_name = args[idx];
                        continue;
                    }

                    if (pos_count < positional.len) {
                        positional[pos_count] = arg;
                        pos_count += 1;
                    }
                }

                const raw_cmd = positional[0] orelse return error.MissingCommand;
                const archive = positional[1] orelse return error.MissingArchivePath;
                const command = std.meta.stringToEnum(Command, raw_cmd) orelse return error.InvalidCommand;

                var entry_name: []const u8 = "";
                var input_path: ?[]const u8 = null;
                var output_path: ?[]const u8 = null;

                switch (command) {
                    .encode => {
                        input_path = positional[2] orelse "-";
                        const is_stdin = std.mem.eql(u8, input_path.?, "-");
                        entry_name = explicit_name orelse if (is_stdin) "stdin" else std.fs.path.basename(input_path.?);
                    },
                    .decode => {
                        if (explicit_name) |name| {
                            entry_name = name;
                            output_path = positional[2] orelse entry_name;
                        } else {
                            entry_name = positional[2] orelse return error.MissingEntryName;
                            output_path = positional[3] orelse entry_name;
                        }
                    },
                    .list => {},
                    .mount => {
                        output_path = positional[2] orelse return error.MissingMountFolder;
                    },
                }

                return .{
                    .command = command,
                    .archive_path = archive,
                    .entry_name = entry_name,
                    .input_path = input_path,
                    .output_path = output_path,
                };
            }
        };

        pub fn printUsage(io: std.Io) !void {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\Usage:
                \\  tfs encode <archive> [input|-]    [--name <entry_name>]
                \\  tfs decode <archive> <entry_name> [output|-]
                \\  tfs list   <archive>
                \\  tfs mount  <archive> <directory>  (Windows ProjFS)
                \\
            );
        }

        pub fn execute(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
            const cwd = std.Io.Dir.cwd();

            if (std.fs.path.dirname(options.archive_path)) |parent| {
                try cwd.createDirPath(io, parent);
            }

            var archive = Archive.init();
            defer archive.deinit(allocator);

            switch (options.command) {
                .encode => {
                    if (cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none })) |archive_file| {
                        defer archive_file.close(io);
                        try archive.load(io, allocator, archive_file);
                    } else |_| {}

                    var dedup = try Dedup.init(allocator, archive.buffer.offsets.items.len * 2);
                    defer dedup.deinit(allocator);
                    try archive.populateDedup(allocator, &dedup);

                    const input_path = options.input_path.?;
                    const is_stdin = std.mem.eql(u8, input_path, "-");

                    var input_file = if (is_stdin)
                        std.Io.File.stdin()
                    else
                        try cwd.openFile(io, input_path, .{ .mode = .read_only, .lock = .none });
                    defer if (!is_stdin) input_file.close(io);

                    var stream_buf: [IoBufferSize]u8 = undefined;
                    var reader = input_file.reader(io, &stream_buf);

                    const seed: u64 = 0x5EED_0000;
                    const result = try tfs.streamToIndex(
                        Index,
                        TargetChunkSize,
                        Index,
                        io,
                        allocator,
                        &reader.interface,
                        seed,
                        &archive.buffer,
                        &dedup,
                    );

                    const timestamp: i96 = std.Io.Clock.now(.real, io).nanoseconds;
                    try archive.put(allocator, options.entry_name, result.root, result.byte_count, timestamp);

                    var archive_output = try cwd.createFile(io, options.archive_path, .{
                        .truncate = true,
                        .lock = .none,
                    });
                    defer archive_output.close(io);
                    try archive.save(io, archive_output);
                },
                .decode => {
                    const archive_file = try cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none });
                    defer archive_file.close(io);
                    try archive.load(io, allocator, archive_file);

                    const entry = archive.find(options.entry_name) orelse return error.FileNotFound;
                    const out_path = options.output_path.?;
                    const is_stdout = std.mem.eql(u8, out_path, "-");

                    if (!is_stdout) {
                        if (std.fs.path.dirname(out_path)) |parent| {
                            try cwd.createDirPath(io, parent);
                        }
                    }

                    var output_file = if (is_stdout)
                        std.Io.File.stdout()
                    else
                        try cwd.createFile(io, out_path, .{ .truncate = true, .lock = .none });
                    defer if (!is_stdout) output_file.close(io);

                    var stream_buf: [IoBufferSize]u8 = undefined;
                    var writer = output_file.writer(io, &stream_buf);

                    try tfs.indexToStream(Index, &archive.buffer, entry.root, &writer.interface);
                    try writer.interface.flush();
                },
                .list => {
                    const archive_file = try cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none });
                    defer archive_file.close(io);
                    try archive.load(io, allocator, archive_file);

                    var stream_buf: [4096]u8 = undefined;
                    var stdout_writer = std.Io.File.stdout().writer(io, &stream_buf);

                    var time_buf: [32]u8 = undefined;
                    for (archive.entries.items, 0..) |entry, i| {
                        const formatted_time = formatTimestamp(entry.timestamp, &time_buf);
                        try stdout_writer.interface.print("[{d}] {s} (size: {d}, root: {d}, time: {s})\n", .{
                            i,
                            entry.path,
                            entry.size,
                            entry.root,
                            formatted_time,
                        });
                    }
                    try stdout_writer.interface.flush();
                },
                .mount => {
                    if (builtin.os.tag != .windows) {
                        std.debug.print("Error: 'mount' is only supported on Windows with ProjFS.\n", .{});
                        return error.UnsupportedPlatform;
                    }

                    if (cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none })) |archive_file| {
                        defer archive_file.close(io);
                        try archive.load(io, allocator, archive_file);
                    } else |_| {}

                    var dedup = try Dedup.init(allocator, archive.buffer.offsets.items.len * 2);
                    defer dedup.deinit(allocator);
                    try archive.populateDedup(allocator, &dedup);

                    const mount_dir = options.output_path orelse return error.MissingMountFolder;
                    try cwd.createDirPath(io, mount_dir);

                    const State = struct {
                        const SpinLock = struct {
                            state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

                            pub fn lock(self: *SpinLock) void {
                                while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
                                    std.atomic.spinLoopHint();
                                }
                            }

                            pub fn unlock(self: *SpinLock) void {
                                self.state.store(0, .release);
                            }
                        };

                        var g_io: std.Io = undefined;
                        var g_allocator: std.mem.Allocator = undefined;
                        var g_dedup: *Dedup = undefined;
                        var g_lock: SpinLock = .{};
                        var g_count: usize = 0;

                        fn onFileWrite(a: *Archive, rel_path: []const u8, full_path: []const u8) anyerror!void {
                            var file = std.Io.Dir.cwd().openFile(g_io, full_path, .{ .mode = .read_only, .lock = .none }) catch return;
                            defer file.close(g_io);

                            var s_buf: [IoBufferSize]u8 = undefined;
                            var r = file.reader(g_io, &s_buf);

                            const seed: u64 = 0x5EED_0000;

                            g_lock.lock();
                            defer g_lock.unlock();

                            const res = try tfs.streamToIndex(
                                Index,
                                TargetChunkSize,
                                Index,
                                g_io,
                                g_allocator,
                                &r.interface,
                                seed,
                                &a.buffer,
                                g_dedup,
                            );

                            const timestamp: i96 = std.Io.Clock.now(.real, g_io).nanoseconds;
                            try a.put(g_allocator, rel_path, res.root, res.byte_count, timestamp);

                            g_count += 1;
                            if (g_count % 100 == 0 or res.byte_count > 1024 * 1024) {
                                std.debug.print("[live] Indexed {d} files (latest: {s})\n", .{ g_count, rel_path });
                            }
                        }

                        fn onFileDelete(a: *Archive, rel_path: []const u8) anyerror!void {
                            g_lock.lock();
                            defer g_lock.unlock();
                            _ = a.remove(g_allocator, rel_path);
                        }
                    };

                    State.g_io = io;
                    State.g_allocator = allocator;
                    State.g_dedup = &dedup;

                    std.debug.print("====================================================\n", .{});
                    std.debug.print(" Mounted '{s}' on '{s}' ({d} entries)\n", .{
                        options.archive_path,
                        mount_dir,
                        archive.entries.items.len,
                    });
                    std.debug.print(" Live FastCDC tree indexing active.\n", .{});
                    std.debug.print(" Press Ctrl+C to unmount.\n", .{});
                    std.debug.print("====================================================\n", .{});

                    try projfs.mount(allocator, &archive, mount_dir, State.onFileWrite, State.onFileDelete);

                    std.debug.print("\n[unmount] Stopping virtualization...\n", .{});

                    std.debug.print("[unmount] Writing archive to '{s}'...\n", .{options.archive_path});
                    var archive_output = try cwd.createFile(io, options.archive_path, .{
                        .truncate = true,
                        .lock = .none,
                    });
                    defer archive_output.close(io);
                    try archive.save(io, archive_output);

                    std.debug.print("[unmount] Done. Total entries: {d}, total bytes indexed: {d}.\n", .{
                        archive.entries.items.len,
                        archive.buffer.bytes.items.len,
                    });
                },
            }
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const App = Cli(u32, 4096, 131072);

    const options = App.Options.parse(args) catch {
        try App.printUsage(io);
        std.process.exit(1);
    };

    try App.execute(io, gpa, options);
}
