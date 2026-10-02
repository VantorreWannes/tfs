const std = @import("std");
const builtin = @import("builtin");

pub const Mount = switch (builtin.os.tag) {
    .linux => Linux.Mount,
    else => Unsupported.Mount,
};

const Unsupported = struct {
    pub fn Mount(comptime Archive: type) type {
        return opaque {
            const Self = @This();

            pub fn start(
                _: std.mem.Allocator,
                _: *Archive,
                _: []const u8,
            ) error{UnsupportedPlatform}!*Self {
                return error.UnsupportedPlatform;
            }

            pub fn stop(_: *Self) ?anyerror {
                unreachable;
            }
        };
    }
};

fn encodeDirent(
    buffer: []u8,
    node_id: u64,
    cookie: u64,
    name: []const u8,
    is_directory: bool,
) ?usize {
    const header_size = 24;
    const alignment = 8;

    if (buffer.len < header_size) return null;
    if (name.len > buffer.len - header_size) return null;

    const total = header_size + name.len;
    const padding = (alignment - total % alignment) % alignment;

    if (padding > buffer.len - total) return null;

    const padded = total + padding;

    std.mem.writeInt(u64, buffer[0..8], node_id, .native);
    std.mem.writeInt(u64, buffer[8..16], cookie, .native);
    std.mem.writeInt(u32, buffer[16..20], @intCast(name.len), .native);
    std.mem.writeInt(
        u32,
        buffer[20..24],
        if (is_directory) 4 else 8,
        .native,
    );

    @memcpy(buffer[header_size..][0..name.len], name);
    @memset(buffer[total..padded], 0);

    return padded;
}

const Namespace = struct {
    const root_id: u64 = 1;
    const Children = std.StringArrayHashMapUnmanaged(u64);

    const Node = struct {
        name: []u8,
        parent: u64,
        data: union(enum) {
            directory: Children,
            file: usize,
        },

        fn isDirectory(self: *const Node) bool {
            return self.data == .directory;
        }
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    fn deinit(self: *Namespace) void {
        for (self.nodes.items) |*item| {
            switch (item.data) {
                .directory => |*children| children.deinit(self.allocator),
                .file => {},
            }

            self.allocator.free(item.name);
        }

        self.nodes.deinit(self.allocator);
    }

    fn node(self: *Namespace, id: u64) ?*Node {
        if (id == 0 or id > self.nodes.items.len) return null;
        return &self.nodes.items[@intCast(id - 1)];
    }

    fn lookup(
        self: *Namespace,
        parent: u64,
        name: []const u8,
    ) ?u64 {
        const directory = self.node(parent) orelse return null;

        return switch (directory.data) {
            .directory => |*children| children.get(name),
            .file => null,
        };
    }

    fn build(
        allocator: std.mem.Allocator,
        archive: anytype,
    ) !Namespace {
        var self = Namespace{ .allocator = allocator };
        errdefer self.deinit();

        try self.nodes.ensureUnusedCapacity(allocator, 1);

        const root_name = try allocator.dupe(u8, "");

        self.nodes.appendAssumeCapacity(.{
            .name = root_name,
            .parent = root_id,
            .data = .{ .directory = .{} },
        });

        var entry_index: usize = 0;

        while (archive.entryAt(entry_index)) |entry| : (entry_index += 1) {
            var parent = root_id;
            var components = std.mem.splitScalar(u8, entry.path, '/');
            var component = components.next() orelse
                return error.InvalidNamespace;

            while (true) {
                if (component.len == 0 or
                    std.mem.eql(u8, component, ".") or
                    std.mem.eql(u8, component, "..") or
                    std.mem.indexOfScalar(u8, component, 0) != null)
                {
                    return error.InvalidNamespace;
                }

                const next = components.next();

                parent = try self.intern(
                    parent,
                    component,
                    if (next != null)
                        .{ .directory = .{} }
                    else
                        .{ .file = entry_index },
                );

                component = next orelse break;
            }
        }

        return self;
    }

    fn intern(
        self: *Namespace,
        parent: u64,
        name: []const u8,
        data: @FieldType(Node, "data"),
    ) !u64 {
        const directory = self.node(parent) orelse
            return error.InvalidNamespace;

        if (!directory.isDirectory()) return error.InvalidNamespace;

        if (directory.data.directory.get(name)) |existing| {
            const existing_node = self.node(existing).?;

            if (data != .directory or !existing_node.isDirectory()) {
                return error.InvalidNamespace;
            }

            return existing;
        }

        try self.nodes.ensureUnusedCapacity(self.allocator, 1);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const id: u64 = @intCast(self.nodes.items.len + 1);

        try self.node(parent).?.data.directory.put(
            self.allocator,
            owned_name,
            id,
        );

        self.nodes.appendAssumeCapacity(.{
            .name = owned_name,
            .parent = parent,
            .data = data,
        });

        return id;
    }
};

const Linux = struct {
    const E = std.os.linux.E;
    const max_read = 128 * 1024;
    const read_buffer_size = max_read + 4096;
    const protocol_major = 7;
    const protocol_minor = 28;

    const C = struct {
        const PollFd = extern struct {
            fd: c_int,
            events: c_short,
            revents: c_short,
        };

        const IoVec = extern struct {
            base: *anyopaque,
            len: usize,
        };

        const Message = extern struct {
            name: ?*anyopaque = null,
            namelen: u32 = 0,
            iov: [*]IoVec,
            iovlen: usize,
            control: ?*anyopaque,
            controllen: usize,
            flags: c_int = 0,
        };

        const ControlHeader = extern struct {
            len: usize,
            level: c_int,
            kind: c_int,
        };

        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn read(fd: c_int, buffer: [*]u8, len: usize) isize;
        extern "c" fn write(fd: c_int, buffer: [*]const u8, len: usize) isize;
        extern "c" fn poll(fds: [*]PollFd, count: usize, timeout: c_int) c_int;

        extern "c" fn socketpair(
            domain: c_int,
            kind: c_int,
            protocol: c_int,
            fds: *[2]c_int,
        ) c_int;

        extern "c" fn recvmsg(
            fd: c_int,
            message: *Message,
            flags: c_int,
        ) isize;

        extern "c" fn fork() c_int;
        extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;

        extern "c" fn execve(
            path: [*:0]const u8,
            argv: [*:null]const ?[*:0]const u8,
            envp: [*:null]const ?[*:0]const u8,
        ) c_int;

        extern "c" fn _exit(status: c_int) noreturn;
        extern "c" fn __errno_location() *c_int;
        extern "c" fn geteuid() c_uint;
        extern "c" fn getegid() c_uint;

        extern "c" var environ: [*:null]?[*:0]u8;

        fn errnoIs(value: E) bool {
            return __errno_location().* == @as(c_int, @intFromEnum(value));
        }
    };

    const InHeader = extern struct {
        len: u32,
        opcode: u32,
        unique: u64,
        nodeid: u64,
        uid: u32,
        gid: u32,
        pid: u32,
        padding: u32,
    };

    const OutHeader = extern struct {
        len: u32,
        error_: i32,
        unique: u64,
    };

    const Attr = extern struct {
        ino: u64,
        size: u64,
        blocks: u64,
        atime: u64,
        mtime: u64,
        ctime: u64,
        atimensec: u32,
        mtimensec: u32,
        ctimensec: u32,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u32,
        blksize: u32,
        padding: u32,
    };

    const EntryOut = extern struct {
        nodeid: u64,
        generation: u64,
        entry_valid: u64,
        attr_valid: u64,
        entry_valid_nsec: u32,
        attr_valid_nsec: u32,
        attr: Attr,
    };

    const AttrOut = extern struct {
        attr_valid: u64,
        attr_valid_nsec: u32,
        dummy: u32,
        attr: Attr,
    };

    const OpenIn = extern struct {
        flags: u32,
        unused: u32,
    };

    const OpenOut = extern struct {
        fh: u64,
        open_flags: u32,
        padding: u32,
    };

    const ReadIn = extern struct {
        fh: u64,
        offset: u64,
        size: u32,
        read_flags: u32,
        lock_owner: u64,
        flags: u32,
        padding: u32,
    };

    const AccessIn = extern struct {
        mask: u32,
        padding: u32,
    };

    const Version = extern struct {
        major: u32,
        minor: u32,
    };

    const InitIn = extern struct {
        major: u32,
        minor: u32,
        max_readahead: u32,
        flags: u32,
    };

    const InitOut = extern struct {
        major: u32,
        minor: u32,
        max_readahead: u32,
        flags: u32,
        max_background: u16,
        congestion_threshold: u16,
        max_write: u32,
        time_gran: u32,
        max_pages: u16,
        map_alignment: u16,
        flags2: u32,
        unused: [7]u32,
    };

    const StatfsOut = extern struct {
        blocks: u64,
        bfree: u64,
        bavail: u64,
        files: u64,
        ffree: u64,
        bsize: u32,
        namelen: u32,
        frsize: u32,
        padding: u32,
        spare: [6]u32,
    };

    const Opcode = enum(u32) {
        lookup = 1,
        forget = 2,
        getattr = 4,
        open = 14,
        read = 15,
        statfs = 17,
        release = 18,
        fsync = 20,
        flush = 25,
        init = 26,
        opendir = 28,
        readdir = 29,
        releasedir = 30,
        fsyncdir = 31,
        access = 34,
        interrupt = 36,
        destroy = 38,
        batch_forget = 42,
        _,
    };

    fn decode(comptime T: type, bytes: []const u8) ?T {
        if (bytes.len < @sizeOf(T)) return null;

        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
        return value;
    }

    fn closeFd(fd: c_int) void {
        // Linux releases the descriptor even when close reports EINTR.
        _ = C.close(fd);
    }

    fn forkChild() !c_int {
        const pid = C.fork();
        if (pid < 0) return error.ForkFailed;
        return pid;
    }

    fn waitChild(pid: c_int) !u8 {
        var status: c_int = 0;

        while (C.waitpid(pid, &status, 0) < 0) {
            if (C.errnoIs(.INTR)) continue;
            return error.WaitFailed;
        }

        const bits: u32 = @bitCast(status);

        if (bits & 0x7f != 0) return error.ChildSignaled;
        return @intCast((bits >> 8) & 0xff);
    }

    const Helper = struct {
        const names = [_][]const u8{
            "fusermount3",
            "fusermount",
        };

        const directories = [_][]const u8{
            "/usr/bin",
            "/bin",
            "/usr/local/bin",
            "/usr/sbin",
            "/sbin",
        };

        arena: std.heap.ArenaAllocator,
        paths: []const [:0]const u8,
        argv: [:null]?[*:0]const u8,
        envp: [:null]?[*:0]const u8,

        fn init(
            allocator: std.mem.Allocator,
            arguments: []const []const u8,
            extra_env: []const []const u8,
        ) !Helper {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();

            const temporary = arena.allocator();

            const paths = try temporary.alloc(
                [:0]const u8,
                names.len * directories.len,
            );

            var path_index: usize = 0;

            for (names) |name| {
                for (directories) |directory| {
                    paths[path_index] = try std.fmt.allocPrintSentinel(
                        temporary,
                        "{s}/{s}",
                        .{ directory, name },
                        0,
                    );
                    path_index += 1;
                }
            }

            var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
            try argv.append(temporary, null);

            for (arguments) |argument| {
                const owned = try temporary.dupeZ(u8, argument);
                try argv.append(temporary, owned.ptr);
            }

            var envp: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
            var environment_index: usize = 0;

            while (C.environ[environment_index]) |entry| : (environment_index += 1) {
                const text = std.mem.span(entry);

                if (std.mem.startsWith(u8, text, "_FUSE_COMMFD=")) {
                    continue;
                }

                const owned = try temporary.dupeZ(u8, text);
                try envp.append(temporary, owned.ptr);
            }

            for (extra_env) |entry| {
                const owned = try temporary.dupeZ(u8, entry);
                try envp.append(temporary, owned.ptr);
            }

            return .{
                .arena = arena,
                .paths = paths,
                .argv = try argv.toOwnedSliceSentinel(temporary, null),
                .envp = try envp.toOwnedSliceSentinel(temporary, null),
            };
        }

        fn deinit(self: *Helper) void {
            self.arena.deinit();
        }

        fn exec(self: *Helper, fd_to_close: ?c_int) noreturn {
            // After fork, only async-signal-safe operations may run before exec.
            if (fd_to_close) |fd| closeFd(fd);

            for (self.paths) |path| {
                self.argv[0] = path.ptr;
                _ = C.execve(path.ptr, self.argv.ptr, self.envp.ptr);
            }

            C._exit(127);
        }
    };

    fn receiveFd(socket: c_int) !c_int {
        const sol_socket = 1;
        const scm_rights = 1;
        const msg_ctrunc = 0x08;

        var control: [64]u8 align(@alignOf(C.ControlHeader)) = undefined;
        var byte: [1]u8 = undefined;
        var vectors = [_]C.IoVec{
            .{ .base = &byte, .len = byte.len },
        };

        var message: C.Message = undefined;

        while (true) {
            message = .{
                .iov = &vectors,
                .iovlen = vectors.len,
                .control = &control,
                .controllen = control.len,
            };

            const count = C.recvmsg(socket, &message, 0);

            if (count < 0) {
                if (C.errnoIs(.INTR)) continue;
                return error.ReceiveFdFailed;
            }

            if (count == 0) return error.MountFailed;
            break;
        }

        if (message.controllen > control.len) {
            return error.InvalidControlMessage;
        }

        var received: ?c_int = null;
        errdefer if (received) |fd| closeFd(fd);

        var offset: usize = 0;

        while (offset < message.controllen) {
            const remaining = control[offset..message.controllen];

            if (remaining.len < @sizeOf(C.ControlHeader)) break;

            const header = decode(C.ControlHeader, remaining).?;

            if (header.len < @sizeOf(C.ControlHeader) or
                header.len > remaining.len)
            {
                return error.InvalidControlMessage;
            }

            if (header.level == sol_socket and header.kind == scm_rights) {
                const payload = remaining[@sizeOf(C.ControlHeader)..header.len];

                if (payload.len == 0 or payload.len % @sizeOf(c_int) != 0) {
                    return error.InvalidControlMessage;
                }

                var descriptor_offset: usize = 0;

                while (descriptor_offset < payload.len) : (descriptor_offset += @sizeOf(c_int)) {
                    const fd = decode(c_int, payload[descriptor_offset..]).?;

                    if (fd < 0) return error.InvalidControlMessage;

                    if (received == null) {
                        received = fd;
                    } else {
                        closeFd(fd);
                    }
                }
            }

            const aligned = std.mem.alignForward(
                usize,
                header.len,
                @sizeOf(usize),
            );

            if (aligned > remaining.len) break;
            offset += aligned;
        }

        if (message.flags & msg_ctrunc != 0) {
            return error.TruncatedControlMessage;
        }

        return received orelse error.MountFailed;
    }

    fn acquireFd(
        allocator: std.mem.Allocator,
        mountpoint: []const u8,
    ) !c_int {
        const af_unix = 1;
        const sock_stream = 1;

        var sockets: [2]c_int = undefined;

        // The helper's socket must survive exec so it can return the FUSE fd.
        if (C.socketpair(af_unix, sock_stream, 0, &sockets) != 0) {
            return error.SocketPairUnavailable;
        }

        defer closeFd(sockets[0]);

        var sender: ?c_int = sockets[1];
        defer if (sender) |fd| closeFd(fd);

        var environment_buffer: [64]u8 = undefined;
        const environment = try std.fmt.bufPrint(
            &environment_buffer,
            "_FUSE_COMMFD={d}",
            .{sockets[1]},
        );

        var helper = try Helper.init(
            allocator,
            &.{ "-o", "ro", "--", mountpoint },
            &.{environment},
        );
        defer helper.deinit();

        const pid = try forkChild();

        if (pid == 0) helper.exec(sockets[0]);

        closeFd(sockets[1]);
        sender = null;

        const fd = receiveFd(sockets[0]) catch |err| {
            _ = waitChild(pid) catch {};
            return err;
        };
        errdefer closeFd(fd);

        if (try waitChild(pid) != 0) return error.MountFailed;

        return fd;
    }

    fn unmount(
        allocator: std.mem.Allocator,
        mountpoint: []const u8,
    ) !void {
        var helper = try Helper.init(
            allocator,
            &.{ "-uz", "--", mountpoint },
            &.{},
        );
        defer helper.deinit();

        const pid = try forkChild();

        if (pid == 0) helper.exec(null);

        if (try waitChild(pid) != 0) return error.UnmountFailed;
    }

    pub fn Mount(comptime Archive: type) type {
        return struct {
            const Self = @This();
            const header_size = @sizeOf(OutHeader);

            allocator: std.mem.Allocator,
            archive: *Archive,
            mountpoint: []u8,
            fd: c_int,
            namespace: Namespace,
            read_buffer: []u8,
            reply_buffer: []u8,
            thread: std.Thread = undefined,
            shutdown: std.atomic.Value(bool) = .init(false),
            failed: ?anyerror = null,

            pub fn start(
                allocator: std.mem.Allocator,
                archive: *Archive,
                mountpoint: []const u8,
            ) !*Self {
                // Archive entries must remain unchanged until this mount stops.
                var namespace = try Namespace.build(allocator, archive);
                errdefer namespace.deinit();

                const owned_mountpoint = try allocator.dupe(u8, mountpoint);
                errdefer allocator.free(owned_mountpoint);

                const read_buffer = try allocator.alloc(u8, read_buffer_size);
                errdefer allocator.free(read_buffer);

                const reply_buffer = try allocator.alloc(
                    u8,
                    header_size + max_read,
                );
                errdefer allocator.free(reply_buffer);

                const self = try allocator.create(Self);
                errdefer allocator.destroy(self);

                const fd = try acquireFd(allocator, owned_mountpoint);
                errdefer {
                    unmount(allocator, owned_mountpoint) catch {};
                    closeFd(fd);
                }

                self.* = .{
                    .allocator = allocator,
                    .archive = archive,
                    .mountpoint = owned_mountpoint,
                    .fd = fd,
                    .namespace = namespace,
                    .read_buffer = read_buffer,
                    .reply_buffer = reply_buffer,
                };

                self.thread = try std.Thread.spawn(.{}, session, .{self});

                return self;
            }

            pub fn stop(self: *Self) ?anyerror {
                self.shutdown.store(true, .release);
                self.thread.join();

                const unmount_error: ?anyerror = result: {
                    unmount(self.allocator, self.mountpoint) catch |err| {
                        break :result err;
                    };

                    break :result null;
                };

                closeFd(self.fd);

                const result = if (self.failed) |err|
                    @as(?anyerror, err)
                else
                    unmount_error;

                const allocator = self.allocator;

                self.namespace.deinit();
                allocator.free(self.read_buffer);
                allocator.free(self.reply_buffer);
                allocator.free(self.mountpoint);
                allocator.destroy(self);

                return result;
            }

            fn recordFailure(self: *Self, err: anyerror) void {
                if (self.failed == null) self.failed = err;
                self.shutdown.store(true, .release);
            }

            fn writeReply(self: *Self, bytes: []const u8) !void {
                while (true) {
                    const count = C.write(self.fd, bytes.ptr, bytes.len);

                    if (count < 0) {
                        if (C.errnoIs(.INTR)) continue;
                        return error.FuseWriteFailed;
                    }

                    // Each write to /dev/fuse must contain a complete response.
                    if (@as(usize, @intCast(count)) != bytes.len) {
                        return error.ShortFuseWrite;
                    }

                    return;
                }
            }

            fn send(
                self: *Self,
                unique: u64,
                errno: ?E,
                payload_len: usize,
            ) void {
                const header = OutHeader{
                    .len = @intCast(header_size + payload_len),
                    .error_ = if (errno) |e|
                        -@as(i32, @intFromEnum(e))
                    else
                        0,
                    .unique = unique,
                };

                @memcpy(
                    self.reply_buffer[0..header_size],
                    std.mem.asBytes(&header),
                );

                self.writeReply(
                    self.reply_buffer[0 .. header_size + payload_len],
                ) catch |err| self.recordFailure(err);
            }

            fn reply(
                self: *Self,
                unique: u64,
                payload: []const u8,
            ) void {
                @memcpy(
                    self.reply_buffer[header_size..][0..payload.len],
                    payload,
                );

                self.send(unique, null, payload.len);
            }

            fn fail(self: *Self, unique: u64, errno: E) void {
                self.send(unique, errno, 0);
            }

            fn session(self: *Self) void {
                const poll_in = 0x001;
                const poll_error = 0x008;
                const poll_hup = 0x010;
                const poll_invalid = 0x020;

                var descriptors = [_]C.PollFd{
                    .{
                        .fd = self.fd,
                        .events = poll_in,
                        .revents = 0,
                    },
                };

                while (!self.shutdown.load(.acquire)) {
                    descriptors[0].revents = 0;

                    const ready = C.poll(
                        &descriptors,
                        descriptors.len,
                        100,
                    );

                    if (ready < 0) {
                        if (C.errnoIs(.INTR)) continue;

                        self.recordFailure(error.FusePollFailed);
                        return;
                    }

                    if (self.shutdown.load(.acquire)) return;
                    if (ready == 0) continue;

                    const events = descriptors[0].revents;

                    if (events & poll_in == 0) {
                        if (events & poll_hup != 0) return;

                        if (events & (poll_error | poll_invalid) != 0) {
                            self.recordFailure(error.FuseDisconnected);
                            return;
                        }

                        continue;
                    }

                    const result = C.read(
                        self.fd,
                        self.read_buffer.ptr,
                        self.read_buffer.len,
                    );

                    if (result < 0) {
                        if (C.errnoIs(.INTR) or C.errnoIs(.AGAIN)) continue;
                        if (C.errnoIs(.NODEV)) return;

                        self.recordFailure(error.FuseReadFailed);
                        return;
                    }

                    if (result == 0) return;

                    const count: usize = @intCast(result);
                    const packet = self.read_buffer[0..count];

                    const header = decode(InHeader, packet) orelse {
                        self.recordFailure(error.ProtocolViolation);
                        return;
                    };

                    if (header.len != packet.len) {
                        self.recordFailure(error.ProtocolViolation);
                        return;
                    }

                    self.dispatch(
                        &header,
                        packet[@sizeOf(InHeader)..],
                    );
                }
            }

            fn dispatch(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const opcode: Opcode = @enumFromInt(header.opcode);

                switch (opcode) {
                    .init => self.onInit(header, body),
                    .lookup => self.onLookup(header, body),
                    .getattr => self.onGetAttr(header),
                    .open => self.onOpen(header, body, false),
                    .opendir => self.onOpen(header, body, true),
                    .read => self.onRead(header, body),
                    .readdir => self.onReadDir(header, body),
                    .statfs => self.onStatfs(header),
                    .access => self.onAccess(header, body),

                    .flush,
                    .release,
                    .releasedir,
                    .fsync,
                    .fsyncdir,
                    => self.reply(header.unique, ""),

                    .forget, .batch_forget => {},

                    .interrupt => self.fail(header.unique, .AGAIN),

                    .destroy => self.shutdown.store(true, .release),

                    else => self.fail(header.unique, .NOSYS),
                }
            }

            fn onInit(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const version = decode(Version, body) orelse
                    return self.fail(header.unique, .INVAL);

                if (version.major > protocol_major) {
                    const supported = Version{
                        .major = protocol_major,
                        .minor = protocol_minor,
                    };

                    self.reply(
                        header.unique,
                        std.mem.asBytes(&supported),
                    );
                    return;
                }

                if (version.major != protocol_major or version.minor < 9) {
                    return self.fail(header.unique, .PROTO);
                }

                const input = decode(InitIn, body) orelse
                    return self.fail(header.unique, .INVAL);

                var output = std.mem.zeroes(InitOut);
                output.major = protocol_major;
                output.minor = @min(input.minor, protocol_minor);
                output.max_readahead = @min(input.max_readahead, max_read);
                output.max_write = max_read;
                output.time_gran = 1;

                const bytes = std.mem.asBytes(&output);

                // Protocol versions before 7.23 use the shorter INIT response.
                const length: usize = if (output.minor < 23)
                    @offsetOf(InitOut, "time_gran")
                else
                    bytes.len;

                self.reply(header.unique, bytes[0..length]);
            }

            fn attributes(
                self: *Self,
                id: u64,
                node: *const Namespace.Node,
            ) ?Attr {
                var size: u64 = 4096;
                var timestamp: i96 = 0;

                switch (node.data) {
                    .directory => {},
                    .file => |index| {
                        const entry = self.archive.entryAt(index) orelse
                            return null;

                        size = entry.content.byte_count;
                        timestamp = @max(entry.timestamp, 0);
                    },
                }

                const seconds: u64 = @intCast(
                    @divFloor(timestamp, std.time.ns_per_s),
                );
                const nanoseconds: u32 = @intCast(
                    @mod(timestamp, std.time.ns_per_s),
                );

                return .{
                    .ino = id,
                    .size = size,
                    .blocks = size / 512 + @intFromBool(size % 512 != 0),
                    .atime = seconds,
                    .mtime = seconds,
                    .ctime = seconds,
                    .atimensec = nanoseconds,
                    .mtimensec = nanoseconds,
                    .ctimensec = nanoseconds,
                    .mode = if (node.isDirectory()) 0o040555 else 0o100444,
                    .nlink = if (node.isDirectory()) 2 else 1,
                    .uid = C.geteuid(),
                    .gid = C.getegid(),
                    .rdev = 0,
                    .blksize = 4096,
                    .padding = 0,
                };
            }

            fn onLookup(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const parent = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                if (!parent.isDirectory()) {
                    return self.fail(header.unique, .NOTDIR);
                }

                const terminator = std.mem.indexOfScalar(u8, body, 0) orelse
                    return self.fail(header.unique, .INVAL);

                const name = body[0..terminator];

                const id = if (std.mem.eql(u8, name, "."))
                    header.nodeid
                else if (std.mem.eql(u8, name, ".."))
                    parent.parent
                else
                    self.namespace.lookup(header.nodeid, name) orelse
                        return self.fail(header.unique, .NOENT);

                const node = self.namespace.node(id).?;

                const attr = self.attributes(id, node) orelse
                    return self.fail(header.unique, .IO);

                const output = EntryOut{
                    .nodeid = id,
                    .generation = 0,
                    .entry_valid = 0,
                    .attr_valid = 0,
                    .entry_valid_nsec = 0,
                    .attr_valid_nsec = 0,
                    .attr = attr,
                };

                self.reply(header.unique, std.mem.asBytes(&output));
            }

            fn onGetAttr(
                self: *Self,
                header: *const InHeader,
            ) void {
                const node = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                const attr = self.attributes(header.nodeid, node) orelse
                    return self.fail(header.unique, .IO);

                const output = AttrOut{
                    .attr_valid = 0,
                    .attr_valid_nsec = 0,
                    .dummy = 0,
                    .attr = attr,
                };

                self.reply(header.unique, std.mem.asBytes(&output));
            }

            fn onOpen(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
                for_directory: bool,
            ) void {
                const input = decode(OpenIn, body) orelse
                    return self.fail(header.unique, .INVAL);

                const node = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                if (for_directory != node.isDirectory()) {
                    return self.fail(
                        header.unique,
                        if (node.isDirectory()) .ISDIR else .NOTDIR,
                    );
                }

                const access_mode = 0x3;
                const truncate = 0x200;

                if (input.flags & (access_mode | truncate) != 0) {
                    return self.fail(header.unique, .ROFS);
                }

                const output = OpenOut{
                    .fh = header.nodeid,
                    .open_flags = 0,
                    .padding = 0,
                };

                self.reply(header.unique, std.mem.asBytes(&output));
            }

            fn onAccess(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const input = decode(AccessIn, body) orelse
                    return self.fail(header.unique, .INVAL);

                const node = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                const execute_access = 1;
                const write_access = 2;

                if (input.mask & write_access != 0) {
                    return self.fail(header.unique, .ROFS);
                }

                if (input.mask & execute_access != 0 and !node.isDirectory()) {
                    return self.fail(header.unique, .ACCES);
                }

                self.reply(header.unique, "");
            }

            fn onRead(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const input = decode(ReadIn, body) orelse
                    return self.fail(header.unique, .INVAL);

                const node = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                const index = switch (node.data) {
                    .directory => return self.fail(header.unique, .ISDIR),
                    .file => |value| value,
                };

                if (input.fh != header.nodeid) {
                    return self.fail(header.unique, .BADF);
                }

                const entry = self.archive.entryAt(index) orelse
                    return self.fail(header.unique, .IO);

                const available = entry.content.byte_count -| input.offset;

                const request: usize = @intCast(@min(
                    @as(u64, input.size),
                    available,
                    self.reply_buffer.len - header_size,
                ));

                if (request == 0) {
                    self.send(header.unique, null, 0);
                    return;
                }

                const root = entry.content.root orelse
                    return self.fail(header.unique, .IO);

                const count = self.archive.readRange(
                    root,
                    input.offset,
                    self.reply_buffer[header_size..][0..request],
                ) catch {
                    return self.fail(header.unique, .IO);
                };

                if (count != request) {
                    return self.fail(header.unique, .IO);
                }

                self.send(header.unique, null, count);
            }

            fn onReadDir(
                self: *Self,
                header: *const InHeader,
                body: []const u8,
            ) void {
                const input = decode(ReadIn, body) orelse
                    return self.fail(header.unique, .INVAL);

                const node = self.namespace.node(header.nodeid) orelse
                    return self.fail(header.unique, .NOENT);

                const children = switch (node.data) {
                    .directory => |*value| value,
                    .file => return self.fail(header.unique, .NOTDIR),
                };

                if (input.fh != header.nodeid) {
                    return self.fail(header.unique, .BADF);
                }

                const child_ids = children.values();
                const item_count = child_ids.len + 2;

                var index: usize = @intCast(@min(
                    input.offset,
                    @as(u64, @intCast(item_count)),
                ));

                const capacity: usize = @intCast(@min(
                    @as(u64, input.size),
                    @as(u64, @intCast(self.reply_buffer.len - header_size)),
                ));

                const output = self.reply_buffer[header_size..][0..capacity];
                var written: usize = 0;

                while (index < item_count) : (index += 1) {
                    const id = switch (index) {
                        0 => header.nodeid,
                        1 => node.parent,
                        else => child_ids[index - 2],
                    };

                    const child = self.namespace.node(id).?;

                    const name: []const u8 = switch (index) {
                        0 => ".",
                        1 => "..",
                        else => child.name,
                    };

                    const used = encodeDirent(
                        output[written..],
                        id,
                        @intCast(index + 1),
                        name,
                        child.isDirectory(),
                    ) orelse break;

                    written += used;
                }

                self.send(header.unique, null, written);
            }

            fn onStatfs(
                self: *Self,
                header: *const InHeader,
            ) void {
                var output = std.mem.zeroes(StatfsOut);
                output.files = @intCast(self.namespace.nodes.items.len);
                output.bsize = 4096;
                output.namelen = 255;
                output.frsize = 4096;

                self.reply(header.unique, std.mem.asBytes(&output));
            }
        };
    }
};

test "directory entries fit the requested buffer and carry resume cookies" {
    var buffer: [64]u8 = undefined;

    try std.testing.expect(
        encodeDirent(buffer[0..31], 42, 7, "hi", false) == null,
    );

    const used = encodeDirent(buffer[0..32], 42, 7, "hi", false) orelse
        return error.BufferTooSmall;

    try std.testing.expectEqual(@as(usize, 32), used);
    try std.testing.expectEqual(
        @as(u64, 42),
        std.mem.readInt(u64, buffer[0..8], .native),
    );
    try std.testing.expectEqual(
        @as(u64, 7),
        std.mem.readInt(u64, buffer[8..16], .native),
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        std.mem.readInt(u32, buffer[16..20], .native),
    );
    try std.testing.expectEqual(
        @as(u32, 8),
        std.mem.readInt(u32, buffer[20..24], .native),
    );
    try std.testing.expectEqualSlices(u8, "hi", buffer[24..26]);

    for (buffer[26..used]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

const TestArchive = struct {
    paths: []const []const u8,

    pub fn entryAt(
        self: *const TestArchive,
        index: usize,
    ) ?struct { path: []const u8 } {
        if (index >= self.paths.len) return null;
        return .{ .path = self.paths[index] };
    }
};

test "namespace synthesizes directories and resolves names by content" {
    const archive = TestArchive{
        .paths = &.{ "a/b.txt", "a/c.txt", "top.txt" },
    };

    var namespace = try Namespace.build(std.testing.allocator, &archive);
    defer namespace.deinit();

    const directory = namespace.lookup(Namespace.root_id, "a") orelse
        return error.MissingDirectory;

    try std.testing.expect(namespace.node(directory).?.isDirectory());

    var copied_name = [_]u8{ 'b', '.', 't', 'x', 't' };

    const file = namespace.lookup(directory, &copied_name) orelse
        return error.MissingFile;

    try std.testing.expectEqual(
        @as(usize, 0),
        namespace.node(file).?.data.file,
    );

    try std.testing.expect(namespace.lookup(directory, "c.txt") != null);
    try std.testing.expect(namespace.lookup(Namespace.root_id, "top.txt") != null);
    try std.testing.expect(namespace.lookup(Namespace.root_id, "missing") == null);
    try std.testing.expect(namespace.lookup(file, "child") == null);
}

test "namespace rejects duplicates and file-directory collisions in either order" {
    const cases = [_][]const []const u8{
        &.{ "a", "a" },
        &.{ "a", "a/b" },
        &.{ "a/b", "a" },
        &.{ "a/b", "a/b" },
    };

    for (cases) |paths| {
        const archive = TestArchive{ .paths = paths };

        try std.testing.expectError(
            error.InvalidNamespace,
            Namespace.build(std.testing.allocator, &archive),
        );
    }
}

test "namespace rejects invalid path components" {
    const paths = [_][]const u8{
        "",
        "/a",
        "a/",
        "a//b",
        ".",
        "..",
        "a/../b",
        "a/./b",
        "a\x00b",
    };

    for (paths) |path| {
        const archive = TestArchive{ .paths = &.{path} };

        try std.testing.expectError(
            error.InvalidNamespace,
            Namespace.build(std.testing.allocator, &archive),
        );
    }
}

test "namespace owns its names" {
    var path = [_]u8{ 'a', '/', 'b' };
    const archive = TestArchive{ .paths = &.{&path} };

    var namespace = try Namespace.build(std.testing.allocator, &archive);
    defer namespace.deinit();

    @memset(&path, 'x');

    const directory = namespace.lookup(Namespace.root_id, "a") orelse
        return error.MissingDirectory;

    try std.testing.expect(namespace.lookup(directory, "b") != null);
}

test "namespace releases allocations on every construction failure" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const archive = TestArchive{
                .paths = &.{
                    "a/b/c.txt",
                    "a/b/d.txt",
                    "a/e.txt",
                    "other/file.txt",
                    "top.txt",
                },
            };

            var namespace = try Namespace.build(allocator, &archive);
            defer namespace.deinit();

            try std.testing.expect(
                namespace.lookup(Namespace.root_id, "top.txt") != null,
            );
        }
    };

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Exercise.run,
        .{},
    );
}

test "FUSE wire layouts match protocol 7.28" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Linux.InHeader));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Linux.OutHeader));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(Linux.Attr));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Linux.EntryOut));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(Linux.AttrOut));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Linux.InitOut));
    try std.testing.expectEqual(
        @as(usize, 24),
        @offsetOf(Linux.EntryOut, "attr_valid"),
    );
}

test "unsupported platforms reject mounting" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const Archive = struct {};
    var archive: Archive = .{};

    try std.testing.expectError(
        error.UnsupportedPlatform,
        Mount(Archive).start(
            std.testing.allocator,
            &archive,
            "unused",
        ),
    );
}
