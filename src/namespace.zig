const std = @import("std");
const tfs = @import("tfs");

pub const NodeId = enum(u64) {
    root = 0,
    _,
};

pub const Entry = struct {
    id: NodeId,
    parent: NodeId,
    name: []const u8,
    kind: Kind,

    pub const Kind = union(enum) {
        directory,
        file: tfs.ContentId,
    };
};

pub const ByteNames = struct {
    pub fn valid(name: []const u8) bool {
        return name.len != 0 and
            !std.mem.eql(u8, name, ".") and
            !std.mem.eql(u8, name, "..") and
            std.mem.indexOfScalar(u8, name, 0) == null and
            std.mem.indexOfScalar(u8, name, '/') == null;
    }

    pub fn equal(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

pub fn Namespace(comptime Names: type) type {
    return struct {
        const Self = @This();
        const magic = "TFSNS\x00\x01\x00";

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
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(?Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self: Self = .{ .allocator = allocator };
            const name = try allocator.dupe(u8, "");
            errdefer allocator.free(name);
            try self.nodes.append(allocator, .{
                .id = .root,
                .parent = .root,
                .name = name,
                .kind = .directory,
            });
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes.items) |maybe_entry| {
                if (maybe_entry) |entry| self.allocator.free(entry.name);
            }
            self.nodes.deinit(self.allocator);
            self.* = undefined;
        }

        fn position(self: *const Self, id: NodeId) Error!usize {
            const index = std.math.cast(usize, @intFromEnum(id)) orelse return error.UnknownNode;
            if (index >= self.nodes.items.len or self.nodes.items[index] == null)
                return error.UnknownNode;
            return index;
        }

        pub fn stat(self: *const Self, id: NodeId) Error!Entry {
            return self.nodes.items[try self.position(id)].?;
        }

        fn requireDirectory(self: *const Self, id: NodeId) Error!void {
            if ((try self.stat(id)).kind != .directory) return error.NotDirectory;
        }

        fn child(self: *const Self, parent: NodeId, name: []const u8) ?NodeId {
            for (self.nodes.items) |maybe_entry| {
                const entry = maybe_entry orelse continue;
                if (entry.id != .root and entry.parent == parent and Names.equal(entry.name, name))
                    return entry.id;
            }
            return null;
        }

        pub fn lookup(self: *const Self, parent: NodeId, name: []const u8) Error!NodeId {
            try self.requireDirectory(parent);
            if (!Names.valid(name)) return error.InvalidName;
            return self.child(parent, name) orelse error.NotFound;
        }

        pub fn resolve(self: *const Self, start: NodeId, components: []const []const u8) Error!NodeId {
            _ = try self.stat(start);
            var id = start;
            for (components) |name| id = try self.lookup(id, name);
            return id;
        }

        pub const Iterator = struct {
            namespace: *const Self,
            parent: NodeId,
            cursor: usize = 1,

            pub fn next(self: *Iterator) ?Entry {
                while (self.cursor < self.namespace.nodes.items.len) {
                    const position_ = self.cursor;
                    self.cursor += 1;
                    const entry = self.namespace.nodes.items[position_] orelse continue;
                    if (entry.parent == self.parent) return entry;
                }
                return null;
            }
        };

        pub fn children(self: *const Self, parent: NodeId) Error!Iterator {
            try self.requireDirectory(parent);
            return .{ .namespace = self, .parent = parent };
        }

        fn create(self: *Self, parent: NodeId, name: []const u8, kind: Entry.Kind) !NodeId {
            try self.requireDirectory(parent);
            if (!Names.valid(name)) return error.InvalidName;
            if (self.child(parent, name) != null) return error.AlreadyExists;
            const index = std.math.cast(u64, self.nodes.items.len) orelse return error.IdExhausted;
            if (self.nodes.items.len == std.math.maxInt(usize)) return error.IdExhausted;
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const id: NodeId = @enumFromInt(index);
            try self.nodes.append(self.allocator, .{
                .id = id,
                .parent = parent,
                .name = owned_name,
                .kind = kind,
            });
            return id;
        }

        pub fn createDirectory(self: *Self, parent: NodeId, name: []const u8) !NodeId {
            return self.create(parent, name, .directory);
        }

        pub fn createFile(self: *Self, parent: NodeId, name: []const u8, content: tfs.ContentId) !NodeId {
            return self.create(parent, name, .{ .file = content });
        }

        pub fn setContent(self: *Self, id: NodeId, content: tfs.ContentId) Error!void {
            const index = try self.position(id);
            if (self.nodes.items[index].?.kind != .file) return error.IsDirectory;
            self.nodes.items[index].?.kind = .{ .file = content };
        }

        pub fn move(self: *Self, id: NodeId, parent: NodeId, name: []const u8) !void {
            const index = try self.position(id);
            if (id == .root) return error.RootImmutable;
            try self.requireDirectory(parent);
            if (!Names.valid(name)) return error.InvalidName;
            if (self.child(parent, name)) |existing| {
                if (existing != id) return error.AlreadyExists;
            }

            var ancestor = parent;
            while (ancestor != .root) {
                if (ancestor == id) return error.Cycle;
                ancestor = (try self.stat(ancestor)).parent;
            }

            const owned_name = try self.allocator.dupe(u8, name);
            const entry = &self.nodes.items[index].?;
            self.allocator.free(entry.name);
            entry.name = owned_name;
            entry.parent = parent;
        }

        pub fn remove(self: *Self, id: NodeId) Error!void {
            const index = try self.position(id);
            if (id == .root) return error.RootImmutable;
            if (self.nodes.items[index].?.kind == .directory) {
                var iterator = try self.children(id);
                if (iterator.next() != null) return error.DirectoryNotEmpty;
            }
            self.allocator.free(self.nodes.items[index].?.name);
            self.nodes.items[index] = null;
        }

        pub fn encode(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
            var size: usize = magic.len + @sizeOf(u64);
            for (self.nodes.items) |maybe_entry| {
                size = try std.math.add(usize, size, 1);
                if (maybe_entry) |entry| {
                    size = try std.math.add(usize, size, 2 * @sizeOf(u64));
                    size = try std.math.add(usize, size, entry.name.len);
                    if (entry.kind == .file) size = try std.math.add(usize, size, @sizeOf(u64));
                }
            }
            const bytes = try allocator.alloc(u8, size);
            errdefer allocator.free(bytes);
            var writer: std.Io.Writer = .fixed(bytes);
            try writer.writeAll(magic);
            try writer.writeInt(u64, self.nodes.items.len, .little);
            for (self.nodes.items) |maybe_entry| {
                const entry = maybe_entry orelse {
                    try writer.writeByte(0);
                    continue;
                };
                try writer.writeByte(if (entry.kind == .directory) 1 else 2);
                try writer.writeInt(u64, @intFromEnum(entry.parent), .little);
                try writer.writeInt(u64, entry.name.len, .little);
                try writer.writeAll(entry.name);
                if (entry.kind == .file)
                    try writer.writeInt(u64, @intFromEnum(entry.kind.file), .little);
            }
            return bytes;
        }

        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Self {
            if (!std.mem.startsWith(u8, bytes, magic)) return error.InvalidSnapshot;
            var reader: std.Io.Reader = .fixed(bytes[magic.len..]);
            const count = std.math.cast(usize, reader.takeInt(u64, .little) catch return error.InvalidSnapshot) orelse
                return error.InvalidSnapshot;
            if (count == 0 or count > bytes.len - magic.len - @sizeOf(u64)) return error.InvalidSnapshot;

            var self: Self = .{ .allocator = allocator };
            errdefer self.deinit();
            for (0..count) |index| {
                const tag = reader.takeInt(u8, .little) catch return error.InvalidSnapshot;
                if (tag == 0) {
                    try self.nodes.append(allocator, null);
                    continue;
                }
                if (tag != 1 and tag != 2) return error.InvalidSnapshot;
                const parent: NodeId = @enumFromInt(reader.takeInt(u64, .little) catch return error.InvalidSnapshot);
                const len = std.math.cast(usize, reader.takeInt(u64, .little) catch return error.InvalidSnapshot) orelse
                    return error.InvalidSnapshot;
                if (len > reader.buffer.len - reader.seek) return error.InvalidSnapshot;
                const name = reader.take(len) catch return error.InvalidSnapshot;
                const kind: Entry.Kind = if (tag == 1) .directory else .{
                    .file = @enumFromInt(reader.takeInt(u64, .little) catch return error.InvalidSnapshot),
                };
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                try self.nodes.append(allocator, .{
                    .id = @enumFromInt(index),
                    .parent = parent,
                    .name = owned_name,
                    .kind = kind,
                });
            }
            if (reader.seek != reader.buffer.len) return error.InvalidSnapshot;
            try self.validate();
            return self;
        }

        fn validationOrder(self: *const Self, a: usize, b: usize) bool {
            const left = self.nodes.items[a].?;
            const right = self.nodes.items[b].?;
            if (left.parent != right.parent)
                return @intFromEnum(left.parent) < @intFromEnum(right.parent);
            if (Names == ByteNames) return std.mem.lessThan(u8, left.name, right.name);
            return a < b;
        }

        fn validate(self: *const Self) !void {
            const root = self.stat(.root) catch return error.InvalidSnapshot;
            if (root.parent != .root or root.name.len != 0 or root.kind != .directory)
                return error.InvalidSnapshot;
            var live_count: usize = 0;
            for (self.nodes.items[1..]) |maybe_entry| {
                const entry = maybe_entry orelse continue;
                if (!Names.valid(entry.name)) return error.InvalidSnapshot;
                self.requireDirectory(entry.parent) catch return error.InvalidSnapshot;
                live_count += 1;
            }

            // Sort only scratch indices: slot order determines persistent identities.
            const order = try self.allocator.alloc(usize, live_count);
            defer self.allocator.free(order);
            var cursor: usize = 0;
            for (self.nodes.items[1..], 1..) |maybe_entry, index| {
                if (maybe_entry == null) continue;
                order[cursor] = index;
                cursor += 1;
            }
            std.mem.sort(usize, order, self, validationOrder);
            var group_start: usize = 0;
            for (order, 0..) |index, i| {
                const entry = self.nodes.items[index].?;
                if (i == 0 or self.nodes.items[order[i - 1]].?.parent != entry.parent) {
                    group_start = i;
                    continue;
                }
                // Arbitrary Names.equal has no compatible ordering/hash contract.
                // Keep its original argument order and compare all earlier siblings.
                const start = if (Names == ByteNames) i - 1 else group_start;
                for (order[start..i]) |previous| {
                    if (Names.equal(self.nodes.items[previous].?.name, entry.name))
                        return error.InvalidSnapshot;
                }
            }

            const State = enum { unseen, visiting, rooted };
            const states = try self.allocator.alloc(State, self.nodes.items.len);
            defer self.allocator.free(states);
            @memset(states, .unseen);
            states[0] = .rooted;
            for (order) |index| {
                var ancestor = index;
                while (states[ancestor] == .unseen) {
                    states[ancestor] = .visiting;
                    ancestor = @intCast(@intFromEnum(self.nodes.items[ancestor].?.parent));
                }
                if (states[ancestor] == .visiting) return error.InvalidSnapshot;
                // Each node is visited at most twice, even with forward parent IDs.
                ancestor = index;
                while (states[ancestor] == .visiting) {
                    states[ancestor] = .rooted;
                    ancestor = @intCast(@intFromEnum(self.nodes.items[ancestor].?.parent));
                }
            }
        }
    };
}

test "namespace root starts as an empty directory" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const root = try ns.stat(.root);
    try std.testing.expectEqual(NodeId.root, root.id);
    try std.testing.expectEqual(NodeId.root, root.parent);
    try std.testing.expectEqualStrings("", root.name);
    try std.testing.expect(root.kind == .directory);

    var children = try ns.children(.root);
    try std.testing.expect(children.next() == null);
}

test "namespace resolves nested paths" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const docs = try ns.createDirectory(.root, "docs");
    const notes = try ns.createDirectory(docs, "notes");
    const file = try ns.createFile(notes, "hello.txt", .fromIndex(4));

    try std.testing.expectEqual(docs, try ns.resolve(.root, &.{"docs"}));
    try std.testing.expectEqual(notes, try ns.resolve(docs, &.{"notes"}));
    try std.testing.expectEqual(file, try ns.resolve(.root, &.{ "docs", "notes", "hello.txt" }));
    try std.testing.expectEqual(NodeId.root, try ns.resolve(.root, &.{}));

    const entry = try ns.stat(file);
    try std.testing.expectEqualStrings("hello.txt", entry.name);
    try std.testing.expectEqual(notes, entry.parent);
    try std.testing.expectEqual(tfs.ContentId.fromIndex(4), entry.kind.file);
}

test "namespace lists children in creation order" {
    const gpa = std.testing.allocator;
    var ns = try Namespace(ByteNames).init(gpa);
    defer ns.deinit();

    const a = try ns.createDirectory(.root, "a");
    const b = try ns.createFile(.root, "b", .fromIndex(0));
    _ = try ns.createDirectory(a, "hidden");

    var seen: std.ArrayList(NodeId) = .empty;
    defer seen.deinit(gpa);
    var children = try ns.children(.root);
    while (children.next()) |entry| try seen.append(gpa, entry.id);

    try std.testing.expectEqualSlices(NodeId, &.{ a, b }, seen.items);
}

test "namespace updates file content without changing identity" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const file = try ns.createFile(.root, "data", .fromIndex(1));
    try ns.setContent(file, .fromIndex(2));

    const entry = try ns.stat(file);
    try std.testing.expectEqual(tfs.ContentId.fromIndex(2), entry.kind.file);
    try std.testing.expectEqual(file, try ns.lookup(.root, "data"));
}

test "namespace moves keep identity and update paths" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const source = try ns.createDirectory(.root, "source");
    const target = try ns.createDirectory(.root, "target");
    const file = try ns.createFile(source, "old.txt", .fromIndex(3));

    try ns.move(file, target, "new.txt");
    try std.testing.expectEqual(file, try ns.resolve(.root, &.{ "target", "new.txt" }));

    var emptied = try ns.children(source);
    try std.testing.expect(emptied.next() == null);

    try ns.move(target, .root, "renamed");
    try std.testing.expectEqual(target, try ns.lookup(.root, "renamed"));
    try std.testing.expectEqual(file, try ns.resolve(.root, &.{ "renamed", "new.txt" }));
}

test "namespace moves directories together with their descendants" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const outer = try ns.createDirectory(.root, "outer");
    const inner = try ns.createDirectory(outer, "inner");
    const file = try ns.createFile(inner, "leaf", .fromIndex(5));
    const destination = try ns.createDirectory(.root, "destination");

    try ns.move(outer, destination, "outer");

    try std.testing.expectEqual(outer, try ns.resolve(.root, &.{ "destination", "outer" }));
    try std.testing.expectEqual(inner, try ns.resolve(outer, &.{"inner"}));
    try std.testing.expectEqual(file, try ns.resolve(.root, &.{ "destination", "outer", "inner", "leaf" }));

    const entry = try ns.stat(file);
    try std.testing.expectEqual(inner, entry.parent);
}

test "namespace removes entries and issues fresh identities" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const directory = try ns.createDirectory(.root, "d");
    const file = try ns.createFile(directory, "f", .fromIndex(0));

    try ns.remove(file);
    try ns.remove(directory);

    var children = try ns.children(.root);
    try std.testing.expect(children.next() == null);

    const next = try ns.createDirectory(.root, "d");
    try std.testing.expect(@intFromEnum(next) > @intFromEnum(file));
}

test "namespace stores names containing spaces and unicode" {
    var ns = try Namespace(ByteNames).init(std.testing.allocator);
    defer ns.deinit();

    const spaced = try ns.createFile(.root, "my file", .fromIndex(0));
    const unicode = try ns.createFile(.root, "héllo", .fromIndex(1));

    try std.testing.expectEqual(spaced, try ns.lookup(.root, "my file"));
    try std.testing.expectEqual(unicode, try ns.lookup(.root, "héllo"));
}

test "namespace supports case-insensitive name policies" {
    const FoldedNames = struct {
        pub const valid = ByteNames.valid;
        pub const equal = std.ascii.eqlIgnoreCase;
    };

    var ns = try Namespace(FoldedNames).init(std.testing.allocator);
    defer ns.deinit();

    const directory = try ns.createDirectory(.root, "Docs");
    try std.testing.expectEqual(directory, try ns.lookup(.root, "docs"));

    try ns.move(directory, .root, "docs");
    try std.testing.expectEqualStrings("docs", (try ns.stat(directory)).name);
}

fn testSnapshot(comptime Names: type, entries: []const ?Entry, valid: bool) !void {
    const NS = Namespace(Names);
    const gpa = std.testing.allocator;
    // Borrow fixture entries; only the decoded namespace owns names and slots.
    const source: NS = .{ .allocator = gpa, .nodes = .{ .items = @constCast(entries), .capacity = entries.len } };
    const bytes = try source.encode(gpa);
    defer gpa.free(bytes);
    if (!valid) {
        try std.testing.expectError(error.InvalidSnapshot, NS.decode(gpa, bytes));
        return;
    }
    var restored = try NS.decode(gpa, bytes);
    defer restored.deinit();
    const again = try restored.encode(gpa);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
    for (entries, 0..) |entry, index| {
        const id: NodeId = @enumFromInt(index);
        if (entry != null) {
            try std.testing.expectEqual(id, (try restored.stat(id)).id);
        } else {
            try std.testing.expectError(error.UnknownNode, restored.stat(id));
        }
    }
    const next = try restored.createDirectory(.root, "fresh-node");
    try std.testing.expectEqual(entries.len, @intFromEnum(next));
}

test "namespace snapshots validate deep forward and backward parent chains" {
    const entries = try std.testing.allocator.alloc(?Entry, 4096);
    defer std.testing.allocator.free(entries);
    entries[0] = .{ .id = .root, .parent = .root, .name = "", .kind = .directory };
    for (entries[1..], 1..) |*entry, index| {
        entry.* = .{ .id = @enumFromInt(index), .parent = @enumFromInt(index - 1), .name = "same", .kind = .directory };
    }
    try testSnapshot(ByteNames, entries, true);
    for (entries[1..], 1..) |*entry, index| {
        entry.*.?.parent = @enumFromInt(if (index + 1 == entries.len) 0 else index + 1);
    }
    try testSnapshot(ByteNames, entries, true);
    entries[entries.len - 1].?.parent = @enumFromInt(entries.len / 2);
    try testSnapshot(ByteNames, entries, false);
}

test "namespace snapshots validate wide directories and nonadjacent duplicates" {
    var entries: [1025]?Entry = undefined;
    var names: [1024][20]u8 = undefined;
    entries[0] = .{ .id = .root, .parent = .root, .name = "", .kind = .directory };
    for (entries[1..], &names, 1..) |*entry, *name, index| {
        entry.* = .{
            .id = @enumFromInt(index),
            .parent = .root,
            .name = try std.fmt.bufPrint(name, "name-{d}", .{entries.len - index}),
            .kind = .{ .file = .fromIndex(index) },
        };
    }
    try testSnapshot(ByteNames, &entries, true);
    entries[entries.len - 1].?.name = entries[1].?.name;
    try testSnapshot(ByteNames, &entries, false);
}

test "namespace snapshots reject invalid roots parents names and cycles" {
    const root: Entry = .{ .id = .root, .parent = .root, .name = "", .kind = .directory };
    const child_entry: Entry = .{ .id = @enumFromInt(1), .parent = .root, .name = "child", .kind = .directory };
    try testSnapshot(ByteNames, &.{root}, true);
    try testSnapshot(ByteNames, &.{ root, null, child_entry, null }, true);
    try testSnapshot(ByteNames, &.{}, false);
    try testSnapshot(ByteNames, &.{null}, false);
    var invalid_root = root;
    invalid_root.parent = @enumFromInt(1);
    try testSnapshot(ByteNames, &.{ invalid_root, child_entry }, false);
    invalid_root = root;
    invalid_root.name = "root";
    try testSnapshot(ByteNames, &.{invalid_root}, false);
    invalid_root = root;
    invalid_root.kind = .{ .file = .fromIndex(0) };
    try testSnapshot(ByteNames, &.{invalid_root}, false);
    for ([_][]const u8{ "", ".", "..", "a/b", "a\x00b" }) |name| {
        var child = child_entry;
        child.name = name;
        try testSnapshot(ByteNames, &.{ root, child }, false);
    }
    for ([_]u64{ 1, 2, std.math.maxInt(u64) }) |parent| {
        var child = child_entry;
        child.parent = @enumFromInt(parent);
        try testSnapshot(ByteNames, &.{ root, child, null }, false);
    }
    var a = child_entry;
    a.parent = @enumFromInt(2);
    var b: Entry = .{ .id = @enumFromInt(2), .parent = .root, .name = "other", .kind = .{ .file = .fromIndex(0) } };
    try testSnapshot(ByteNames, &.{ root, a, b }, false);
    b.kind = .directory;
    b.parent = @enumFromInt(1);
    try testSnapshot(ByteNames, &.{ root, a, b }, false);
}

test "namespace snapshot validation preserves custom name equality" {
    const FoldedNames = struct {
        pub const valid = ByteNames.valid;
        pub const equal = std.ascii.eqlIgnoreCase;
    };
    const LengthNames = struct {
        pub const valid = ByteNames.valid;
        pub fn equal(a: []const u8, b: []const u8) bool {
            return a.len == b.len;
        }
    };
    const root: Entry = .{ .id = .root, .parent = .root, .name = "", .kind = .directory };
    var entries = [_]?Entry{
        root,
        .{ .id = @enumFromInt(1), .parent = .root, .name = "Docs", .kind = .directory },
        null,
        .{ .id = @enumFromInt(3), .parent = .root, .name = "between", .kind = .directory },
        .{ .id = @enumFromInt(4), .parent = .root, .name = "docs", .kind = .{ .file = .fromIndex(7) } },
    };
    try testSnapshot(ByteNames, &entries, true);
    try testSnapshot(FoldedNames, &entries, false);
    entries[4].?.name = "else";
    try testSnapshot(FoldedNames, &entries, true);
    try testSnapshot(LengthNames, &entries, false);
    entries[4].?.parent = @enumFromInt(1);
    try testSnapshot(LengthNames, &entries, true);
    entries[4].?.name = "Docs";
    try testSnapshot(ByteNames, &entries, true);
    try testSnapshot(FoldedNames, &entries, true);
}

test "namespace snapshot validation retains custom equality argument order" {
    const PrefixNames = struct {
        pub const valid = ByteNames.valid;
        pub fn equal(a: []const u8, b: []const u8) bool {
            return std.mem.startsWith(u8, b, a);
        }
    };
    var entries = [_]?Entry{
        .{ .id = .root, .parent = .root, .name = "", .kind = .directory },
        .{ .id = @enumFromInt(1), .parent = .root, .name = "prefix-long", .kind = .directory },
        .{ .id = @enumFromInt(2), .parent = .root, .name = "prefix", .kind = .directory },
    };
    try testSnapshot(PrefixNames, &entries, true);
    std.mem.swap([]const u8, &entries[1].?.name, &entries[2].?.name);
    try testSnapshot(PrefixNames, &entries, false);
}

test "namespace snapshots reject truncation and trailing bytes" {
    const gpa = std.testing.allocator;
    const NS = Namespace(ByteNames);
    var ns = try NS.init(gpa);
    defer ns.deinit();
    _ = try ns.createFile(.root, "file", .fromIndex(8));
    const bytes = try ns.encode(gpa);
    defer gpa.free(bytes);
    for (0..bytes.len) |len| {
        try std.testing.expectError(error.InvalidSnapshot, NS.decode(gpa, bytes[0..len]));
    }
    const trailing = try std.mem.concat(gpa, u8, &.{ bytes, &.{0} });
    defer gpa.free(trailing);
    try std.testing.expectError(error.InvalidSnapshot, NS.decode(gpa, trailing));
    bytes[0] ^= 1;
    try std.testing.expectError(error.InvalidSnapshot, NS.decode(gpa, bytes));
}

fn testSnapshotAllocationFailures(allocator: std.mem.Allocator, bytes: []const u8, valid: bool) !void {
    var restored = Namespace(ByteNames).decode(allocator, bytes) catch |err| {
        if (!valid and err == error.InvalidSnapshot) return;
        return err;
    };
    defer restored.deinit();
    try std.testing.expect(valid);
}

test "namespace snapshot validation cleans up allocation failures" {
    const gpa = std.testing.allocator;
    var ns = try Namespace(ByteNames).init(gpa);
    defer ns.deinit();
    const a = try ns.createDirectory(.root, "a");
    const b = try ns.createDirectory(a, "b");
    const bytes = try ns.encode(gpa);
    defer gpa.free(bytes);
    try std.testing.checkAllAllocationFailures(gpa, testSnapshotAllocationFailures, .{ bytes, true });
    ns.nodes.items[@intFromEnum(a)].?.parent = b;
    const cyclic = try ns.encode(gpa);
    defer gpa.free(cyclic);
    try std.testing.checkAllAllocationFailures(gpa, testSnapshotAllocationFailures, .{ cyclic, false });
}

test "namespace snapshots round trip identities and content" {
    const gpa = std.testing.allocator;
    const NS = Namespace(ByteNames);

    var ns = try NS.init(gpa);
    defer ns.deinit();

    const removed = try ns.createDirectory(.root, "removed");
    const file = try ns.createFile(.root, "file", .fromIndex(123));
    const directory = try ns.createDirectory(.root, "later-parent");
    try ns.move(file, directory, "file");
    try ns.remove(removed);

    const bytes = try ns.encode(gpa);
    defer gpa.free(bytes);

    var restored = try NS.decode(gpa, bytes);
    defer restored.deinit();

    try std.testing.expectEqual(file, try restored.resolve(.root, &.{ "later-parent", "file" }));
    try std.testing.expectEqual(tfs.ContentId.fromIndex(123), (try restored.stat(file)).kind.file);

    var children = try restored.children(.root);
    try std.testing.expectEqual(directory, children.next().?.id);
    try std.testing.expect(children.next() == null);

    const again = try restored.encode(gpa);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);

    const next = try restored.createDirectory(.root, "new");
    try std.testing.expect(@intFromEnum(next) > @intFromEnum(directory));
}
