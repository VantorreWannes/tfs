const std = @import("std");
const fs_mod = @import("fs.zig");
const vfs = @import("vfs.zig");

const Fs = fs_mod.Fs(fs_mod.ByteNames);

const usage_text =
    \\usage:
    \\  tfs put <store> <file>          store a file into the filesystem
    \\  tfs get <store> <path> [out]    extract a file (out "-" = stdout)
    \\  tfs ls <store> [path]           list a directory
    \\  tfs mount <store> <dir>         mount as a virtual directory (Windows ProjFS)
    \\
    \\  <store>  data file; index kept beside it as <store>.idx,
    \\           namespace snapshot as <store>.ns
    \\  <path>   path inside the filesystem, e.g. docs/notes/a.txt
    \\
;

const Request = union(enum) {
    put: struct { store: []const u8, input: []const u8 },
    get: struct { store: []const u8, path: []const u8, output: ?[]const u8 },
    ls: struct { store: []const u8, path: ?[]const u8 },
    mount: struct { store: []const u8, directory: []const u8 },
    @"read-raw": []const u8,

    const ParseError = error{
        MissingCommand,
        InvalidCommand,
        MissingArgument,
        TooManyArguments,
        StorePipe,
    };

    fn parse(arguments: []const [:0]const u8) ParseError!Request {
        if (arguments.len < 2) return error.MissingCommand;

        const command = std.meta.stringToEnum(
            std.meta.Tag(Request),
            arguments[1],
        ) orelse return error.InvalidCommand;
        const rest = arguments[2..];

        const limits: struct { min: usize, max: usize } = switch (command) {
            .ls => .{ .min = 1, .max = 2 },
            .put => .{ .min = 2, .max = 2 },
            .get => .{ .min = 2, .max = 3 },
            .mount => .{ .min = 2, .max = 2 },
            .@"read-raw" => .{ .min = 1, .max = 1 },
        };
        if (rest.len < limits.min) return error.MissingArgument;
        if (rest.len > limits.max) return error.TooManyArguments;

        const store = rest[0];
        if (std.mem.eql(u8, store, "-")) return error.StorePipe;

        return switch (command) {
            .put => .{ .put = .{ .store = store, .input = rest[1] } },
            .get => .{ .get = .{
                .store = store,
                .path = rest[1],
                .output = if (rest.len > 2) rest[2] else null,
            } },
            .ls => .{ .ls = .{ .store = store, .path = if (rest.len > 1) rest[1] else null } },
            .mount => .{ .mount = .{ .store = store, .directory = rest[1] } },
            .@"read-raw" => .{ .@"read-raw" = rest[0] },
        };
    }
};

fn report(io: std.Io, comptime format: []const u8, arguments: anytype) void {
    var writer = std.Io.File.stderr().writer(io, &.{});
    writer.interface.print(format, arguments) catch {};
    writer.interface.flush() catch {};
}

fn readInput(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) ![]u8 {
    const file = if (path) |name|
        try std.Io.Dir.cwd().openFile(io, name, .{ .mode = .read_only })
    else
        std.Io.File.stdin();
    defer if (path != null) file.close(io);

    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(fs_mod.max_file_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        error.ReadFailed => reader.err orelse err,
        else => err,
    };
}

fn writeOutput(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const is_stdout = std.mem.eql(u8, path, "-");
    const file = if (is_stdout)
        std.Io.File.stdout()
    else
        try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer if (!is_stdout) file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// Only the returned slice is allocated; its components borrow from path.
fn splitPath(gpa: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var components: std.ArrayList([]const u8) = .empty;
    errdefer components.deinit(gpa);

    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0) continue;
        try components.append(gpa, component);
    }

    return components.toOwnedSlice(gpa);
}

fn put(gpa: std.mem.Allocator, io: std.Io, store: []const u8, input: []const u8) !void {
    const bytes = try readInput(gpa, io, if (std.mem.eql(u8, input, "-")) null else input);
    defer gpa.free(bytes);

    var fs = try Fs.open(gpa, io, store);
    defer fs.deinit();

    const name = std.fs.path.basename(input);
    _ = try fs.createFileWith(.root, name, bytes);
    try fs.commit();

    report(io, "stored {s} as {s}: {d} bytes\n", .{ input, name, bytes.len });
}

fn get(gpa: std.mem.Allocator, io: std.Io, store: []const u8, path: []const u8, output: ?[]const u8) !void {
    var fs = try Fs.open(gpa, io, store);
    defer fs.deinit();

    const components = try splitPath(gpa, path);
    defer gpa.free(components);

    const id = try fs.resolve(.root, components);
    const bytes = try fs.readFile(id);
    defer gpa.free(bytes);

    try writeOutput(io, output orelse std.fs.path.basename(path), bytes);
}

fn ls(gpa: std.mem.Allocator, io: std.Io, store: []const u8, path: ?[]const u8) !void {
    var fs = try Fs.open(gpa, io, store);
    defer fs.deinit();

    var id = fs_mod.NodeId.root;
    if (path) |text| {
        const components = try splitPath(gpa, text);
        defer gpa.free(components);
        id = try fs.resolve(.root, components);
    }

    const entry = try fs.stat(id);
    if (entry.kind == .file) {
        report(io, "{s}\n", .{entry.name});
        return;
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    var children = try fs.children(id);
    while (children.next()) |child| {
        switch (child.kind) {
            .directory => try out.print("{s}/\n", .{child.name}),
            .file => |content| {
                const metadata = fs.writer.metadata(content) orelse continue;
                try out.print("{s:<6}  {d:>12}\n", .{ child.name, metadata.byte_len });
            },
        }
    }

    try out.flush();
}

fn mount(gpa: std.mem.Allocator, io: std.Io, store: []const u8, directory: []const u8, exe_path: []const u8) !void {
    var fs = try Fs.open(gpa, io, store);
    defer fs.deinit();

    try vfs.Mount(Fs).run(gpa, io, &fs, directory, exe_path);
}

pub fn main(init: std.process.Init) void {
    // The mount path frees and reallocates across its lifetime, so it needs a
    // general-purpose allocator rather than the process arena.
    const gpa = init.gpa;
    const io = init.io;

    // Arguments live for the whole process, so the arena owns them; the
    // general-purpose allocator is for work that actually frees.
    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        report(io, "tfs: could not read arguments\n", .{});
        std.process.exit(1);
    };

    const request = Request.parse(arguments) catch |err| {
        report(io, "{s}", .{usage_text});
        report(io, "tfs: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    run(gpa, io, request, arguments[0]) catch |err| {
        report(io, "tfs: {s}\n", .{errorMessage(err)});
        std.process.exit(1);
    };
}

fn run(gpa: std.mem.Allocator, io: std.Io, request: Request, exe_path: []const u8) !void {
    switch (request) {
        .put => |p| try put(gpa, io, p.store, p.input),
        .get => |g| try get(gpa, io, g.store, g.path, g.output),
        .ls => |l| try ls(gpa, io, l.store, l.path),
        .mount => |m| try mount(gpa, io, m.store, m.directory, exe_path),
        .@"read-raw" => |path| try readRaw(gpa, io, path),
    }
}

fn readRaw(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    if (std.mem.eql(u8, path, "--serve")) return serveReader(gpa, io);

    const bytes = try readInput(gpa, io, path);
    defer gpa.free(bytes);
    try writeOutput(io, "-", bytes);
}

// Consume exactly one request, including an overlong line, without losing any
// following request already buffered by the reader.
fn readCapturePath(reader: *std.Io.Reader, buffer: []u8) !?[]const u8 {
    var total: usize = 0;
    var overflow = false;
    while (true) {
        const byte = reader.takeByte() catch |err| {
            if (err == error.EndOfStream and total == 0 and !overflow) return null;
            return err;
        };
        if (byte == '\n') {
            if (overflow) return error.NameTooLong;
            const path = buffer[0..total];
            if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidName;
            return path;
        }
        if (total == buffer.len) {
            overflow = true;
        } else {
            buffer[total] = byte;
            total += 1;
        }
    }
}

fn serveReader(gpa: std.mem.Allocator, io: std.Io) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var io_buffer: [4096]u8 = undefined;
    var reader = stdin.reader(io, &io_buffer);
    var path_buffer: [4095]u8 = undefined;

    while (true) {
        const result = blk: {
            const path = readCapturePath(&reader.interface, &path_buffer) catch |err| switch (err) {
                error.NameTooLong, error.InvalidName => break :blk err,
                else => return err,
            };
            break :blk readInput(gpa, io, path orelse return);
        };
        defer if (result) |bytes| gpa.free(bytes) else |_| {};

        // The status distinguishes an empty file from a failed read.
        var header: [5]u8 = undefined;
        header[0] = if (result) |_| 0 else |_| 1;
        const payload: []const u8 = result catch |err| @errorName(err);
        std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
        var writer = stdout.writer(io, &.{});
        try writer.interface.writeAll(&header);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
    }
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "store or file not found",
        error.AccessDenied => "permission denied",
        error.UnknownNode, error.NotFound => "no such path in the filesystem",
        error.NotDirectory => "path component is not a directory",
        error.IsDirectory => "path is a directory",
        error.AlreadyExists => "an entry with that name already exists",
        error.DirectoryNotEmpty => "directory not empty",
        error.FileOpen => "file is open; close handles before removing",
        error.InvalidName => "invalid name",
        error.FileTooLarge => std.fmt.comptimePrint(
            "file exceeds the {d} byte limit",
            .{fs_mod.max_file_bytes},
        ),
        error.HashCollision => "two different contents hash to the same value; refusing to store",
        error.RollbackFailed => "a failed write could not be rolled back; the store may be inconsistent",
        error.WriterPoisoned => "store writer is unusable after a failed write; reopen the store",
        error.DataSizeMismatch => "data file size does not match the index; refusing to open",
        error.InvalidIndex => "index file is corrupt",
        error.InvalidSnapshot => "namespace snapshot is corrupt",
        error.UnsupportedPlatform => "mount requires Windows (ProjFS)",
        error.ProjFsUnavailable => "ProjFS not available; run as admin: Enable-WindowsOptionalFeature -Online -FeatureName Client-ProjFS",
        error.ProjFsSymbolMissing => "ProjectedFSLib.dll is missing an expected export (unsupported Windows build)",
        error.MountStartFailed => "could not start virtualization (details above; root must be an empty local NTFS folder)",
        error.BrokenPipe => "output pipe closed",
        else => @errorName(err),
    };
}

test "parse accepts put, get, ls, and mount" {
    const put_argv = [_][:0]const u8{ "tfs", "put", "store.tfs", "input.bin" };
    const put_req = try Request.parse(&put_argv);
    try std.testing.expect(put_req == .put);
    try std.testing.expectEqualStrings("store.tfs", put_req.put.store);
    try std.testing.expectEqualStrings("input.bin", put_req.put.input);

    const get_argv = [_][:0]const u8{ "tfs", "get", "store.tfs", "docs/a.txt", "-" };
    const get_req = try Request.parse(&get_argv);
    try std.testing.expect(get_req == .get);
    try std.testing.expectEqualStrings("docs/a.txt", get_req.get.path);
    try std.testing.expectEqualStrings("-", get_req.get.output.?);

    const ls_argv = [_][:0]const u8{ "tfs", "ls", "store.tfs" };
    const ls_req = try Request.parse(&ls_argv);
    try std.testing.expect(ls_req == .ls);
    try std.testing.expect(ls_req.ls.path == null);

    const mount_argv = [_][:0]const u8{ "tfs", "mount", "store.tfs", "mnt" };
    const mount_req = try Request.parse(&mount_argv);
    try std.testing.expect(mount_req == .mount);
    try std.testing.expectEqualStrings("mnt", mount_req.mount.directory);
}

test "splitPath borrows components and skips empty separators" {
    const gpa = std.testing.allocator;
    const path = "/docs//notes/file.txt/";
    const components = try splitPath(gpa, path);
    defer gpa.free(components);

    try std.testing.expectEqual(@as(usize, 3), components.len);
    try std.testing.expectEqualStrings("docs", components[0]);
    try std.testing.expectEqualStrings("notes", components[1]);
    try std.testing.expectEqualStrings("file.txt", components[2]);
    try std.testing.expect(components[0].ptr == path[1..].ptr);

    const root = try splitPath(gpa, "///");
    defer gpa.free(root);
    try std.testing.expectEqual(@as(usize, 0), root.len);
}

test "parse accepts optional paths and the capture helper command" {
    const get_req = try Request.parse(&.{ "tfs", "get", "store.tfs", "docs/file.txt" });
    try std.testing.expectEqualStrings("store.tfs", get_req.get.store);
    try std.testing.expect(get_req.get.output == null);

    const ls_req = try Request.parse(&.{ "tfs", "ls", "store.tfs", "docs" });
    try std.testing.expectEqualStrings("store.tfs", ls_req.ls.store);
    try std.testing.expectEqualStrings("docs", ls_req.ls.path.?);

    const helper_req = try Request.parse(&.{ "tfs", "read-raw", "--serve" });
    try std.testing.expectEqualStrings("--serve", helper_req.@"read-raw");
}

test "capture requests preserve coalesced lines and recover after invalid paths" {
    var reader: std.Io.Reader = .fixed("abc\ntoolong\nok\na\x00b\nz\n");
    var buffer: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", (try readCapturePath(&reader, &buffer)).?);
    try std.testing.expectError(error.NameTooLong, readCapturePath(&reader, &buffer));
    try std.testing.expectEqualStrings("ok", (try readCapturePath(&reader, &buffer)).?);
    try std.testing.expectError(error.InvalidName, readCapturePath(&reader, &buffer));
    try std.testing.expectEqualStrings("z", (try readCapturePath(&reader, &buffer)).?);
    try std.testing.expectEqual(null, try readCapturePath(&reader, &buffer));

    var partial: std.Io.Reader = .fixed("abc");
    try std.testing.expectError(error.EndOfStream, readCapturePath(&partial, &buffer));
    var overlong: std.Io.Reader = .fixed("abcd");
    try std.testing.expectError(error.EndOfStream, readCapturePath(&overlong, &buffer));
}

test "parse rejects malformed commands" {
    try std.testing.expectError(error.MissingCommand, Request.parse(&[_][:0]const u8{}));

    const bad_command = [_][:0]const u8{ "tfs", "frobnicate" };
    try std.testing.expectError(error.InvalidCommand, Request.parse(&bad_command));

    const short_put = [_][:0]const u8{ "tfs", "put", "store.tfs" };
    try std.testing.expectError(error.MissingArgument, Request.parse(&short_put));

    const extra_ls = [_][:0]const u8{ "tfs", "ls", "a", "b", "c" };
    try std.testing.expectError(error.TooManyArguments, Request.parse(&extra_ls));

    const piped_store = [_][:0]const u8{ "tfs", "put", "-", "f" };
    try std.testing.expectError(error.StorePipe, Request.parse(&piped_store));
}
