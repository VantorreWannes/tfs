const std = @import("std");
const tfs = @import("root.zig");

pub fn Cli(
    comptime Index: type,
    comptime TargetChunkSize: usize,
    comptime IoBufferSize: usize,
) type {
    return struct {
        pub const Fs = tfs.FileSystem(Index, TargetChunkSize);

        pub const Command = enum {
            encode,
            decode,
            list,
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
                        entry_name = explicit_name orelse (positional[2] orelse return error.MissingEntryName);
                        output_path = positional[3] orelse if (explicit_name != null and positional[2] != null) positional[2].? else "-";
                    },
                    .list => {},
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
                \\  tfs encode <archive> [input|-] [--name <entry_name>]
                \\  tfs decode <archive> [entry_name] [output|-] [--name <entry_name>]
                \\  tfs list   <archive>
                \\
            );
        }

        pub fn execute(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
            const cwd = std.Io.Dir.cwd();

            if (std.fs.path.dirname(options.archive_path)) |parent| {
                try cwd.createDirPath(io, parent);
            }

            var fs = try Fs.init(allocator);
            defer fs.deinit(allocator);

            switch (options.command) {
                .encode => {
                    if (cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none })) |archive_file| {
                        defer archive_file.close(io);
                        try fs.loadFrom(io, allocator, archive_file, true);
                    } else |_| {}

                    try fs.prepareForEncode(allocator, options.entry_name);
                    const active_path = fs.active_entry.?.path;

                    const input_path = options.input_path.?;
                    const is_stdin = std.mem.eql(u8, input_path, "-");

                    var input_file = if (is_stdin)
                        std.Io.File.stdin()
                    else
                        try cwd.openFile(io, input_path, .{ .mode = .read_only, .lock = .none });
                    defer if (!is_stdin) input_file.close(io);

                    var stream_buf: [IoBufferSize]u8 = undefined;
                    var reader = input_file.reader(io, &stream_buf);
                    var read_chunk: [IoBufferSize]u8 = undefined;

                    while (true) {
                        const bytes_read = try reader.interface.readSliceShort(&read_chunk);
                        if (bytes_read == 0) break;
                        try fs.appendSlice(allocator, active_path, read_chunk[0..bytes_read]);
                    }

                    var archive_output = try cwd.createFile(io, options.archive_path, .{
                        .truncate = true,
                        .lock = .none,
                    });
                    defer archive_output.close(io);
                    try fs.writeTo(io, allocator, archive_output);
                },
                .decode => {
                    const archive_file = try cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none });
                    defer archive_file.close(io);
                    try fs.loadFrom(io, allocator, archive_file, false);

                    const file_size = (try fs.size(allocator, options.entry_name)) orelse return error.FileNotFound;
                    const out_path = options.output_path.?;
                    const is_stdout = std.mem.eql(u8, out_path, "-");

                    var output_file = if (is_stdout)
                        std.Io.File.stdout()
                    else
                        try cwd.createFile(io, out_path, .{ .truncate = true, .lock = .none });
                    defer if (!is_stdout) output_file.close(io);

                    var stream_buf: [IoBufferSize]u8 = undefined;
                    var writer = output_file.writer(io, &stream_buf);

                    var read_chunk: [IoBufferSize]u8 = undefined;
                    var offset: u64 = 0;

                    while (offset < file_size) {
                        const bytes_read = try fs.read(allocator, options.entry_name, offset, &read_chunk);
                        if (bytes_read == 0) break;
                        try writer.interface.writeAll(read_chunk[0..bytes_read]);
                        offset += bytes_read;
                    }
                    try writer.interface.flush();
                },
                .list => {
                    const archive_file = try cwd.openFile(io, options.archive_path, .{ .mode = .read_only, .lock = .none });
                    defer archive_file.close(io);
                    try fs.loadFrom(io, allocator, archive_file, false);

                    var stream_buf: [4096]u8 = undefined;
                    var stdout_writer = std.Io.File.stdout().writer(io, &stream_buf);

                    for (fs.entries.items) |entry| {
                        try stdout_writer.interface.print("{s} (size: {d}, root: {d})\n", .{
                            entry.path,
                            entry.size,
                            entry.root.raw(),
                        });
                    }
                    try stdout_writer.interface.flush();
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
    const App = Cli(u32, 64, std.math.maxInt(u21));

    const options = App.Options.parse(args) catch {
        try App.printUsage(io);
        std.process.exit(1);
    };

    try App.execute(io, gpa, options);
}
