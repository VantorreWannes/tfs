const std = @import("std");
const builtin = @import("builtin");

pub const InstanceId = std.os.windows.GUID;

pub const LoadFile = *const fn (
    allocator: std.mem.Allocator,
    absolute_path: [:0]const u16,
) anyerror![]u8;

const Platform = if (builtin.os.tag == .windows) Windows else Unsupported;

pub const Mount = Platform.Mount;
pub const markDirectory = Platform.markDirectory;

fn archivePath(
    allocator: std.mem.Allocator,
    path: [:0]const u16,
) ![]u8 {
    const result = try std.unicode.utf16LeToUtf8Alloc(allocator, path);

    for (result) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }

    return result;
}

fn windowsPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![:0]u16 {
    const result = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);

    for (result) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }

    return result;
}

fn joinPath(
    allocator: std.mem.Allocator,
    directory: []const u16,
    relative: []const u16,
) ![:0]u16 {
    const needs_separator = directory.len != 0 and
        directory[directory.len - 1] != '\\';

    const prefix_len = try std.math.add(
        usize,
        directory.len,
        @intFromBool(needs_separator),
    );
    const length = try std.math.add(usize, prefix_len, relative.len);

    const result = try allocator.allocSentinel(u16, length, 0);

    @memcpy(result[0..directory.len], directory);
    if (needs_separator) result[directory.len] = '\\';
    @memcpy(result[prefix_len..], relative);

    return result;
}

const Unsupported = struct {
    pub fn markDirectory(
        _: std.mem.Allocator,
        _: []const u8,
        _: *const InstanceId,
    ) error{UnsupportedPlatform}!void {
        return error.UnsupportedPlatform;
    }

    pub fn Mount(comptime Archive: type) type {
        return opaque {
            const Self = @This();

            pub fn start(
                _: std.mem.Allocator,
                _: *Archive,
                _: []const u8,
                _: LoadFile,
            ) error{UnsupportedPlatform}!*Self {
                return error.UnsupportedPlatform;
            }

            pub fn stop(_: *Self) ?anyerror {
                unreachable;
            }
        };
    }
};

const Windows = struct {
    const HRESULT = i32;
    const Handle = ?*anyopaque;
    const GUID = InstanceId;

    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

    const ENUM_RESTART_SCAN: u32 = 0x1;
    const ENUM_RETURN_SINGLE_ENTRY: u32 = 0x2;

    const FILE_RENAMED: u32 = 0x80;
    const FILE_CLOSED_MODIFIED: u32 = 0x400;
    const FILE_CLOSED_DELETED: u32 = 0x800;

    const ERROR_FILE_NOT_FOUND: u32 = 2;
    const ERROR_NOT_ENOUGH_MEMORY: u32 = 8;
    const ERROR_GEN_FAILURE: u32 = 31;
    const ERROR_INVALID_PARAMETER: u32 = 87;
    const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
    const ERROR_FILE_TOO_LARGE: u32 = 223;

    const SRWLOCK = extern struct {
        Ptr: ?*anyopaque = null,
    };

    const VersionInfo = extern struct {
        ProviderID: [128]u8,
        ContentID: [128]u8,
    };

    const CallbackData = extern struct {
        Size: u32,
        Flags: u32,
        NamespaceVirtualizationContext: Handle,
        CommandId: i32,
        FileId: GUID,
        DataStreamId: GUID,
        FilePathName: ?[*:0]const u16,
        VersionInfo: ?*const VersionInfo,
        TriggeringProcessId: u32,
        TriggeringProcessImageFileName: ?[*:0]const u16,
        InstanceContext: ?*anyopaque,
    };

    const FileBasicInfo = extern struct {
        IsDirectory: u8,
        FileSize: i64,
        CreationTime: i64,
        LastAccessTime: i64,
        LastWriteTime: i64,
        ChangeTime: i64,
        FileAttributes: u32,
    };

    const PlaceholderInfo = extern struct {
        FileBasicInfo: FileBasicInfo,

        EaInformation: extern struct {
            EaBufferSize: u32,
            OffsetToFirstEa: u32,
        },

        SecurityInformation: extern struct {
            SecurityBufferSize: u32,
            OffsetToSecurityDescriptor: u32,
        },

        StreamsInformation: extern struct {
            StreamsInfoBufferSize: u32,
            OffsetToFirstStreamInfo: u32,
        },

        VersionInfo: VersionInfo,
        VariableData: [1]u8,
    };

    const NotificationParameters = extern union {
        PostCreate: extern struct {
            NotificationMask: u32,
        },

        FileRenamed: extern struct {
            NotificationMask: u32,
        },

        FileDeletedOnHandleClose: extern struct {
            IsFileModified: u8,
        },
    };

    const NotificationMapping = extern struct {
        NotificationBitMask: u32,
        NotificationRoot: [*:0]const u16,
    };

    const StartOptions = extern struct {
        Flags: u32,
        PoolThreadCount: u32,
        ConcurrentThreadCount: u32,
        NotificationMappings: ?[*]NotificationMapping,
        NotificationMappingsCount: u32,
    };

    const VirtualizationInstanceInfo = extern struct {
        InstanceID: GUID,
        WriteAlignment: u32,
    };

    const Callbacks = extern struct {
        StartDirectoryEnumerationCallback: ?*const fn (
            *const CallbackData,
            *const GUID,
        ) callconv(.winapi) HRESULT,

        EndDirectoryEnumerationCallback: ?*const fn (
            *const CallbackData,
            *const GUID,
        ) callconv(.winapi) HRESULT,

        GetDirectoryEnumerationCallback: ?*const fn (
            *const CallbackData,
            *const GUID,
            ?[*:0]const u16,
            Handle,
        ) callconv(.winapi) HRESULT,

        GetPlaceholderInfoCallback: ?*const fn (
            *const CallbackData,
        ) callconv(.winapi) HRESULT,

        GetFileDataCallback: ?*const fn (
            *const CallbackData,
            u64,
            u32,
        ) callconv(.winapi) HRESULT,

        QueryFileNameCallback: ?*const fn (
            *const CallbackData,
        ) callconv(.winapi) HRESULT,

        NotificationCallback: ?*const fn (
            *const CallbackData,
            u8,
            u32,
            ?[*:0]const u16,
            ?*NotificationParameters,
        ) callconv(.winapi) HRESULT,

        CancelCommandCallback: ?*const fn (
            *const CallbackData,
        ) callconv(.winapi) void,
    };

    extern "kernel32" fn LoadLibraryExW(
        name: [*:0]const u16,
        file: Handle,
        flags: u32,
    ) callconv(.winapi) Handle;

    extern "kernel32" fn GetProcAddress(
        module: *anyopaque,
        name: [*:0]const u8,
    ) callconv(.winapi) ?*const anyopaque;

    extern "kernel32" fn FreeLibrary(
        module: *anyopaque,
    ) callconv(.winapi) i32;

    extern "kernel32" fn GetFullPathNameW(
        path: [*:0]const u16,
        capacity: u32,
        buffer: ?[*]u16,
        file_part: ?*?[*]u16,
    ) callconv(.winapi) u32;

    extern "kernel32" fn AcquireSRWLockExclusive(
        lock: *SRWLOCK,
    ) callconv(.winapi) void;

    extern "kernel32" fn ReleaseSRWLockExclusive(
        lock: *SRWLOCK,
    ) callconv(.winapi) void;

    const Api = struct {
        module: *anyopaque,

        PrjStartVirtualizing: *const fn (
            [*:0]const u16,
            *const Callbacks,
            ?*anyopaque,
            ?*const StartOptions,
            *Handle,
        ) callconv(.winapi) HRESULT,

        PrjStopVirtualizing: *const fn (
            Handle,
        ) callconv(.winapi) void,

        PrjMarkDirectoryAsPlaceholder: *const fn (
            [*:0]const u16,
            ?[*:0]const u16,
            ?*const VersionInfo,
            *const GUID,
        ) callconv(.winapi) HRESULT,

        PrjFillDirEntryBuffer: *const fn (
            [*:0]const u16,
            *const FileBasicInfo,
            Handle,
        ) callconv(.winapi) HRESULT,

        PrjWritePlaceholderInfo: *const fn (
            Handle,
            [*:0]const u16,
            *const PlaceholderInfo,
            u32,
        ) callconv(.winapi) HRESULT,

        PrjGetVirtualizationInstanceInfo: *const fn (
            Handle,
            *VirtualizationInstanceInfo,
        ) callconv(.winapi) HRESULT,

        PrjAllocateAlignedBuffer: *const fn (
            Handle,
            usize,
        ) callconv(.winapi) ?*anyopaque,

        PrjFreeAlignedBuffer: *const fn (
            *anyopaque,
        ) callconv(.winapi) void,

        PrjWriteFileData: *const fn (
            Handle,
            *const GUID,
            *const anyopaque,
            u64,
            u32,
        ) callconv(.winapi) HRESULT,

        PrjFileNameMatch: *const fn (
            [*:0]const u16,
            [*:0]const u16,
        ) callconv(.winapi) u8,

        PrjFileNameCompare: *const fn (
            [*:0]const u16,
            [*:0]const u16,
        ) callconv(.winapi) i32,

        fn load() !Api {
            const name = std.unicode.utf8ToUtf16LeStringLiteral(
                "ProjectedFSLib.dll",
            );
            const load_library_search_system32: u32 = 0x00000800;

            const module = LoadLibraryExW(
                name,
                null,
                load_library_search_system32,
            ) orelse return error.ProjFsUnavailable;
            errdefer _ = FreeLibrary(module);

            var api: Api = undefined;
            api.module = module;

            inline for (@typeInfo(Api).@"struct".fields) |field| {
                if (comptime !std.mem.eql(u8, field.name, "module")) {
                    const address = GetProcAddress(
                        module,
                        field.name ++ "\x00",
                    ) orelse return error.ProjFsSymbolMissing;

                    @field(api, field.name) = @ptrCast(@alignCast(address));
                }
            }

            return api;
        }

        fn deinit(self: *Api) void {
            _ = FreeLibrary(self.module);
            self.* = undefined;
        }
    };

    const Child = struct {
        name: []const u16,
        is_directory: bool,
    };

    const DirItem = struct {
        name: [:0]u16,
        is_directory: bool,
        size: u64,

        fn lessThan(
            api: *const Api,
            left: DirItem,
            right: DirItem,
        ) bool {
            return api.PrjFileNameCompare(
                left.name.ptr,
                right.name.ptr,
            ) < 0;
        }
    };

    const Session = struct {
        id: GUID,
        items: []DirItem,
        cursor: usize = 0,
        pattern: ?[:0]u16 = null,

        fn deinit(self: *Session, allocator: std.mem.Allocator) void {
            for (self.items) |item| allocator.free(item.name);
            allocator.free(self.items);

            if (self.pattern) |pattern| allocator.free(pattern);
        }

        fn setPattern(
            self: *Session,
            allocator: std.mem.Allocator,
            search: ?[*:0]const u16,
        ) !void {
            const wildcard = std.unicode.utf8ToUtf16LeStringLiteral("*");
            const source: []const u16 = if (search) |value|
                std.mem.span(value)
            else
                wildcard;

            const replacement = try allocator.dupeZ(u16, source);

            if (self.pattern) |previous| allocator.free(previous);

            self.pattern = replacement;
            self.cursor = 0;
        }
    };

    fn callbackPath(data: *const CallbackData) ![:0]const u16 {
        const path = data.FilePathName orelse return error.MissingPath;
        return std.mem.span(path);
    }

    fn hresult(code: u32) HRESULT {
        if (code == 0) return 0;
        return @bitCast(@as(u32, 0x80070000) | (code & 0xffff));
    }

    fn failure(err: anyerror) HRESULT {
        return switch (err) {
            error.OutOfMemory => hresult(ERROR_NOT_ENOUGH_MEMORY),
            error.NotFound => hresult(ERROR_FILE_NOT_FOUND),
            error.InvalidNamespace,
            error.InvalidEnumeration,
            error.MissingPath,
            error.MissingDestination,
            => hresult(ERROR_INVALID_PARAMETER),
            error.FileTooLarge => hresult(ERROR_FILE_TOO_LARGE),
            else => hresult(ERROR_GEN_FAILURE),
        };
    }

    fn check(result: HRESULT) !void {
        if (result < 0) return error.ProjectedFsFailure;
    }

    fn absolutePath(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) ![:0]u16 {
        const relative = try windowsPath(allocator, path);
        defer allocator.free(relative);

        const needed = GetFullPathNameW(relative.ptr, 0, null, null);
        if (needed == 0) return error.PathResolutionFailed;

        const temporary = try allocator.alloc(u16, needed);
        defer allocator.free(temporary);

        const length = GetFullPathNameW(
            relative.ptr,
            needed,
            temporary.ptr,
            null,
        );

        if (length == 0 or length >= needed) {
            return error.PathResolutionFailed;
        }

        return allocator.dupeZ(u16, temporary[0..length]);
    }

    fn childName(
        api: *const Api,
        path: [:0]u16,
        directory: [:0]const u16,
    ) ?Child {
        var relative: []const u16 = path;

        if (directory.len != 0) {
            if (path.len <= directory.len or
                path[directory.len] != '\\')
            {
                return null;
            }

            const separator = path[directory.len];
            path[directory.len] = 0;

            const equal = api.PrjFileNameCompare(
                path.ptr,
                directory.ptr,
            ) == 0;

            path[directory.len] = separator;

            if (!equal) return null;
            relative = path[directory.len + 1 ..];
        }

        if (relative.len == 0) return null;

        const separator = std.mem.indexOfScalar(u16, relative, '\\');

        return .{
            .name = relative[0 .. separator orelse relative.len],
            .is_directory = separator != null,
        };
    }

    fn basicInfo(
        is_directory: bool,
        size: u64,
    ) !FileBasicInfo {
        if (size > std.math.maxInt(i64)) return error.FileTooLarge;

        var info = std.mem.zeroes(FileBasicInfo);

        info.IsDirectory = @intFromBool(is_directory);
        info.FileSize = if (is_directory) 0 else @intCast(size);
        info.FileAttributes = if (is_directory)
            FILE_ATTRIBUTE_DIRECTORY
        else
            FILE_ATTRIBUTE_NORMAL;

        return info;
    }

    pub fn markDirectory(
        allocator: std.mem.Allocator,
        path: []const u8,
        instance_id: *const InstanceId,
    ) !void {
        var api = try Api.load();
        defer api.deinit();

        const absolute = try absolutePath(allocator, path);
        defer allocator.free(absolute);

        try check(api.PrjMarkDirectoryAsPlaceholder(
            absolute.ptr,
            null,
            null,
            instance_id,
        ));
    }

    pub fn Mount(comptime Archive: type) type {
        return struct {
            const Self = @This();

            allocator: std.mem.Allocator,
            archive: *Archive,
            root_path: [:0]u16,
            load_file: LoadFile,
            api: Api,

            handle: Handle = null,
            sessions: std.ArrayListUnmanaged(Session) = .empty,
            lock: SRWLOCK = .{},
            mutation_lock: SRWLOCK = .{},
            notification_error: ?anyerror = null,

            const callbacks = Callbacks{
                .StartDirectoryEnumerationCallback = onStartDirectory,
                .EndDirectoryEnumerationCallback = onEndDirectory,
                .GetDirectoryEnumerationCallback = onGetDirectory,
                .GetPlaceholderInfoCallback = onGetPlaceholder,
                .GetFileDataCallback = onGetFileData,
                .QueryFileNameCallback = null,
                .NotificationCallback = onNotification,
                .CancelCommandCallback = null,
            };

            pub fn start(
                allocator: std.mem.Allocator,
                archive: *Archive,
                root_path: []const u8,
                load_file: LoadFile,
            ) !*Self {
                var api = try Api.load();
                errdefer api.deinit();

                const absolute = try absolutePath(allocator, root_path);
                errdefer allocator.free(absolute);

                const self = try allocator.create(Self);
                errdefer allocator.destroy(self);

                self.* = .{
                    .allocator = allocator,
                    .archive = archive,
                    .root_path = absolute,
                    .load_file = load_file,
                    .api = api,
                };

                const empty = std.unicode.utf8ToUtf16LeStringLiteral("");

                var mappings = [_]NotificationMapping{
                    .{
                        .NotificationBitMask = FILE_CLOSED_MODIFIED |
                            FILE_CLOSED_DELETED |
                            FILE_RENAMED,
                        .NotificationRoot = empty,
                    },
                };

                var options = std.mem.zeroes(StartOptions);
                options.NotificationMappings = &mappings;
                options.NotificationMappingsCount = mappings.len;

                errdefer {
                    for (self.sessions.items) |*session| {
                        session.deinit(allocator);
                    }
                    self.sessions.deinit(allocator);
                }

                try check(self.api.PrjStartVirtualizing(
                    self.root_path.ptr,
                    &callbacks,
                    self,
                    &options,
                    &self.handle,
                ));

                return self;
            }

            pub fn stop(self: *Self) ?anyerror {
                self.api.PrjStopVirtualizing(self.handle);

                const notification_error = self.notification_error;

                for (self.sessions.items) |*session| {
                    session.deinit(self.allocator);
                }

                self.sessions.deinit(self.allocator);
                self.allocator.free(self.root_path);
                self.api.deinit();

                const allocator = self.allocator;
                allocator.destroy(self);

                return notification_error;
            }

            fn recordNotificationError(self: *Self, err: anyerror) void {
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                if (self.notification_error == null) {
                    self.notification_error = err;
                }
            }

            fn context(data: *const CallbackData) *Self {
                return @ptrCast(@alignCast(data.InstanceContext.?));
            }

            fn sessionIndex(self: *Self, id: *const GUID) ?usize {
                for (self.sessions.items, 0..) |session, index| {
                    if (std.meta.eql(session.id, id.*)) return index;
                }

                return null;
            }

            fn directoryItems(
                self: *Self,
                directory: [:0]const u16,
            ) ![]DirItem {
                var items: std.ArrayListUnmanaged(DirItem) = .empty;

                errdefer {
                    for (items.items) |item| {
                        self.allocator.free(item.name);
                    }
                    items.deinit(self.allocator);
                }

                var entry_index: usize = 0;

                while (self.archive.entryAt(entry_index)) |entry| : (entry_index += 1) {
                    const path = try windowsPath(
                        self.allocator,
                        entry.path,
                    );
                    defer self.allocator.free(path);

                    const child = childName(
                        &self.api,
                        path,
                        directory,
                    ) orelse continue;

                    const name = try self.allocator.dupeZ(u16, child.name);
                    errdefer self.allocator.free(name);

                    try items.append(self.allocator, .{
                        .name = name,
                        .is_directory = child.is_directory,
                        .size = if (child.is_directory)
                            0
                        else
                            entry.content.byte_count,
                    });
                }

                std.mem.sort(
                    DirItem,
                    items.items,
                    @as(*const Api, &self.api),
                    DirItem.lessThan,
                );

                for (items.items, 0..) |item, index| {
                    if (index == 0) continue;

                    const previous = items.items[index - 1];

                    if (self.api.PrjFileNameCompare(
                        previous.name.ptr,
                        item.name.ptr,
                    ) != 0) {
                        continue;
                    }

                    if (!previous.is_directory or !item.is_directory) {
                        return error.InvalidNamespace;
                    }
                }

                var kept: usize = 0;

                for (items.items) |item| {
                    if (kept != 0 and self.api.PrjFileNameCompare(
                        items.items[kept - 1].name.ptr,
                        item.name.ptr,
                    ) == 0) {
                        self.allocator.free(item.name);
                    } else {
                        items.items[kept] = item;
                        kept += 1;
                    }
                }

                items.items.len = kept;

                return items.toOwnedSlice(self.allocator);
            }

            fn isDirectory(
                self: *Self,
                directory: [:0]const u16,
            ) !bool {
                if (directory.len == 0) return true;

                var index: usize = 0;

                while (self.archive.entryAt(index)) |entry| : (index += 1) {
                    const path = try windowsPath(
                        self.allocator,
                        entry.path,
                    );
                    defer self.allocator.free(path);

                    if (childName(&self.api, path, directory) != null) {
                        return true;
                    }
                }

                return false;
            }

            fn startDirectory(
                self: *Self,
                data: *const CallbackData,
                id: *const GUID,
            ) !void {
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                if (self.sessionIndex(id) != null) {
                    return error.InvalidEnumeration;
                }

                const directory = try callbackPath(data);
                const items = try self.directoryItems(directory);

                errdefer {
                    for (items) |item| self.allocator.free(item.name);
                    self.allocator.free(items);
                }

                try self.sessions.append(self.allocator, .{
                    .id = id.*,
                    .items = items,
                });
            }

            fn onStartDirectory(
                data: *const CallbackData,
                id: *const GUID,
            ) callconv(.winapi) HRESULT {
                context(data).startDirectory(data, id) catch |err| {
                    return failure(err);
                };

                return 0;
            }

            fn onEndDirectory(
                data: *const CallbackData,
                id: *const GUID,
            ) callconv(.winapi) HRESULT {
                const self = context(data);

                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                if (self.sessionIndex(id)) |index| {
                    var session = self.sessions.swapRemove(index);
                    session.deinit(self.allocator);
                }

                return 0;
            }

            fn getDirectory(
                self: *Self,
                data: *const CallbackData,
                id: *const GUID,
                search: ?[*:0]const u16,
                buffer: Handle,
            ) !HRESULT {
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                const index = self.sessionIndex(id) orelse {
                    return error.NotFound;
                };

                const session = &self.sessions.items[index];

                if (session.pattern == null or
                    data.Flags & ENUM_RESTART_SCAN != 0)
                {
                    try session.setPattern(self.allocator, search);
                }

                var added: usize = 0;

                while (session.cursor < session.items.len) {
                    const item = &session.items[session.cursor];

                    if (self.api.PrjFileNameMatch(
                        item.name.ptr,
                        session.pattern.?.ptr,
                    ) == 0) {
                        session.cursor += 1;
                        continue;
                    }

                    const info = try basicInfo(
                        item.is_directory,
                        item.size,
                    );

                    const result = self.api.PrjFillDirEntryBuffer(
                        item.name.ptr,
                        &info,
                        buffer,
                    );

                    if (result == hresult(ERROR_INSUFFICIENT_BUFFER)) {
                        return if (added == 0) result else 0;
                    }

                    if (result < 0) return result;

                    session.cursor += 1;
                    added += 1;

                    if (data.Flags & ENUM_RETURN_SINGLE_ENTRY != 0) {
                        break;
                    }
                }

                return 0;
            }

            fn onGetDirectory(
                data: *const CallbackData,
                id: *const GUID,
                search: ?[*:0]const u16,
                buffer: Handle,
            ) callconv(.winapi) HRESULT {
                return context(data).getDirectory(
                    data,
                    id,
                    search,
                    buffer,
                ) catch |err| failure(err);
            }

            fn getPlaceholder(
                self: *Self,
                data: *const CallbackData,
            ) !HRESULT {
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                const path_w = try callbackPath(data);
                const path = try archivePath(self.allocator, path_w);
                defer self.allocator.free(path);

                var info = std.mem.zeroes(PlaceholderInfo);

                if (self.archive.find(path)) |entry| {
                    info.FileBasicInfo = try basicInfo(
                        false,
                        entry.byte_count,
                    );
                } else if (try self.isDirectory(path_w)) {
                    info.FileBasicInfo = try basicInfo(true, 0);
                } else {
                    return error.NotFound;
                }

                return self.api.PrjWritePlaceholderInfo(
                    data.NamespaceVirtualizationContext,
                    path_w.ptr,
                    &info,
                    @sizeOf(PlaceholderInfo),
                );
            }

            fn onGetPlaceholder(
                data: *const CallbackData,
            ) callconv(.winapi) HRESULT {
                return context(data).getPlaceholder(data) catch |err| {
                    return failure(err);
                };
            }

            fn getFileData(
                self: *Self,
                data: *const CallbackData,
                offset: u64,
                length: u32,
            ) !HRESULT {
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                const path_w = try callbackPath(data);
                const path = try archivePath(self.allocator, path_w);
                defer self.allocator.free(path);

                const entry = self.archive.find(path) orelse {
                    return error.NotFound;
                };

                const root = entry.root orelse return 0;

                if (length == 0 or offset >= entry.byte_count) return 0;

                var instance = std.mem.zeroes(VirtualizationInstanceInfo);

                const query_result = self.api.PrjGetVirtualizationInstanceInfo(
                    data.NamespaceVirtualizationContext,
                    &instance,
                );

                if (query_result < 0) return query_result;

                const alignment: u64 = instance.WriteAlignment;
                if (alignment == 0) return error.InvalidAlignment;

                var position = offset - offset % alignment;

                var end = offset + @min(
                    @as(u64, length),
                    entry.byte_count - offset,
                );

                const remainder = end % alignment;

                if (remainder != 0) {
                    end += @min(
                        alignment - remainder,
                        entry.byte_count - end,
                    );
                }

                const preferred: u64 = 64 * 1024;
                const capacity: usize = @intCast(
                    @max(@as(u64, 1), preferred / alignment) * alignment,
                );

                const allocation = self.api.PrjAllocateAlignedBuffer(
                    data.NamespaceVirtualizationContext,
                    capacity,
                ) orelse return error.OutOfMemory;
                defer self.api.PrjFreeAlignedBuffer(allocation);

                const bytes = @as([*]u8, @ptrCast(allocation))[0..capacity];

                while (position < end) {
                    const count: usize = @intCast(@min(
                        @as(u64, @intCast(bytes.len)),
                        end - position,
                    ));

                    const read_count = try self.archive.readRange(
                        root,
                        position,
                        bytes[0..count],
                    );

                    if (read_count != count) {
                        return error.UnexpectedEndOfContent;
                    }

                    const result = self.api.PrjWriteFileData(
                        data.NamespaceVirtualizationContext,
                        &data.DataStreamId,
                        allocation,
                        position,
                        @intCast(count),
                    );

                    if (result < 0) return result;

                    position += count;
                }

                return 0;
            }

            fn onGetFileData(
                data: *const CallbackData,
                offset: u64,
                length: u32,
            ) callconv(.winapi) HRESULT {
                return context(data).getFileData(
                    data,
                    offset,
                    length,
                ) catch |err| failure(err);
            }

            fn notify(
                self: *Self,
                data: *const CallbackData,
                is_directory: bool,
                notification: u32,
                destination: ?[*:0]const u16,
            ) !void {
                const deleted = notification & FILE_CLOSED_DELETED != 0;
                const renamed = notification & FILE_RENAMED != 0;
                const modified = notification & FILE_CLOSED_MODIFIED != 0;

                if (!deleted and !renamed and
                    (!modified or is_directory))
                {
                    return;
                }

                AcquireSRWLockExclusive(&self.mutation_lock);
                defer ReleaseSRWLockExclusive(&self.mutation_lock);

                const path_w = try callbackPath(data);
                const path = try archivePath(self.allocator, path_w);
                defer self.allocator.free(path);

                if (deleted) {
                    AcquireSRWLockExclusive(&self.lock);
                    defer ReleaseSRWLockExclusive(&self.lock);

                    try self.archive.remove(path, is_directory);
                    return;
                }

                if (renamed) {
                    const target = destination orelse {
                        return error.MissingDestination;
                    };

                    const target_path = try archivePath(
                        self.allocator,
                        std.mem.span(target),
                    );
                    defer self.allocator.free(target_path);

                    AcquireSRWLockExclusive(&self.lock);
                    defer ReleaseSRWLockExclusive(&self.lock);

                    try self.archive.rename(
                        path,
                        target_path,
                        is_directory,
                    );
                    return;
                }

                const full_path = try joinPath(
                    self.allocator,
                    self.root_path,
                    path_w,
                );
                defer self.allocator.free(full_path);

                const bytes = try self.load_file(
                    self.allocator,
                    full_path,
                );
                defer self.allocator.free(bytes);

                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);

                try self.archive.writeFile(path, bytes);
            }

            fn onNotification(
                data: *const CallbackData,
                is_directory: u8,
                notification: u32,
                destination: ?[*:0]const u16,
                _: ?*NotificationParameters,
            ) callconv(.winapi) HRESULT {
                const self = context(data);

                self.notify(
                    data,
                    is_directory != 0,
                    notification,
                    destination,
                ) catch |err| {
                    self.recordNotificationError(err);
                };

                return 0;
            }
        };
    }
};

test "archivePath" {
    const allocator = std.testing.allocator;

    {
        const path = std.unicode.utf8ToUtf16LeStringLiteral(
            "directory\\file.txt",
        );

        const result = try archivePath(allocator, path);
        defer allocator.free(result);

        try std.testing.expectEqualSlices(
            u8,
            "directory/file.txt",
            result,
        );
    }

    {
        const path = std.unicode.utf8ToUtf16LeStringLiteral("");

        const result = try archivePath(allocator, path);
        defer allocator.free(result);

        try std.testing.expectEqualSlices(u8, "", result);
    }
}

test "windowsPath" {
    const allocator = std.testing.allocator;

    {
        const result = try windowsPath(allocator, "directory/file.txt");
        defer allocator.free(result);

        const expected = std.unicode.utf8ToUtf16LeStringLiteral(
            "directory\\file.txt",
        );

        try std.testing.expectEqualSlices(u16, expected, result);
    }

    {
        const result = try windowsPath(allocator, "");
        defer allocator.free(result);

        try std.testing.expectEqual(@as(usize, 0), result.len);
        try std.testing.expectEqual(@as(u16, 0), result.ptr[0]);
    }
}

test "joinPath" {
    const allocator = std.testing.allocator;

    {
        const directory = std.unicode.utf8ToUtf16LeStringLiteral(
            "C:\\mount",
        );
        const relative = std.unicode.utf8ToUtf16LeStringLiteral(
            "dir\\file",
        );

        const result = try joinPath(allocator, directory, relative);
        defer allocator.free(result);

        const expected = std.unicode.utf8ToUtf16LeStringLiteral(
            "C:\\mount\\dir\\file",
        );

        try std.testing.expectEqualSlices(u16, expected, result);
    }

    {
        const directory = std.unicode.utf8ToUtf16LeStringLiteral(
            "C:\\mount\\",
        );
        const relative = std.unicode.utf8ToUtf16LeStringLiteral("file");

        const result = try joinPath(allocator, directory, relative);
        defer allocator.free(result);

        const expected = std.unicode.utf8ToUtf16LeStringLiteral(
            "C:\\mount\\file",
        );

        try std.testing.expectEqualSlices(u16, expected, result);
    }
}

test "Mount" {
    if (builtin.os.tag != .windows) {
        const Archive = struct {};
        var archive: Archive = .{};

        const Loader = struct {
            fn load(
                _: std.mem.Allocator,
                _: [:0]const u16,
            ) anyerror![]u8 {
                return error.LoaderMustNotBeCalled;
            }
        };

        try std.testing.expectError(
            error.UnsupportedPlatform,
            Mount(Archive).start(
                std.testing.allocator,
                &archive,
                "unused",
                Loader.load,
            ),
        );
    } else {
        return error.SkipZigTest;
    }
}

test "markDirectory" {
    if (builtin.os.tag != .windows) {
        const instance_id = std.mem.zeroes(InstanceId);

        try std.testing.expectError(
            error.UnsupportedPlatform,
            markDirectory(
                std.testing.allocator,
                "unused",
                &instance_id,
            ),
        );
    } else {
        return error.SkipZigTest;
    }
}

test "childName" {
    if (builtin.os.tag == .windows) {
        const allocator = std.testing.allocator;

        var api = Windows.Api.load() catch |err| switch (err) {
            error.ProjFsUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer api.deinit();

        {
            const path = try windowsPath(
                allocator,
                "Directory/file.txt",
            );
            defer allocator.free(path);

            const directory = try windowsPath(allocator, "directory");
            defer allocator.free(directory);

            const child = Windows.childName(
                &api,
                path,
                directory,
            ) orelse return error.MissingChild;

            const expected = std.unicode.utf8ToUtf16LeStringLiteral(
                "file.txt",
            );

            try std.testing.expectEqualSlices(u16, expected, child.name);
            try std.testing.expect(!child.is_directory);
        }

        {
            const path = try windowsPath(
                allocator,
                "dir/sub/file.txt",
            );
            defer allocator.free(path);

            const directory = try windowsPath(allocator, "dir");
            defer allocator.free(directory);

            const child = Windows.childName(
                &api,
                path,
                directory,
            ) orelse return error.MissingChild;

            const expected = std.unicode.utf8ToUtf16LeStringLiteral("sub");

            try std.testing.expectEqualSlices(u16, expected, child.name);
            try std.testing.expect(child.is_directory);
        }

        {
            const path = try windowsPath(
                allocator,
                "directory/file.txt",
            );
            defer allocator.free(path);

            const directory = try windowsPath(allocator, "dir");
            defer allocator.free(directory);

            try std.testing.expect(
                Windows.childName(&api, path, directory) == null,
            );
        }
    } else {
        return error.SkipZigTest;
    }
}

test "Session" {
    if (builtin.os.tag == .windows) {
        const allocator = std.testing.allocator;

        {
            var session = Windows.Session{
                .id = std.mem.zeroes(InstanceId),
                .items = try allocator.alloc(Windows.DirItem, 0),
            };
            defer session.deinit(allocator);

            try session.setPattern(allocator, null);

            const wildcard = std.unicode.utf8ToUtf16LeStringLiteral("*");

            try std.testing.expectEqualSlices(
                u16,
                wildcard,
                session.pattern.?,
            );

            session.cursor = 12;

            const search = std.unicode.utf8ToUtf16LeStringLiteral("*.txt");
            try session.setPattern(allocator, search);

            try std.testing.expectEqual(@as(usize, 0), session.cursor);
            try std.testing.expectEqualSlices(
                u16,
                search,
                session.pattern.?,
            );
        }
    } else {
        return error.SkipZigTest;
    }
}