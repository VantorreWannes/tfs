const std = @import("std");
const tfs = @import("tfs");

const Archive = tfs.Archive(u32, u8);

const Parameters = struct {
    const Self = @This();

    mode: ?[]const u8 = null,
    archive: ?[]const u8 = null,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    name: ?[]const u8 = null,

    fn findOption(args: []const [:0]const u8, flag: []const u8) ?usize {
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, flag)) return i;
        }
        return null;
    }

    pub fn init(args: []const [:0]const u8) Self {
        var positional: [4]?[]const u8 = .{ null, null, null, null };
        var pos_count: usize = 0;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
                i += 1;
                continue;
            }

            if (pos_count < 4) {
                positional[pos_count] = arg;
                pos_count += 1;
            }
        }

        const name_idx = findOption(args, "--name") orelse findOption(args, "-n");
        const name = if (name_idx) |idx| if (idx + 1 < args.len) args[idx + 1] else null else null;

        return .{
            .mode = positional[0],
            .archive = positional[1],
            .input = positional[2],
            .output = positional[3],
            .name = name,
        };
    }
};

const Config = struct {
    const Self = @This();

    pub const Mode = enum {
        encode,
        decode,
        list,
    };

    mode: Mode,
    archive_path: []const u8,
    entry_name: []const u8,
    input_file: ?std.Io.File,
    output_file: ?std.Io.File,
    close_input: bool,
    close_output: bool,

    pub fn initFromParameters(io: std.Io, p: *const Parameters) !Self {
        const mode_str = p.mode orelse return error.MissingArguments;
        const archive_path = p.archive orelse return error.MissingArguments;

        const mode = if (std.mem.eql(u8, mode_str, "encode"))
            Mode.encode
        else if (std.mem.eql(u8, mode_str, "decode"))
            Mode.decode
        else if (std.mem.eql(u8, mode_str, "list"))
            Mode.list
        else
            return error.InvalidMode;

        const cwd = std.Io.Dir.cwd();
        var in_file: ?std.Io.File = null;
        var out_file: ?std.Io.File = null;
        var close_in = false;
        var close_out = false;
        var entry_name: []const u8 = "";

        switch (mode) {
            .encode => {
                const in_path = p.input orelse "-";
                const is_stdin = std.mem.eql(u8, in_path, "-");
                in_file = if (is_stdin) std.Io.File.stdin() else try cwd.openFile(io, in_path, .{ .mode = .read_only });
                close_in = !is_stdin;

                entry_name = p.name orelse (if (is_stdin) "stdin" else std.fs.path.basename(in_path));
            },
            .decode => {
                entry_name = p.name orelse (p.input orelse return error.MissingEntryName);
                const out_path = p.output orelse (if (p.name != null and p.input != null) p.input.? else "-");
                const is_stdout = std.mem.eql(u8, out_path, "-");
                out_file = if (is_stdout) std.Io.File.stdout() else try cwd.createFile(io, out_path, .{});
                close_out = !is_stdout;
            },
            .list => {},
        }

        return .{
            .mode = mode,
            .archive_path = archive_path,
            .entry_name = entry_name,
            .input_file = in_file,
            .output_file = out_file,
            .close_input = close_in,
            .close_output = close_out,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        if (self.close_input) if (self.input_file) |f| f.close(io);
        if (self.close_output) if (self.output_file) |f| f.close(io);
    }
};

fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage:
        \\  tfs encode <archive> [input|-] [--name <entry_name>]
        \\  tfs decode <archive> [entry_name] [output|-] [--name <entry_name>]
        \\  tfs list   <archive>
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const params = Parameters.init(args);

    var config = Config.initFromParameters(io, &params) catch |err| {
        if (err == error.MissingArguments or err == error.InvalidMode or err == error.MissingEntryName) {
            try printUsage(io);
            return;
        }
        return err;
    };
    defer config.deinit(io);

    const cwd = std.Io.Dir.cwd();

    switch (config.mode) {
        .encode => {
            var archive: Archive = undefined;
            {
                var existing = cwd.openFile(io, config.archive_path, .{ .mode = .read_only }) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (existing) |*file| {
                    defer file.close(io);
                    const stat = try file.stat(io);
                    if (stat.size > 0) {
                        var read_buf: [131072]u8 = undefined;
                        var reader = file.reader(io, &read_buf);
                        archive = Archive.readFrom(arena, &reader.interface, true) catch |err| switch (err) {
                            error.InvalidArchiveFormat => try Archive.init(arena),
                            else => return err,
                        };
                    } else {
                        archive = try Archive.init(arena);
                    }
                } else {
                    archive = try Archive.init(arena);
                }
            }

            const in_file = config.input_file.?;
            const stat = try in_file.stat(io);
            const input_bytes = if (stat.size > 0) blk: {
                var in_map = try std.Io.File.MemoryMap.create(io, in_file, .{
                    .len = stat.size,
                    .protection = .{ .write = false },
                });
                defer in_map.destroy(io);
                break :blk try arena.dupe(u8, in_map.memory);
            } else try arena.alloc(u8, 0);

            _ = try archive.encodeLeaves(arena, config.entry_name, input_bytes);

            var out_file = try cwd.createFile(io, config.archive_path, .{ .truncate = true });
            defer out_file.close(io);

            var write_buf: [131072]u8 = undefined;
            var out_writer = out_file.writer(io, &write_buf);
            try archive.writeTo(&out_writer.interface);
            try out_writer.interface.flush();
        },
        .decode => {
            var arc_file = cwd.openFile(io, config.archive_path, .{ .mode = .read_only }) catch |err| {
                if (err == error.FileNotFound) {
                    try std.Io.File.stdout().writeStreamingAll(io, "Archive not found.\n");
                    return;
                }
                return err;
            };
            defer arc_file.close(io);

            var read_buf: [131072]u8 = undefined;
            var r = arc_file.reader(io, &read_buf);
            const archive = try Archive.readFrom(arena, &r.interface, false);

            var write_buf: [131072]u8 = undefined;
            var w = config.output_file.?.writer(io, &write_buf);
            try archive.decodeStream(arena, config.entry_name, &w.interface);
            try w.interface.flush();
        },
        .list => {
            var arc_file = cwd.openFile(io, config.archive_path, .{ .mode = .read_only }) catch |err| {
                if (err == error.FileNotFound) {
                    try std.Io.File.stdout().writeStreamingAll(io, "Archive not found.\n");
                    return;
                }
                return err;
            };
            defer arc_file.close(io);

            var read_buf: [4096]u8 = undefined;
            var r = arc_file.reader(io, &read_buf);
            const catalog = try Archive.readCatalogOnly(arena, &r.interface);

            var stdout = std.Io.File.stdout();
            for (catalog.entries.items) |e| {
                const msg = try std.fmt.allocPrint(arena, "{s} (root_id: {d})\n", .{ e.name, e.root_id });
                try stdout.writeStreamingAll(io, msg);
            }
        },
    }
}
