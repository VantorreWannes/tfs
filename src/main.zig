const std = @import("std");
const tfs = @import("root.zig");

const Hash = u128;
const fanout = 16;

const Config = tfs.TreeConfig(Hash, fanout);
const IndexFile = tfs.TreeIndexFile(Config);
const TreeFileWriter = tfs.TreeFileWriter(Config);
const TreeFileReader = tfs.TreeFileReader(Config);
const ContentId = tfs.ContentId;

const max_input_bytes: usize = 1 << 30;
const stdio_path = "-";

const usage_text =
    \\usage:
    \\  tfs encode <store> <file>
    \\  tfs decode <store> <id> <file>
    \\  tfs list <store>
    \\
    \\  <store>  data file, index kept beside it as <store>.idx
    \\  <id>     content id printed by encode or shown by list
    \\  <file>   "-" reads stdin (encode) or writes stdout (decode)
    \\
;

const Request = struct {
    store: []const u8,
    action: Action,

    const Action = union(enum) {
        encode: []const u8,
        decode: struct { id: ContentId, file: []const u8 },
        list,
    };

    const ParseError = error{
        MissingCommand,
        InvalidCommand,
        MissingArgument,
        TooManyArguments,
        InvalidId,
        StorePipe,
    };

    fn parse(arguments: []const [:0]const u8) ParseError!Request {
        if (arguments.len < 2) return error.MissingCommand;

        const command = std.meta.stringToEnum(std.meta.Tag(Action), arguments[1]) orelse
            return error.InvalidCommand;
        const rest = arguments[2..];

        const expected: usize = switch (command) {
            .list => 1,
            .encode => 2,
            .decode => 3,
        };
        if (rest.len < expected) return error.MissingArgument;
        if (rest.len > expected) return error.TooManyArguments;

        const store: []const u8 = rest[0];
        if (std.mem.eql(u8, store, stdio_path)) return error.StorePipe;

        return .{
            .store = store,
            .action = switch (command) {
                .list => .list,
                .encode => .{ .encode = rest[1] },
                .decode => .{ .decode = .{ .id = try parseId(rest[1]), .file = rest[2] } },
            },
        };
    }

    fn parseId(text: []const u8) ParseError!ContentId {
        const position = std.fmt.parseInt(usize, text, 10) catch return error.InvalidId;
        return .fromIndex(position);
    }
};

const Access = enum { read_only, read_write };

fn openFile(io: std.Io, path: []const u8, access: Access) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    return switch (access) {
        .read_only => cwd.openFile(io, path, .{ .mode = .read_only }),
        .read_write => cwd.createFile(io, path, .{ .read = true, .truncate = false }),
    };
}

fn indexPath(gpa: std.mem.Allocator, store: []const u8) std.mem.Allocator.Error![]u8 {
    return std.mem.concat(gpa, u8, &.{ store, ".idx" });
}

const StoreFiles = struct {
    data: std.Io.File,
    index: std.Io.File,

    fn open(gpa: std.mem.Allocator, io: std.Io, store: []const u8, access: Access) !StoreFiles {
        const index_path = try indexPath(gpa, store);
        defer gpa.free(index_path);

        const data = try openFile(io, store, access);
        errdefer data.close(io);
        const index = try openFile(io, index_path, access);

        return .{ .data = data, .index = index };
    }

    fn close(self: StoreFiles, io: std.Io) void {
        self.index.close(io);
        self.data.close(io);
    }
};

fn report(io: std.Io, comptime format: []const u8, arguments: anytype) void {
    var writer = std.Io.File.stderr().writer(io, &.{});
    writer.interface.print(format, arguments) catch {};
    writer.interface.flush() catch {};
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(max_input_bytes));
}

fn writeFile(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    var writer = file.writer(io, &.{});
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn readInput(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, stdio_path)) return readFile(gpa, io, .stdin());

    const file = try openFile(io, path, .read_only);
    defer file.close(io);
    return readFile(gpa, io, file);
}

fn writeOutput(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, path, stdio_path)) return writeFile(io, .stdout(), bytes);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try writeFile(io, file, bytes);
}

fn encode(gpa: std.mem.Allocator, io: std.Io, store_path: []const u8, input: []const u8) !void {
    const bytes = try readInput(gpa, io, input);
    defer gpa.free(bytes);

    const files: StoreFiles = try .open(gpa, io, store_path, .read_write);
    defer files.close(io);

    var store = try TreeFileWriter.init(gpa, io, files.index, files.data);
    defer store.deinit();

    const words_before = store.index.count();
    const id = try store.put(bytes);
    const metadata = store.metadata(id).?;

    report(io, "encoded id {d}: {d} bytes, depth {d}, {d} new words, root {x}\n", .{
        id.index(),
        metadata.byte_len,
        metadata.root.depth,
        store.index.count() - words_before,
        metadata.root.hash,
    });
}

fn decode(
    gpa: std.mem.Allocator,
    io: std.Io,
    store_path: []const u8,
    id: ContentId,
    output: []const u8,
) !void {
    const files: StoreFiles = try .open(gpa, io, store_path, .read_only);
    defer files.close(io);

    var store = try TreeFileReader.init(gpa, io, files.index, files.data);
    defer store.deinit();

    const bytes = try store.get(gpa, id);
    defer gpa.free(bytes);

    try writeOutput(io, output, bytes);
}

fn list(gpa: std.mem.Allocator, io: std.Io, store_path: []const u8) !void {
    const index_path = try indexPath(gpa, store_path);
    defer gpa.free(index_path);

    const index_file = try openFile(io, index_path, .read_only);
    defer index_file.close(io);

    const catalog = try IndexFile.scan(gpa, io, index_file);
    defer gpa.free(catalog);

    try printCatalog(io, catalog);
}

fn printCatalog(io: std.Io, catalog: []const Config.Metadata) !void {
    const root_width = comptime std.fmt.comptimePrint("{d}", .{Config.hash_bytes * 2});

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    try out.print("{s:>6}  {s:>12}  {s:>5}  {s:>" ++ root_width ++ "}\n", .{
        "id", "size", "depth", "root",
    });

    for (catalog, 0..) |metadata, position| {
        try out.print("{d:>6}  {d:>12}  {d:>5}  {x:0>" ++ root_width ++ "}\n", .{
            position,
            metadata.byte_len,
            metadata.root.depth,
            metadata.root.hash,
        });
    }

    try out.flush();
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingCommand, error.InvalidCommand => "missing or invalid command",
        error.MissingArgument => "missing argument",
        error.TooManyArguments => "too many arguments",
        error.InvalidId => "id must be a non-negative integer",
        error.StorePipe => "store must be a path; only <file> may be \"-\"",
        error.UnknownContentId => "no content with that id",
        error.DataSizeMismatch => "data file size does not match the index; refusing to open",
        error.InvalidIndex => "index file is corrupt",
        error.MissingWord, error.DataTruncated => "data file is missing words the index refers to",
        error.FileNotFound => "store or file not found",
        error.AccessDenied => "permission denied (OneDrive sync or antivirus may be blocking writes)",
        error.StreamTooLong => "input exceeds 1 GiB read limit",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}

fn run(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(gpa);

    const request = Request.parse(arguments) catch |err| {
        report(io, "{s}", .{usage_text});
        return err;
    };

    switch (request.action) {
        .encode => |file| try encode(gpa, io, request.store, file),
        .decode => |target| try decode(gpa, io, request.store, target.id, target.file),
        .list => try list(gpa, io, request.store),
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        report(init.io, "tfs: {s}\n", .{errorMessage(err)});
        std.process.exit(1);
    };
}
