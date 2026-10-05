const std = @import("std");
const builtin = @import("builtin");
const fs_mod = @import("fs.zig");
const tfs = @import("tfs");

pub const HRESULT = i32;
pub const Handle = ?*anyopaque;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const FILE_ATTRIBUTE_READONLY: u32 = 0x1;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

pub const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
pub const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000000C;

pub const ENUM_RESTART_SCAN: u32 = 0x1;
pub const ENUM_RETURN_SINGLE_ENTRY: u32 = 0x2;

pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_SHARING_VIOLATION: u32 = 32;
pub const ERROR_NO_MORE_FILES: u32 = 18;
pub const ERROR_GEN_FAILURE: u32 = 31;
pub const ERROR_INVALID_PARAMETER: u32 = 87;
pub const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
pub const ERROR_REPARSE_POINT_ENCOUNTERED: u32 = 4390;

pub const NOTIFICATION_FILE_OPENED: u32 = 0x2;
pub const NOTIFICATION_NEW_FILE_CREATED: u32 = 0x4;
pub const NOTIFICATION_FILE_OVERWRITTEN: u32 = 0x8;
pub const NOTIFICATION_PRE_DELETE: u32 = 0x10;
pub const NOTIFICATION_PRE_RENAME: u32 = 0x20;
pub const NOTIFICATION_FILE_RENAMED: u32 = 0x80;
pub const NOTIFICATION_FILE_HANDLE_CLOSED_NO_MODIFICATION: u32 = 0x200;
pub const NOTIFICATION_FILE_HANDLE_CLOSED_FILE_MODIFIED: u32 = 0x400;
pub const NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED: u32 = 0x800;

pub const UPDATE_ALLOW_DIRTY_META: u32 = 0x1;
pub const UPDATE_ALLOW_DIRTY_DATA: u32 = 0x2;

pub const FILE_STATE_PLACEHOLDER: u32 = 0x1;
pub const FILE_STATE_HYDRATED_PLACEHOLDER: u32 = 0x2;
pub const FILE_STATE_DIRTY_PLACEHOLDER: u32 = 0x4;
pub const FILE_STATE_FULL: u32 = 0x8;
pub const FILE_STATE_TOMBSTONE: u32 = 0x10;

pub fn fileStateName(state: u32) []const u8 {
    return switch (state) {
        FILE_STATE_PLACEHOLDER => "PLACEHOLDER",
        FILE_STATE_HYDRATED_PLACEHOLDER => "HYDRATED",
        FILE_STATE_DIRTY_PLACEHOLDER => "DIRTY",
        FILE_STATE_FULL => "FULL",
        FILE_STATE_TOMBSTONE => "TOMBSTONE",
        else => "UNKNOWN",
    };
}

pub const INVALID_HANDLE_VALUE: Handle = @ptrFromInt(std.math.maxInt(usize));

comptime {
    if (NOTIFICATION_FILE_HANDLE_CLOSED_FILE_MODIFIED != 0x400 or
        NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED != 0x800 or
        NOTIFICATION_PRE_DELETE != 0x10 or
        NOTIFICATION_FILE_RENAMED != 0x80)
    {
        @compileError("notification masks must match PRJ_NOTIFICATION");
    }
}

pub const FILETIME = extern struct {
    low: u32,
    high: u32,
};

pub const WIN32_FIND_DATAW = extern struct {
    FileAttributes: u32,
    CreationTime: FILETIME,
    LastAccessTime: FILETIME,
    LastWriteTime: FILETIME,
    FileSizeHigh: u32,
    FileSizeLow: u32,
    Reserved0: u32,
    Reserved1: u32,
    FileName: [260]u16,
    AlternateFileName: [14]u16,
};

pub const SRWLOCK = extern struct {
    Ptr: ?*anyopaque = null,
};

pub const VersionInfo = extern struct {
    ProviderID: [128]u8,
    ContentID: [128]u8,

    const content_format = "tfs-content-id-v1";
};

pub const CallbackData = extern struct {
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

pub const FileBasicInfo = extern struct {
    IsDirectory: u8,
    FileSize: i64,
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    FileAttributes: u32,
};

pub const PlaceholderInfo = extern struct {
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

pub const NotificationParameters = extern union {
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

pub const NotificationMapping = extern struct {
    NotificationBitMask: u32,
    NotificationRoot: [*:0]const u16,
};

pub const StartOptions = extern struct {
    Flags: u32,
    PoolThreadCount: u32,
    ConcurrentThreadCount: u32,
    NotificationMappings: ?[*]NotificationMapping,
    NotificationMappingsCount: u32,
};

pub const VirtualizationInstanceInfo = extern struct {
    InstanceID: GUID,
    WriteAlignment: u32,
};

pub const Callbacks = extern struct {
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

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (ctrl_type: u32) callconv(.winapi) i32,
    add: i32,
) callconv(.winapi) i32;

pub extern "kernel32" fn FindFirstFileW(
    file_name: [*:0]const u16,
    data: *WIN32_FIND_DATAW,
) callconv(.winapi) Handle;

pub extern "kernel32" fn FindNextFileW(
    find: Handle,
    data: *WIN32_FIND_DATAW,
) callconv(.winapi) i32;

pub extern "kernel32" fn FindClose(
    find: Handle,
) callconv(.winapi) i32;

pub extern "kernel32" fn DeleteFileW(
    path: [*:0]const u16,
) callconv(.winapi) i32;

pub extern "kernel32" fn RemoveDirectoryW(
    path: [*:0]const u16,
) callconv(.winapi) i32;

pub extern "kernel32" fn SetFileAttributesW(
    path: [*:0]const u16,
    attributes: u32,
) callconv(.winapi) i32;

pub extern "kernel32" fn LoadLibraryExW(
    name: [*:0]const u16,
    file: Handle,
    flags: u32,
) callconv(.winapi) Handle;

pub extern "kernel32" fn GetProcAddress(
    module: *anyopaque,
    name: [*:0]const u8,
) callconv(.winapi) ?*const anyopaque;

pub extern "kernel32" fn FreeLibrary(
    module: *anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn GetFullPathNameW(
    path: [*:0]const u16,
    capacity: u32,
    buffer: ?[*]u16,
    file_part: ?*?[*]u16,
) callconv(.winapi) u32;

pub extern "kernel32" fn AcquireSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(.winapi) void;

pub extern "kernel32" fn ReleaseSRWLockExclusive(
    lock: *SRWLOCK,
) callconv(.winapi) void;

pub extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: u32,
    share_mode: u32,
    security: ?*anyopaque,
    creation_disposition: u32,
    flags_and_attributes: u32,
    template: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn ReadFile(
    file: ?*anyopaque,
    buffer: [*]u8,
    count: u32,
    read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;

pub extern "kernel32" fn GetFileSize(
    file: ?*anyopaque,
    high: ?*u32,
) callconv(.winapi) u32;

extern "kernel32" fn GetFileInformationByHandleEx(Handle, u32, *anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn SetFileInformationByHandle(Handle, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn GetFileSizeEx(Handle, *i64) callconv(.winapi) i32;

const AttributeTagInfo = extern struct { attributes: u32, tag: u32 };
const projfs_tag = 0x9000001C;
const generic_read = 0x80000000;
const delete_access = 0x00010000;
const open_reparse_point = 0x00200000;
const backup_semantics = 0x02000000;

fn cleanPlaceholderState(state: u32) bool {
    const clean = FILE_STATE_PLACEHOLDER | FILE_STATE_HYDRATED_PLACEHOLDER;
    return state != 0 and state & ~@as(u32, clean) == 0;
}

fn cleanupComponentValid(name: []const u8) bool {
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) return false;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    for (name) |byte| {
        // Also reject DOS short-name aliases: ownership of their long name is unknown.
        if (byte < 32 or std.mem.indexOfScalar(u8, "\\/:\"<>|?*~", byte) != null) return false;
    }
    var stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    stem = std.mem.trimEnd(u8, stem, " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    }
    if (stem.len >= 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        const suffix = stem[3..];
        if ((suffix.len == 1 and suffix[0] >= '0' and suffix[0] <= '9') or
            std.mem.eql(u8, suffix, "¹") or std.mem.eql(u8, suffix, "²") or std.mem.eql(u8, suffix, "³")) return false;
    }
    return true;
}

// After virtualization stops, opening an unmaterialized namespace path can
// return ERROR_FILE_SYSTEM_VIRTUALIZATION_UNAVAILABLE instead of FILE_NOT_FOUND.
// Confirm absence in the on-disk directory; the error alone is not proof.
fn cleanupChildPresent(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) !bool {
    const pattern = try std.mem.concat(gpa, u8, &.{ parent, "\\*" });
    defer gpa.free(pattern);
    const wide = try utf8Path(gpa, pattern);
    defer gpa.free(wide);
    const target = try utf8Path(gpa, name);
    defer gpa.free(target);
    var data: WIN32_FIND_DATAW = undefined;
    const find = FindFirstFileW(wide.ptr, &data);
    if (find == INVALID_HANDLE_VALUE) {
        if (GetLastError() == ERROR_FILE_NOT_FOUND) return false;
        return cleanupWin32Failure("enumerate parent");
    }
    defer _ = FindClose(find);
    while (true) {
        if (std.os.windows.eqlIgnoreCaseWtf16(std.mem.sliceTo(&data.FileName, 0), target)) return true;
        if (FindNextFileW(find, &data) == 0) {
            if (GetLastError() == ERROR_NO_MORE_FILES) return false;
            return cleanupWin32Failure("enumerate next child");
        }
    }
}

fn cleanupWin32Failure(operation: []const u8) error{CleanupWin32Failed} {
    std.log.warn("cleanup {s} failed (Win32 {d}); retained", .{ operation, GetLastError() });
    return error.CleanupWin32Failed;
}

fn cleanupAttributes(handle: Handle) !AttributeTagInfo {
    var info: AttributeTagInfo = undefined;
    if (GetFileInformationByHandleEx(handle, 9, &info, @sizeOf(AttributeTagInfo)) == 0)
        return cleanupWin32Failure("FileAttributeTagInfo");
    if (info.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 and info.tag != projfs_tag)
        return error.UnsafeReparsePoint;
    return info;
}

fn cleanupCheckStreams(handle: Handle) !void {
    // FileStreamInfo is queried on the locked object, never by pathname. A bounded
    // buffer is intentional: overflow or unsupported queries retain the file.
    var buffer: [65536]u8 align(8) = undefined;
    if (GetFileInformationByHandleEx(handle, 7, &buffer, buffer.len) == 0) {
        if (GetLastError() == 38) return; // ERROR_HANDLE_EOF: no streams (directories).
        return cleanupWin32Failure("FileStreamInfo");
    }
    const next = std.mem.readInt(u32, buffer[0..4], .little);
    const name_len = std.mem.readInt(u32, buffer[4..8], .little);
    const unnamed = std.unicode.utf8ToUtf16LeStringLiteral("::$DATA");
    if (next != 0 or name_len != unnamed.len * 2 or
        !std.mem.eql(u8, buffer[24..][0 .. unnamed.len * 2], std.mem.sliceAsBytes(unnamed)))
        return error.AlternateDataStreams;
}

fn cleanupDisposition(handle: Handle) !void {
    const disposition = extern struct { delete_file: u8 }{ .delete_file = 1 };
    if (SetFileInformationByHandle(handle, 4, &disposition, @sizeOf(@TypeOf(disposition))) == 0)
        return cleanupWin32Failure("FileDispositionInfo");
}

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;

pub extern "kernel32" fn GetFileAttributesW(
    path: [*:0]const u16,
) callconv(.winapi) u32;

pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

pub extern "kernel32" fn MoveFileExW(
    existing: [*:0]const u16,
    new: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;

pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
pub const MOVEFILE_COPY_ALLOWED: u32 = 0x2;

pub const Api = struct {
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

    PrjDeleteFile: *const fn (
        Handle,
        [*:0]const u16,
        u32,
        ?*u32,
    ) callconv(.winapi) HRESULT,

    PrjFileNameMatch: *const fn (
        [*:0]const u16,
        [*:0]const u16,
    ) callconv(.winapi) u8,

    PrjFileNameCompare: *const fn (
        [*:0]const u16,
        [*:0]const u16,
    ) callconv(.winapi) i32,

    PrjGetOnDiskFileState: *const fn (
        [*:0]const u16,
        *u32,
    ) callconv(.winapi) HRESULT,

    pub fn load() !Api {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("ProjectedFSLib.dll");
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

    pub fn deinit(self: *Api) void {
        _ = FreeLibrary(self.module);
        self.* = undefined;
    }
};

pub fn hresult(code: u32) HRESULT {
    if (code == 0) return 0;
    return @bitCast(@as(u32, 0x80070000) | (code & 0xffff));
}

pub fn hresultFromError(err: anyerror) HRESULT {
    return switch (err) {
        error.NotFound, error.UnknownNode => hresult(ERROR_FILE_NOT_FOUND),
        error.AccessDenied, error.RootImmutable => hresult(ERROR_ACCESS_DENIED),
        error.FileOpen => hresult(ERROR_SHARING_VIOLATION),
        error.DirectoryNotEmpty => hresult(ERROR_ACCESS_DENIED),
        else => @bitCast(@as(u32, 0x80004005)),
    };
}

fn wideToUtf8(gpa: std.mem.Allocator, path: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, path);
}

fn utf8Path(gpa: std.mem.Allocator, path: []const u8) ![:0]u16 {
    const result = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);

    for (result) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }

    return result;
}

fn splitRelative(gpa: std.mem.Allocator, path_w: [*:0]const u16) ![][]const u8 {
    const text = std.mem.span(path_w);
    var relative = text;
    if (relative.len > 0 and relative[0] == '\\') relative = relative[1..];

    var components: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (components.items) |component| gpa.free(component);
        components.deinit(gpa);
    }

    var iterator = std.mem.splitScalar(u16, relative, '\\');
    while (iterator.next()) |part| {
        if (part.len == 0) continue;
        const utf8 = try wideToUtf8(gpa, part);
        errdefer gpa.free(utf8);
        try components.append(gpa, utf8);
    }

    return components.toOwnedSlice(gpa);
}

fn freeComponents(gpa: std.mem.Allocator, components: [][]const u8) void {
    for (components) |component| gpa.free(component);
    gpa.free(components);
}

fn absolutePath(gpa: std.mem.Allocator, directory: []const u8) ![:0]u16 {
    const wide = try utf8Path(gpa, directory);
    defer gpa.free(wide);

    const capacity = GetFullPathNameW(wide.ptr, 0, null, null);
    if (capacity == 0) return error.PathResolutionFailed;

    const buffer = try gpa.allocSentinel(u16, capacity, 0);
    defer gpa.free(buffer);

    const length = GetFullPathNameW(wide.ptr, capacity, buffer.ptr, null);
    if (length == 0 or length >= capacity) return error.PathResolutionFailed;

    return gpa.dupeZ(u16, buffer[0..length]);
}

pub fn Mount(comptime FsT: type) type {
    return if (builtin.os.tag == .windows)
        WindowsMount(FsT)
    else
        UnsupportedMount(FsT);
}

fn UnsupportedMount(comptime FsT: type) type {
    _ = FsT;
    return struct {
        pub fn run(
            _: std.mem.Allocator,
            _: std.Io,
            _: *fs_mod.Fs(fs_mod.ByteNames),
            _: []const u8,
            _: []const u8,
        ) !void {
            return error.UnsupportedPlatform;
        }
    };
}

// Entries stay owned by the queue while reads run without the callback lock.
// A revision identifies both a pathname and the modification being captured.
const CaptureQueue = struct {
    const Entry = struct { path: []u8, revision: u64 };
    items: std.ArrayList(Entry) = .empty,
    revision: u64 = 0,

    fn deinit(self: *CaptureQueue, gpa: std.mem.Allocator) void {
        for (self.items.items) |entry| gpa.free(entry.path);
        self.items.deinit(gpa);
    }

    fn nextRevision(self: *CaptureQueue) u64 {
        self.revision += 1;
        return self.revision;
    }

    fn contains(self: *const CaptureQueue, revision: u64) bool {
        for (self.items.items) |entry| {
            if (entry.revision == revision) return true;
        }
        return false;
    }

    fn enqueue(self: *CaptureQueue, gpa: std.mem.Allocator, path: []const u8) !void {
        if (path.len == 0) return error.MissingPath;
        const revision = self.nextRevision();
        for (self.items.items) |*entry| {
            if (std.os.windows.eqlIgnoreCaseWtf8(entry.path, path)) {
                entry.revision = revision;
                return;
            }
        }
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try self.items.append(gpa, .{ .path = owned, .revision = revision });
    }

    fn prefixLength(path: []const u8, parent: []const u8) ?usize {
        if (parent.len == 0) return null;
        var parts = std.mem.splitScalar(u8, path, '\\');
        var parents = std.mem.splitScalar(u8, parent, '\\');
        var length: usize = 0;
        while (parents.next()) |component| {
            const part = parts.next() orelse return null;
            if (!std.os.windows.eqlIgnoreCaseWtf8(part, component)) return null;
            if (length != 0) length += 1;
            length += part.len;
        }
        return length;
    }

    fn within(path: []const u8, parent: []const u8) bool {
        return prefixLength(path, parent) != null;
    }

    fn remove(self: *CaptureQueue, gpa: std.mem.Allocator, revision: u64) void {
        for (self.items.items, 0..) |entry, index| {
            if (entry.revision == revision) {
                gpa.free(self.items.orderedRemove(index).path);
                return;
            }
        }
    }

    fn removePrefix(self: *CaptureQueue, gpa: std.mem.Allocator, path: []const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (within(self.items.items[index].path, path)) {
                gpa.free(self.items.orderedRemove(index).path);
            } else index += 1;
        }
    }

    fn rename(self: *CaptureQueue, gpa: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
        var replacement: CaptureQueue = .{ .revision = self.revision };
        errdefer replacement.deinit(gpa);
        for (self.items.items) |entry| {
            const prefix = prefixLength(entry.path, source);
            const moved = prefix != null;
            if (!moved and within(entry.path, destination)) continue;
            const path = if (prefix) |length|
                try std.mem.concat(gpa, u8, &.{ destination, entry.path[length..] })
            else
                try gpa.dupe(u8, entry.path);
            errdefer gpa.free(path);
            try replacement.items.append(gpa, .{
                .path = path,
                .revision = if (moved) replacement.nextRevision() else entry.revision,
            });
        }
        self.deinit(gpa);
        self.* = replacement;
    }
};

fn WindowsMount(comptime FsT: type) type {
    return struct {
        const Self = @This();
        const InstanceId = GUID;

        const DirItem = struct {
            name: [:0]const u16,
            is_directory: bool,
            size: u64,

            fn lessThan(api: *const Api, left: DirItem, right: DirItem) bool {
                return api.PrjFileNameCompare(left.name.ptr, right.name.ptr) < 0;
            }
        };

        const Session = struct {
            id: InstanceId,
            items: []DirItem,
            cursor: usize = 0,
            pattern: ?[:0]const u16 = null,

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

        gpa: std.mem.Allocator,
        io: std.Io,
        fs: *FsT,
        api: Api,
        root_wide: [:0]u16,
        root_utf8: []u8,
        handle: Handle = null,
        sessions: std.ArrayList(Session) = .empty,
        pending: CaptureQueue = .{},
        tracking_failed: bool = false,
        lock: SRWLOCK = .{},
        notification_mapping: NotificationMapping = undefined,
        cache_content: ?tfs.ContentId = null,
        cache_bytes: []u8 = &.{},
        instance_alignment: u64 = 4096,
        dirty: std.atomic.Value(bool) = .init(false),

        exe_path: []const u8,
        helper: ?std.process.Child = null,

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

        var g_shutdown = std.atomic.Value(bool).init(false);

        fn consoleCtrlHandler(ctrl_type: u32) callconv(.winapi) i32 {
            _ = ctrl_type;
            g_shutdown.store(true, .release);
            return 1;
        }

        fn context(data: *const CallbackData) *Self {
            return @ptrCast(@alignCast(data.InstanceContext.?));
        }

        fn callbackPath(data: *const CallbackData) ![:0]const u16 {
            const path = data.FilePathName orelse return error.MissingPath;
            return std.mem.span(path);
        }

        fn basicInfo(is_directory: bool, size: u64) !FileBasicInfo {
            var info = std.mem.zeroes(FileBasicInfo);
            info.IsDirectory = @intFromBool(is_directory);
            info.FileSize = std.math.cast(i64, size) orelse return error.FileTooLarge;
            info.FileAttributes = if (is_directory)
                FILE_ATTRIBUTE_DIRECTORY
            else
                FILE_ATTRIBUTE_NORMAL;
            return info;
        }

        fn resolveNode(self: *Self, path_w: [*:0]const u16) !fs_mod.NodeId {
            const components = try splitRelative(self.gpa, path_w);
            defer freeComponents(self.gpa, components);
            return self.fs.resolve(.root, components);
        }

        fn ensureNode(self: *Self, path_w: [*:0]const u16) !fs_mod.NodeId {
            const components = try splitRelative(self.gpa, path_w);
            defer freeComponents(self.gpa, components);
            if (components.len == 0) return .root;

            var node = fs_mod.NodeId.root;
            for (components[0 .. components.len - 1]) |component| {
                node = self.fs.lookup(node, component) catch |err| switch (err) {
                    error.NotFound => try self.fs.createDirectory(node, component),
                    else => return err,
                };
            }

            const name = components[components.len - 1];
            return self.fs.lookup(node, name) catch |err| switch (err) {
                error.NotFound => try self.fs.createFile(node, name),
                else => return err,
            };
        }

        fn materialize(self: *Self, content: tfs.ContentId) ![]u8 {
            if (self.cache_content == content) return self.cache_bytes;

            const bytes = try self.fs.writer.get(self.gpa, content);
            if (self.cache_bytes.len > 0) self.gpa.free(self.cache_bytes);
            self.cache_content = content;
            self.cache_bytes = bytes;
            return bytes;
        }

        fn writeAligned(
            self: *Self,
            data: *const CallbackData,
            source: []const u8,
            offset: u64,
            length: u32,
        ) !HRESULT {
            const size: u64 = source.len;
            if (offset >= size) return 0;

            const alignment: u64 = self.instance_alignment;
            if (alignment == 0) return error.InvalidAlignment;

            var position = offset - offset % alignment;

            var end = offset + @min(@as(u64, length), size - offset);
            const remainder = end % alignment;
            if (remainder != 0) {
                end += @min(alignment - remainder, size - end);
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

            const buffer = @as([*]u8, @ptrCast(allocation))[0..capacity];

            while (position < end) {
                const count: usize = @intCast(
                    @min(@as(u64, buffer.len), end - position),
                );
                const start: usize = @intCast(position);
                @memcpy(buffer[0..count], source[start..][0..count]);

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

        fn getFileData(
            self: *Self,
            data: *const CallbackData,
            offset: u64,
            length: u32,
        ) !HRESULT {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);

            const version = data.VersionInfo orelse return error.InvalidPlaceholderVersion;
            if (!std.mem.eql(u8, version.ProviderID[0..VersionInfo.content_format.len], VersionInfo.content_format))
                return error.InvalidPlaceholderVersion;
            const content = tfs.ContentId.fromIndex(std.mem.readInt(u64, version.ContentID[0..8], .little));
            const bytes = try self.materialize(content);
            return self.writeAligned(data, bytes, offset, length);
        }

        fn getPlaceholder(
            self: *Self,
            data: *const CallbackData,
        ) !HRESULT {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);

            const path_w = try callbackPath(data);
            const node = try self.resolveNode(path_w);

            const entry = try self.fs.stat(node);
            var info = std.mem.zeroes(PlaceholderInfo);

            switch (entry.kind) {
                .directory => info.FileBasicInfo = try basicInfo(true, 0),
                .file => |content| {
                    const metadata = self.fs.writer.metadata(content) orelse
                        return error.NotFound;
                    info.FileBasicInfo = try basicInfo(false, metadata.byte_len);
                    @memcpy(info.VersionInfo.ProviderID[0..VersionInfo.content_format.len], VersionInfo.content_format);
                    std.mem.writeInt(u64, info.VersionInfo.ContentID[0..8], content.index(), .little);
                },
            }

            return self.api.PrjWritePlaceholderInfo(
                data.NamespaceVirtualizationContext,
                path_w.ptr,
                &info,
                @sizeOf(PlaceholderInfo),
            );
        }

        fn directoryItems(
            self: *Self,
            path_w: [*:0]const u16,
        ) ![]DirItem {
            const components = try splitRelative(self.gpa, path_w);
            defer freeComponents(self.gpa, components);

            const node = try self.fs.resolve(.root, components);

            var items: std.ArrayList(DirItem) = .empty;
            errdefer {
                for (items.items) |item| self.gpa.free(item.name);
                items.deinit(self.gpa);
            }

            var children = try self.fs.children(node);
            while (children.next()) |entry| {
                const wide = try utf8Path(self.gpa, entry.name);
                errdefer self.gpa.free(wide);

                const is_directory = entry.kind == .directory;
                const size: u64 = if (entry.kind == .file)
                    (self.fs.writer.metadata(entry.kind.file) orelse
                        return error.UnknownContentId).byte_len
                else
                    0;

                try items.append(self.gpa, .{
                    .name = wide,
                    .is_directory = is_directory,
                    .size = size,
                });
            }

            std.mem.sort(DirItem, items.items, &self.api, DirItem.lessThan);
            return items.toOwnedSlice(self.gpa);
        }

        fn startDirectory(
            self: *Self,
            data: *const CallbackData,
            id: *const InstanceId,
        ) !HRESULT {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);

            for (self.sessions.items) |*session| {
                if (std.mem.eql(u8, std.mem.asBytes(&session.id), std.mem.asBytes(id)))
                    return error.InvalidEnumeration;
            }

            const path_w = try callbackPath(data);
            const items = try self.directoryItems(path_w);

            try self.addSession(id.*, items);
            return 0;
        }

        // Takes ownership of items, including when pattern/append allocation fails.
        fn addSession(self: *Self, id: InstanceId, items: []DirItem) !void {
            var session: Session = .{ .id = id, .items = items };
            errdefer session.deinit(self.gpa);
            try session.setPattern(self.gpa, null);
            try self.sessions.append(self.gpa, session);
        }

        fn endDirectory(
            self: *Self,
            id: *const InstanceId,
        ) !HRESULT {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);

            var index: usize = 0;
            while (index < self.sessions.items.len) : (index += 1) {
                if (std.mem.eql(u8, std.mem.asBytes(&self.sessions.items[index].id), std.mem.asBytes(id))) {
                    var session = self.sessions.orderedRemove(index);
                    session.deinit(self.gpa);
                    return 0;
                }
            }

            return 0;
        }

        fn getDirectory(
            self: *Self,
            data: *const CallbackData,
            id: *const InstanceId,
            search: ?[*:0]const u16,
            buffer: Handle,
        ) !HRESULT {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);

            var session: ?*Session = null;
            for (self.sessions.items) |*candidate| {
                if (std.mem.eql(u8, std.mem.asBytes(&candidate.id), std.mem.asBytes(id))) {
                    session = candidate;
                    break;
                }
            }
            const state = session orelse return error.InvalidEnumeration;

            if (data.Flags & ENUM_RESTART_SCAN != 0)
                try state.setPattern(self.gpa, search);

            const single = data.Flags & ENUM_RETURN_SINGLE_ENTRY != 0;
            const pattern: [*:0]const u16 = if (state.pattern) |value|
                value.ptr
            else
                std.unicode.utf8ToUtf16LeStringLiteral("*");

            while (state.cursor < state.items.len) {
                const item = state.items[state.cursor];

                if (self.api.PrjFileNameMatch(item.name.ptr, pattern) == 0) {
                    state.cursor += 1;
                    continue;
                }

                const info = try basicInfo(item.is_directory, item.size);
                const result = self.api.PrjFillDirEntryBuffer(
                    item.name.ptr,
                    &info,
                    buffer,
                );

                if (result == hresult(ERROR_INSUFFICIENT_BUFFER)) return 0;
                if (result < 0) return result;

                state.cursor += 1;
                if (single) return 0;
            }

            if (single) return hresult(ERROR_NO_MORE_FILES);
            return 0;
        }

        fn captureRelative(self: *Self, relative_utf8: []const u8, revision: u64) !void {
            const full = try std.mem.concat(self.gpa, u8, &.{
                self.root_utf8,
                "\\",
                relative_utf8,
            });
            defer self.gpa.free(full);

            var bytes: ?[]u8 = null;
            var attempt: u32 = 0;
            while (attempt < 12 and bytes == null) : (attempt += 1) {
                if (attempt > 0)
                    std.Io.sleep(self.io, .{ .nanoseconds = 250 * std.time.ns_per_ms }, .real) catch {};
                bytes = self.captureViaChild(full) catch null;
            }

            const captured = bytes orelse {
                std.log.err("child capture never succeeded for {s}", .{relative_utf8});
                return error.ReadFailed;
            };
            defer self.gpa.free(captured);

            try self.publishCapture(relative_utf8, revision, captured);
        }

        fn publishCapture(self: *Self, path: []const u8, revision: u64, captured: []const u8) !void {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);
            if (self.tracking_failed) return error.CaptureTrackingFailed;
            if (!self.pending.contains(revision)) return error.StaleCapture;

            const wide = try utf8Path(self.gpa, path);
            defer self.gpa.free(wide);
            self.dirty.store(true, .release);
            const target = try self.ensureNode(wide.ptr);
            try self.fs.setContent(target, captured);
            self.pending.remove(self.gpa, revision);

            self.cache_content = null;
            if (self.cache_bytes.len > 0) {
                self.gpa.free(self.cache_bytes);
                self.cache_bytes = &.{};
            }
            self.dirty.store(true, .release);
        }

        fn captureViaChild(self: *Self, full: []const u8) ![]u8 {
            if (std.mem.indexOfScalar(u8, full, 0) != null or
                std.mem.indexOfScalar(u8, full, '\n') != null) return error.InvalidName;
            const request = try std.fmt.allocPrint(self.gpa, "{s}\n", .{full});
            defer self.gpa.free(request);

            if (self.helper == null) try self.spawnHelper();
            // An incomplete response cannot be reused for the next request.
            var response_complete = false;
            errdefer if (!response_complete) self.stopHelper();
            try self.helper.?.stdin.?.writeStreamingAll(self.io, request);

            var header: [5]u8 = undefined;
            var total: usize = 0;
            while (total < header.len) {
                const read = try self.helper.?.stdout.?.readStreaming(self.io, &.{header[total..]});
                if (read == 0) return error.EndOfStream;
                total += read;
            }
            if (header[0] > 1) return error.InvalidCaptureResponse;
            const length = std.mem.readInt(u32, header[1..5], .little);
            if (length > fs_mod.max_file_bytes) return error.FileTooLarge;
            if (header[0] == 1 and length == 0) return error.InvalidCaptureResponse;

            const bytes = try self.gpa.alloc(u8, length);
            errdefer self.gpa.free(bytes);
            total = 0;
            while (total < length) {
                const read = try self.helper.?.stdout.?.readStreaming(self.io, &.{bytes[total..]});
                if (read == 0) return error.EndOfStream;
                total += read;
            }
            response_complete = true;
            if (header[0] == 1) {
                std.log.err("capture helper failed for {s}: {s}", .{ full, bytes });
                return error.CaptureFailed;
            }
            return bytes;
        }

        fn spawnHelper(self: *Self) !void {
            self.helper = try std.process.spawn(self.io, .{
                .argv = &.{ self.exe_path, "read-raw", "--serve" },
                // Ctrl+C belongs to the mount, not its capture worker. Keep the
                // helper alive until the final drain completes and stopHelper runs.
                .create_no_window = true,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
        }

        fn stopHelper(self: *Self) void {
            if (self.helper) |*child| {
                child.kill(self.io);
            }
            self.helper = null;
        }

        fn queueCapture(self: *Self, data: *const CallbackData, path_w: [*:0]const u16) !void {
            _ = data;
            const rel8 = try wideToUtf8(self.gpa, std.mem.span(path_w));
            defer self.gpa.free(rel8);

            // notify owns the callback lock, including allocation failure paths.
            try self.pending.enqueue(self.gpa, rel8);
        }

        fn processPending(self: *Self) !void {
            // A finite snapshot gives each entry one turn; failures remain queued
            // for a later pass, rather than spinning forever during shutdown.
            const revisions = blk: {
                SRWAcquire(&self.lock);
                defer SRWRelease(&self.lock);
                if (self.tracking_failed) return error.CaptureTrackingFailed;
                const result = try self.gpa.alloc(u64, self.pending.items.items.len);
                for (self.pending.items.items, result) |entry, *revision| revision.* = entry.revision;
                break :blk result;
            };
            defer self.gpa.free(revisions);

            var first_error: ?anyerror = null;
            for (revisions) |revision| {
                const relative = blk: {
                    SRWAcquire(&self.lock);
                    defer SRWRelease(&self.lock);
                    for (self.pending.items.items) |entry| {
                        if (entry.revision == revision)
                            break :blk try self.gpa.dupe(u8, entry.path);
                    }
                    break :blk null;
                } orelse continue;
                defer self.gpa.free(relative);
                self.captureRelative(relative, revision) catch |err| {
                    if (err == error.StaleCapture) continue;
                    std.log.err("capture retained for retry: {s} ({s})", .{ relative, @errorName(err) });
                    if (first_error == null) first_error = err;
                };
            }
            if (first_error) |err| return err;
        }

        fn commitPending(self: *Self, force: bool) !void {
            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);
            if (!force and !self.dirty.load(.acquire)) return;
            // Clear only after success, under the same lock as all Fs mutations.
            self.dirty.store(true, .release);
            try self.fs.commit();
            self.dirty.store(false, .release);
        }

        fn notify(
            self: *Self,
            data: *const CallbackData,
            is_directory: bool,
            notification: u32,
            destination: ?[*:0]const u16,
        ) !HRESULT {
            if (data.TriggeringProcessId == GetCurrentProcessId()) return 0;

            SRWAcquire(&self.lock);
            defer SRWRelease(&self.lock);
            errdefer self.tracking_failed = true;

            switch (notification) {
                NOTIFICATION_PRE_DELETE => return 0,

                NOTIFICATION_NEW_FILE_CREATED => {
                    if (!is_directory) return 0;
                    const path_w = try callbackPath(data);
                    const components = try splitRelative(self.gpa, path_w);
                    defer freeComponents(self.gpa, components);
                    var parent = fs_mod.NodeId.root;
                    // Record directories even when they never receive a file.
                    for (components) |component| {
                        parent = self.fs.lookup(parent, component) catch |err| switch (err) {
                            error.NotFound => try self.fs.createDirectory(parent, component),
                            else => return err,
                        };
                    }
                    self.dirty.store(true, .release);
                    return 0;
                },

                NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED => {
                    const path_w = try callbackPath(data);
                    const path = try wideToUtf8(self.gpa, path_w);
                    defer self.gpa.free(path);
                    self.pending.removePrefix(self.gpa, path);
                    const node = self.resolveNode(path_w) catch |err| switch (err) {
                        error.NotFound => return 0,
                        else => return err,
                    };
                    try self.fs.remove(node);
                    self.dirty.store(true, .release);
                    return 0;
                },

                NOTIFICATION_FILE_RENAMED => {
                    const source_w = try callbackPath(data);

                    if (destination) |dest_w| {
                        const dest_text = std.mem.span(dest_w);

                        if (source_w.len == 0 and dest_text.len != 0) {
                            if (is_directory) return 0;
                            try self.queueCapture(data, dest_w);
                            return 0;
                        }

                        const source = try wideToUtf8(self.gpa, source_w);
                        defer self.gpa.free(source);
                        const dest = try wideToUtf8(self.gpa, dest_text);
                        defer self.gpa.free(dest);

                        if (dest_text.len == 0) {
                            self.pending.removePrefix(self.gpa, source);
                            const node = self.resolveNode(source_w) catch |err| switch (err) {
                                error.NotFound => return 0,
                                else => return err,
                            };
                            try self.fs.remove(node);
                            self.dirty.store(true, .release);
                            return 0;
                        }

                        try self.pending.rename(self.gpa, source, dest);
                        if (!is_directory) try self.pending.enqueue(self.gpa, dest);

                        const components = try splitRelative(self.gpa, dest_w);
                        defer freeComponents(self.gpa, components);
                        if (components.len == 0) return 0;

                        const node = self.resolveNode(source_w) catch |err| switch (err) {
                            error.NotFound => return 0,
                            else => return err,
                        };
                        const parent = if (components.len == 1)
                            fs_mod.NodeId.root
                        else
                            try self.fs.resolve(.root, components[0 .. components.len - 1]);

                        try self.fs.move(node, parent, components[components.len - 1]);
                        self.dirty.store(true, .release);
                        return 0;
                    }

                    return 0;
                },

                NOTIFICATION_FILE_HANDLE_CLOSED_FILE_MODIFIED => {
                    if (is_directory) return 0;

                    const path_w = try callbackPath(data);
                    try self.queueCapture(data, path_w);
                    return 0;
                },

                else => return 0,
            }
        }

        fn onStartDirectory(data: *const CallbackData, id: *const GUID) callconv(.winapi) HRESULT {
            const self = context(data);

            return invoke(self.startDirectory(data, id));
        }

        fn onEndDirectory(data: *const CallbackData, id: *const GUID) callconv(.winapi) HRESULT {
            const self = context(data);
            return invoke(self.endDirectory(id));
        }

        fn onGetDirectory(
            data: *const CallbackData,
            enumeration_id: *const GUID,
            search: ?[*:0]const u16,
            buffer: Handle,
        ) callconv(.winapi) HRESULT {
            const self = context(data);
            return invoke(self.getDirectory(data, enumeration_id, search, buffer));
        }

        fn onGetPlaceholder(data: *const CallbackData) callconv(.winapi) HRESULT {
            const self = context(data);
            return invoke(self.getPlaceholder(data));
        }

        fn onGetFileData(
            data: *const CallbackData,
            offset: u64,
            length: u32,
        ) callconv(.winapi) HRESULT {
            const self = context(data);
            return invoke(self.getFileData(data, offset, length));
        }

        fn onNotification(
            data: *const CallbackData,
            is_directory: u8,
            notification: u32,
            destination: ?[*:0]const u16,
            parameters: ?*NotificationParameters,
        ) callconv(.winapi) HRESULT {
            _ = parameters;
            const self = context(data);

            return invoke(self.notify(data, is_directory != 0, notification, destination));
        }

        fn invoke(result: anytype) HRESULT {
            const info = @typeInfo(@TypeOf(result));
            if (info == .error_union) {
                return result catch |err| hresultFromError(err);
            }
            return result;
        }

        fn SRWAcquire(lock: *SRWLOCK) void {
            AcquireSRWLockExclusive(lock);
        }

        fn SRWRelease(lock: *SRWLOCK) void {
            ReleaseSRWLockExclusive(lock);
        }

        fn releaseState(self: *Self) void {
            for (self.sessions.items) |*session| session.deinit(self.gpa);
            self.sessions.deinit(self.gpa);

            self.pending.deinit(self.gpa);

            if (self.cache_bytes.len > 0) self.gpa.free(self.cache_bytes);
            self.cache_bytes = &.{};
            self.cache_content = null;
        }

        pub fn run(
            gpa: std.mem.Allocator,
            io: std.Io,
            fs: *FsT,
            directory: []const u8,
            exe_path: []const u8,
        ) !void {
            g_shutdown.store(false, .release);

            var self: Self = .{
                .gpa = gpa,
                .io = io,
                .fs = fs,
                .api = undefined,
                .root_wide = undefined,
                .root_utf8 = undefined,
                .exe_path = exe_path,
            };
            defer self.releaseState();

            self.api = try Api.load();
            defer self.api.deinit();

            try self.spawnHelper();
            defer self.stopHelper();

            try std.Io.Dir.cwd().createDirPath(io, directory);

            self.root_wide = try absolutePath(gpa, directory);
            defer gpa.free(self.root_wide);
            self.root_utf8 = try wideToUtf8(gpa, self.root_wide);
            defer gpa.free(self.root_utf8);

            var instance_id: InstanceId = undefined;
            try std.Io.randomSecure(io, std.mem.asBytes(&instance_id));

            const mark_hr = self.api.PrjMarkDirectoryAsPlaceholder(
                self.root_wide.ptr,
                null,
                null,
                &instance_id,
            );
            if (mark_hr < 0 and
                mark_hr != hresult(ERROR_REPARSE_POINT_ENCOUNTERED))
            {
                std.log.err("PrjMarkDirectoryAsPlaceholder failed: 0x{X:0>8}", .{
                    @as(u32, @bitCast(mark_hr)),
                });
                return error.MountStartFailed;
            }

            var options = std.mem.zeroes(StartOptions);
            self.notification_mapping = .{
                .NotificationBitMask = NOTIFICATION_PRE_DELETE |
                    NOTIFICATION_NEW_FILE_CREATED |
                    NOTIFICATION_FILE_RENAMED |
                    NOTIFICATION_FILE_HANDLE_CLOSED_FILE_MODIFIED |
                    NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED,
                .NotificationRoot = std.unicode.utf8ToUtf16LeStringLiteral(""),
            };
            options.NotificationMappings = @ptrCast(&self.notification_mapping);
            options.NotificationMappingsCount = 1;

            _ = SetConsoleCtrlHandler(consoleCtrlHandler, 1);
            defer _ = SetConsoleCtrlHandler(consoleCtrlHandler, 0);

            const start_hr = self.api.PrjStartVirtualizing(
                self.root_wide.ptr,
                &callbacks,
                @ptrCast(&self),
                &options,
                &self.handle,
            );
            if (start_hr < 0) {
                std.log.err("PrjStartVirtualizing failed: 0x{X:0>8}", .{
                    @as(u32, @bitCast(start_hr)),
                });
                return error.MountStartFailed;
            }

            {
                var instance_info: VirtualizationInstanceInfo = undefined;
                const info_hr = self.api.PrjGetVirtualizationInstanceInfo(
                    self.handle,
                    &instance_info,
                );
                if (info_hr >= 0 and instance_info.WriteAlignment != 0)
                    self.instance_alignment = instance_info.WriteAlignment;
            }

            std.log.info("mounted at {s} - Ctrl+C to unmount", .{self.root_utf8});

            while (!g_shutdown.load(.acquire)) {
                std.Io.sleep(io, .{ .nanoseconds = 250 * std.time.ns_per_ms }, .real) catch {};

                self.processPending() catch |err| {
                    std.log.err("pending captures incomplete ({s}); local files retained", .{@errorName(err)});
                };
                self.commitPending(false) catch |err| {
                    std.log.err("periodic commit failed ({s}); will retry", .{@errorName(err)});
                };
            }

            // Stop and wait for callbacks before the final finite drain. Partly
            // hydrated placeholders may no longer be readable; retain them too.
            try self.finish();
        }

        const CleanupStats = struct {
            removed: usize = 0,
            retained: usize = 0,

            fn failed(stats: *CleanupStats, path: []const u8, err: anyerror) void {
                stats.retained += 1;
                std.log.warn("cleanup retained {s} ({s})", .{ path, @errorName(err) });
            }
        };

        fn cleanupFile(self: *Self, id: fs_mod.NodeId, path: [:0]const u16, handle: Handle, info: AttributeTagInfo) !void {
            try cleanupCheckStreams(handle);
            // Ordinary files must always compare, even if a state query reports a
            // clean placeholder. Only the ProjFS reparse tag can bypass reading.
            if (info.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) {
                var state: u32 = 0;
                const hr = self.api.PrjGetOnDiskFileState(path.ptr, &state);
                if (hr < 0) {
                    std.log.warn("cleanup PrjGetOnDiskFileState failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
                    return error.CleanupStateFailed;
                }
                if (cleanPlaceholderState(state)) return cleanupDisposition(handle);
            }
            var size: i64 = undefined;
            if (GetFileSizeEx(handle, &size) == 0) return cleanupWin32Failure("GetFileSizeEx");
            if (size < 0 or @as(u64, @intCast(size)) != try self.fs.size(id)) return error.ContentMismatch;
            const archived = try self.fs.readFile(id);
            defer self.fs.gpa.free(archived);
            if (archived.len != size) return error.ContentMismatch;
            var buffer: [65536]u8 = undefined;
            var offset: usize = 0;
            while (offset < archived.len) {
                const count = @min(buffer.len, archived.len - offset);
                var read: u32 = 0;
                if (ReadFile(handle, &buffer, @intCast(count), &read, null) == 0)
                    return cleanupWin32Failure("ReadFile");
                if (read == 0 or !std.mem.eql(u8, buffer[0..read], archived[offset..][0..read]))
                    return error.ContentMismatch;
                offset += read;
            }
            try cleanupDisposition(handle);
        }

        fn cleanupEntry(self: *Self, entry: @import("namespace.zig").Entry, parent: []const u8, stats: *CleanupStats) anyerror!void {
            if (!cleanupComponentValid(entry.name)) return error.InvalidWindowsComponent;
            const path = try std.mem.concat(self.gpa, u8, &.{ parent, "\\", entry.name });
            defer self.gpa.free(path);
            const wide = try utf8Path(self.gpa, path);
            defer self.gpa.free(wide);
            const directory = entry.kind == .directory;
            // Directory handles deny write/delete sharing while children are opened
            // by path, preventing reparse mutation or replacement during traversal.
            const handle = CreateFileW(wide.ptr, generic_read | delete_access, if (directory) 1 else 0, null, 3, open_reparse_point | if (directory) @as(u32, backup_semantics) else 0, null);
            if (handle == INVALID_HANDLE_VALUE) {
                const code = GetLastError();
                if (code == ERROR_FILE_NOT_FOUND or code == 3) return;
                const virtualization_unavailable = 369;
                if (code == virtualization_unavailable) {
                    const present = try cleanupChildPresent(self.gpa, parent, entry.name);
                    std.log.debug("cleanup open {s}: Win32 {d}, present in on-disk parent listing: {}", .{ path, code, present });
                    if (!present) return;
                }
                std.log.warn("cleanup open {s} failed (Win32 {d}); retained", .{ path, code });
                return error.CleanupWin32Failed;
            }
            var disposition_set = false;
            defer {
                if (CloseHandle(handle) == 0) {
                    stats.failed(path, cleanupWin32Failure("CloseHandle"));
                } else if (disposition_set) {
                    stats.removed += 1;
                }
            }
            const info = try cleanupAttributes(handle);
            if ((info.attributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory) return error.KindMismatch;
            if (info.attributes & FILE_ATTRIBUTE_READONLY != 0) return error.ReadOnly;
            if (directory) {
                try self.cleanupChildren(entry.id, path, stats);
                try cleanupCheckStreams(handle);
                // Windows refuses disposition on nonempty directories. Unknown
                // children are never enumerated, opened or removed by cleanup.
                try cleanupDisposition(handle);
            } else {
                try self.cleanupFile(entry.id, wide, handle, info);
            }
            disposition_set = true;
        }

        fn cleanupChildren(self: *Self, parent: fs_mod.NodeId, path: []const u8, stats: *CleanupStats) anyerror!void {
            var children = try self.fs.children(parent);
            while (children.next()) |entry| {
                self.cleanupEntry(entry, path, stats) catch |err| stats.failed(entry.name, err);
            }
        }

        fn cleanup(self: *Self, stats: *CleanupStats) !void {
            const root = CreateFileW(self.root_wide.ptr, generic_read, 1, null, 3, backup_semantics | open_reparse_point, null);
            if (root == INVALID_HANDLE_VALUE) return cleanupWin32Failure("open root");
            defer {
                if (CloseHandle(root) == 0) stats.failed(self.root_utf8, cleanupWin32Failure("close root"));
            }
            const info = try cleanupAttributes(root);
            if (info.attributes & FILE_ATTRIBUTE_DIRECTORY == 0) return error.KindMismatch;
            try self.cleanupChildren(.root, self.root_utf8, stats);
        }

        fn finish(self: *Self) !void {
            self.api.PrjStopVirtualizing(self.handle);
            self.handle = null;
            errdefer std.log.warn("unmounted; cleanup incomplete at {s}; retained files require review", .{self.root_utf8});
            var drain_error: ?anyerror = null;
            self.processPending() catch |err| {
                drain_error = err;
            };
            // Persist successful captures even when another capture failed.
            try self.commitPending(true);
            if (drain_error) |err| return err;
            var stats: CleanupStats = .{};
            self.cleanup(&stats) catch |err| stats.failed(self.root_utf8, err);
            std.log.info("cleanup removed {d} namespace entries, retained {d}; unknown paths and mount root left untouched", .{ stats.removed, stats.retained });
            if (stats.retained != 0) return error.CleanupIncomplete;
        }
    };
}

test "notification masks match the documented PRJ_NOTIFICATION values" {
    try std.testing.expectEqual(@as(u32, 0x10), NOTIFICATION_PRE_DELETE);
    try std.testing.expectEqual(@as(u32, 0x80), NOTIFICATION_FILE_RENAMED);
    try std.testing.expectEqual(@as(u32, 0x400), NOTIFICATION_FILE_HANDLE_CLOSED_FILE_MODIFIED);
    try std.testing.expectEqual(@as(u32, 0x800), NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED);
}

test "hresult packs win32 codes and hresultFromError maps fs errors" {
    try std.testing.expectEqual(@as(HRESULT, 0), hresult(0));
    try std.testing.expectEqual(@as(HRESULT, @bitCast(@as(u32, 0x80070002))), hresult(ERROR_FILE_NOT_FOUND));
    try std.testing.expectEqual(hresult(ERROR_FILE_NOT_FOUND), hresultFromError(error.NotFound));
    try std.testing.expectEqual(hresult(ERROR_SHARING_VIOLATION), hresultFromError(error.FileOpen));
    try std.testing.expectEqual(hresult(ERROR_ACCESS_DENIED), hresultFromError(error.RootImmutable));
}

test "utf8Path flips separators and wideToUtf8 round trips" {
    const gpa = std.testing.allocator;

    const wide = try utf8Path(gpa, "some/path");
    defer gpa.free(wide);

    const back = try wideToUtf8(gpa, wide);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("some\\path", back);
}

test "absolutePath excludes the Win32 terminator from the owned slice" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const wide = try absolutePath(gpa, ".");
    defer gpa.free(wide);
    try std.testing.expectEqual(std.mem.span(wide.ptr).len, wide.len);
    const utf8 = try wideToUtf8(gpa, wide);
    defer gpa.free(utf8);
    try std.testing.expect(std.mem.indexOfScalar(u8, utf8, 0) == null);
}

test "splitRelative strips the root separator and skips empty components" {
    const gpa = std.testing.allocator;

    const text = try std.unicode.utf8ToUtf16LeAllocZ(gpa, "\\docs\\notes\\file.txt");
    defer gpa.free(text);

    const components = try splitRelative(gpa, text.ptr);
    defer freeComponents(gpa, components);

    try std.testing.expectEqual(@as(usize, 3), components.len);
    try std.testing.expectEqualStrings("docs", components[0]);
    try std.testing.expectEqualStrings("notes", components[1]);
    try std.testing.expectEqualStrings("file.txt", components[2]);

    const root_text = try std.unicode.utf8ToUtf16LeAllocZ(gpa, "\\");
    defer gpa.free(root_text);
    const root_components = try splitRelative(gpa, root_text.ptr);
    defer freeComponents(gpa, root_components);
    try std.testing.expectEqual(@as(usize, 0), root_components.len);
}

test "Mount rejects unsupported platforms" {
    if (builtin.os.tag != .windows) {
        const F = fs_mod.Fs(fs_mod.ByteNames);
        try std.testing.expectError(
            error.UnsupportedPlatform,
            Mount(F).run(undefined, undefined, undefined, "unused", "unused"),
        );
    } else {
        return error.SkipZigTest;
    }
}

test "callback signatures match the documented ProjFS ABI" {
    const expected_counts = .{
        .StartDirectoryEnumerationCallback = @as(usize, 2),
        .EndDirectoryEnumerationCallback = @as(usize, 2),
        .GetDirectoryEnumerationCallback = @as(usize, 4),
        .GetPlaceholderInfoCallback = @as(usize, 1),
        .GetFileDataCallback = @as(usize, 3),
        .QueryFileNameCallback = @as(usize, 1),
        .NotificationCallback = @as(usize, 5),
        .CancelCommandCallback = @as(usize, 1),
    };

    inline for (@typeInfo(Callbacks).@"struct".fields) |field| {
        const pointer = @typeInfo(field.type).optional.child;
        const function = @typeInfo(pointer).pointer.child;
        const info = @typeInfo(function).@"fn";
        try std.testing.expectEqual(
            @field(expected_counts, field.name),
            info.params.len,
        );
    }
}

test "capture queue deduplicates and keeps the newest revision" {
    const gpa = std.testing.allocator;

    var queue: CaptureQueue = .{};
    defer queue.deinit(gpa);

    try queue.enqueue(gpa, "a.txt");
    try queue.enqueue(gpa, "b.txt");
    const first = queue.items.items[0].revision;
    try queue.enqueue(gpa, "a.txt");

    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
    try std.testing.expect(!queue.contains(first));
    try std.testing.expect(queue.contains(queue.items.items[0].revision));
    try std.testing.expect(queue.items.items[0].revision > first);
}

fn expectQueuePaths(queue: *const CaptureQueue, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, queue.items.items.len);
    for (expected, queue.items.items) |want, entry| {
        try std.testing.expectEqualStrings(want, entry.path);
    }
}

test "capture queue rename rewrites descendant paths and drops removed entries" {
    const gpa = std.testing.allocator;

    var queue: CaptureQueue = .{};
    defer queue.deinit(gpa);

    try queue.enqueue(gpa, "docs\\a.txt");
    try queue.enqueue(gpa, "docs\\sub\\b.txt");
    try queue.enqueue(gpa, "other.txt");
    const untouched = queue.items.items[2].revision;

    try queue.rename(gpa, "docs", "archive");
    try expectQueuePaths(&queue, &.{ "archive\\a.txt", "archive\\sub\\b.txt", "other.txt" });
    try std.testing.expectEqual(untouched, queue.items.items[2].revision);

    try queue.rename(gpa, "archive\\a.txt", "archive\\renamed.txt");
    try expectQueuePaths(&queue, &.{ "archive\\renamed.txt", "archive\\sub\\b.txt", "other.txt" });

    queue.removePrefix(gpa, "archive\\renamed.txt");
    try expectQueuePaths(&queue, &.{ "archive\\sub\\b.txt", "other.txt" });

    queue.removePrefix(gpa, "archive");
    try expectQueuePaths(&queue, &.{"other.txt"});
}

const FakeFs = struct {
    sets: usize = 0,
    removals: usize = 0,
    moves: usize = 0,
    commits: usize = 0,
    fail_commit: bool = false,
    fail_set: bool = false,
    missing: bool = false,
    cleanup_calls: usize = 0,
    gpa: std.mem.Allocator = std.testing.allocator,

    const EmptyChildren = struct {
        fn next(_: *EmptyChildren) ?@import("namespace.zig").Entry {
            return null;
        }
    };

    fn children(self: *FakeFs, _: fs_mod.NodeId) error{}!EmptyChildren {
        self.cleanup_calls += 1;
        return .{};
    }

    fn size(_: *FakeFs, _: fs_mod.NodeId) error{}!u64 {
        unreachable;
    }

    fn readFile(_: *FakeFs, _: fs_mod.NodeId) error{}![]u8 {
        unreachable;
    }

    fn lookup(self: *FakeFs, _: fs_mod.NodeId, _: []const u8) anyerror!fs_mod.NodeId {
        if (self.missing) return error.NotFound;
        return @enumFromInt(1);
    }

    fn resolve(self: *FakeFs, parent: fs_mod.NodeId, _: []const []const u8) anyerror!fs_mod.NodeId {
        return self.lookup(parent, "");
    }

    fn createDirectory(_: *FakeFs, _: fs_mod.NodeId, _: []const u8) error{}!fs_mod.NodeId {
        return @enumFromInt(1);
    }

    fn createFile(self: *FakeFs, parent: fs_mod.NodeId, name: []const u8) error{}!fs_mod.NodeId {
        return self.createDirectory(parent, name);
    }

    fn move(self: *FakeFs, _: fs_mod.NodeId, _: fs_mod.NodeId, _: []const u8) error{}!void {
        self.moves += 1;
    }

    fn remove(self: *FakeFs, _: fs_mod.NodeId) error{}!void {
        self.removals += 1;
    }

    fn setContent(self: *FakeFs, _: fs_mod.NodeId, _: []const u8) error{OutOfMemory}!void {
        if (self.fail_set) return error.OutOfMemory;
        self.sets += 1;
    }

    fn commit(self: *FakeFs) error{OutOfMemory}!void {
        if (self.fail_commit) return error.OutOfMemory;
        self.commits += 1;
    }
};

test "publishCapture rejects stale revisions and drops entries after success" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fs: FakeFs = .{};

    var mount: WindowsMount(FakeFs) = .{
        .gpa = gpa,
        .io = io,
        .fs = &fs,
        .api = undefined,
        .root_wide = undefined,
        .root_utf8 = &.{},
        .exe_path = "",
    };
    defer mount.releaseState();

    try mount.pending.enqueue(gpa, "a.txt");
    const revision = mount.pending.items.items[0].revision;

    try mount.publishCapture("a.txt", revision, "hello");
    try std.testing.expectEqual(@as(usize, 0), mount.pending.items.items.len);
    try std.testing.expect(mount.dirty.load(.acquire));

    try mount.pending.enqueue(gpa, "a.txt");
    try std.testing.expectError(error.StaleCapture, mount.publishCapture("a.txt", revision, "stale"));
    try std.testing.expectEqual(@as(usize, 1), mount.pending.items.items.len);
}

fn testMount(gpa: std.mem.Allocator, io: std.Io, fs: *FakeFs) WindowsMount(FakeFs) {
    return .{
        .gpa = gpa,
        .io = io,
        .fs = fs,
        .api = undefined,
        .root_wide = undefined,
        .root_utf8 = &.{},
        .exe_path = "",
    };
}

test "failed publication retains capture for retry and tracking failure prevents reads" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fs: FakeFs = .{ .fail_set = true };

    var mount = testMount(gpa, io, &fs);
    defer mount.releaseState();

    try mount.pending.enqueue(gpa, "a.txt");
    const revision = mount.pending.items.items[0].revision;
    try std.testing.expectError(error.OutOfMemory, mount.publishCapture("a.txt", revision, "data"));
    try std.testing.expectEqual(@as(usize, 1), mount.pending.items.items.len);

    fs.fail_set = false;
    try mount.publishCapture("a.txt", revision, "data");
    try std.testing.expectEqual(@as(usize, 0), mount.pending.items.items.len);

    mount.tracking_failed = true;
    try mount.pending.enqueue(gpa, "b.txt");
    try std.testing.expectError(error.CaptureTrackingFailed, mount.processPending());
    try std.testing.expectEqual(@as(usize, 1), mount.pending.items.items.len);
}

test "commitPending retries failed commits and clears dirty only on success" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fs: FakeFs = .{ .fail_commit = true };

    var mount = testMount(gpa, io, &fs);
    defer mount.releaseState();

    mount.dirty.store(true, .release);
    try std.testing.expectError(error.OutOfMemory, mount.commitPending(false));
    try std.testing.expect(mount.dirty.load(.acquire));

    fs.fail_commit = false;
    try mount.commitPending(false);
    try std.testing.expectEqual(@as(usize, 1), fs.commits);
    try std.testing.expect(!mount.dirty.load(.acquire));

    try mount.commitPending(false);
    try std.testing.expectEqual(@as(usize, 1), fs.commits);
}

test "processPending survives allocation failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fs: FakeFs = .{};

    var mount = testMount(gpa, io, &fs);
    defer mount.releaseState();

    try mount.pending.enqueue(gpa, "a.txt");
    try mount.pending.enqueue(gpa, "b.txt");

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    const result = processPendingWith(&mount, failing.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expectEqual(@as(usize, 2), mount.pending.items.items.len);
}

fn processPendingWith(mount: *WindowsMount(FakeFs), allocator: std.mem.Allocator) !void {
    const saved = mount.gpa;
    mount.gpa = allocator;
    defer mount.gpa = saved;
    try mount.processPending();
}

fn notificationData(path: [*:0]const u16) CallbackData {
    var data = std.mem.zeroes(CallbackData);
    data.FilePathName = path;
    return data;
}

test "PRE_DELETE does not publish deletion and confirmed delete invalidates capture" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fs: FakeFs = .{};
    var mount = testMount(std.testing.allocator, std.testing.io, &fs);
    defer mount.releaseState();
    const data = notificationData(std.unicode.utf8ToUtf16LeStringLiteral("a.txt"));
    try mount.pending.enqueue(mount.gpa, "a.txt");
    const revision = mount.pending.items.items[0].revision;

    _ = try mount.notify(&data, false, NOTIFICATION_PRE_DELETE, null);
    try std.testing.expectEqual(@as(usize, 0), fs.removals);
    try std.testing.expect(mount.pending.contains(revision));
    try std.testing.expect(!mount.dirty.load(.acquire));

    _ = try mount.notify(&data, false, NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED, null);
    try std.testing.expectEqual(@as(usize, 1), fs.removals);
    try std.testing.expectError(error.StaleCapture, mount.publishCapture("a.txt", revision, "old"));
    try std.testing.expectEqual(@as(usize, 0), fs.sets);

    // Recreating the same name must not make the deleted request valid again.
    try mount.pending.enqueue(mount.gpa, "a.txt");
    try std.testing.expectError(error.StaleCapture, mount.publishCapture("a.txt", revision, "old"));
}

test "directory rename invalidates in-flight capture and rewrites queued descendants" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fs: FakeFs = .{};
    var mount = testMount(std.testing.allocator, std.testing.io, &fs);
    defer mount.releaseState();
    const data = notificationData(std.unicode.utf8ToUtf16LeStringLiteral("docs"));
    try mount.pending.enqueue(mount.gpa, "docs\\a.txt");
    const revision = mount.pending.items.items[0].revision;
    try mount.pending.enqueue(mount.gpa, "docs-other\\b.txt");

    _ = try mount.notify(&data, true, NOTIFICATION_FILE_RENAMED, std.unicode.utf8ToUtf16LeStringLiteral("archive"));
    try expectQueuePaths(&mount.pending, &.{ "archive\\a.txt", "docs-other\\b.txt" });
    try std.testing.expectEqual(@as(usize, 1), fs.moves);
    try std.testing.expectError(error.StaleCapture, mount.publishCapture("docs\\a.txt", revision, "old"));
    try mount.publishCapture("archive\\a.txt", mount.pending.items.items[0].revision, "new");
    try std.testing.expectEqual(@as(usize, 1), fs.sets);
}

test "rename of uncaptured local file queues destination and move out cancels it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fs: FakeFs = .{ .missing = true };
    var mount = testMount(std.testing.allocator, std.testing.io, &fs);
    defer mount.releaseState();
    var data = notificationData(std.unicode.utf8ToUtf16LeStringLiteral("new.txt"));
    _ = try mount.notify(&data, false, NOTIFICATION_FILE_RENAMED, std.unicode.utf8ToUtf16LeStringLiteral("renamed.txt"));
    try expectQueuePaths(&mount.pending, &.{"renamed.txt"});
    data.FilePathName = std.unicode.utf8ToUtf16LeStringLiteral("renamed.txt");
    _ = try mount.notify(&data, false, NOTIFICATION_FILE_RENAMED, std.unicode.utf8ToUtf16LeStringLiteral(""));
    try expectQueuePaths(&mount.pending, &.{});
}

test "queue matches Windows case aliases and does not match partial components" {
    var queue: CaptureQueue = .{};
    const gpa = std.testing.allocator;
    defer queue.deinit(gpa);
    try queue.enqueue(gpa, "docs\\a");
    const old = queue.items.items[0].revision;
    try queue.enqueue(gpa, "DOCS\\A");
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expect(!queue.contains(old));
    try queue.enqueue(gpa, "docs-other\\a");
    try queue.enqueue(gpa, "target\\a");
    const replaced = queue.items.items[2].revision;
    try queue.rename(gpa, "DOCS", "target");
    try expectQueuePaths(&queue, &.{ "target\\a", "docs-other\\a" });
    try std.testing.expect(!queue.contains(replaced));
    queue.removePrefix(gpa, "TARGET");
    try expectQueuePaths(&queue, &.{"docs-other\\a"});
}

fn queueAllocationFailures(gpa: std.mem.Allocator) !void {
    var queue: CaptureQueue = .{};
    defer queue.deinit(gpa);
    try queue.enqueue(gpa, "docs\\a");
    try queue.enqueue(gpa, "docs\\b");
    const revision = queue.items.items[0].revision;
    queue.rename(gpa, "docs", "new") catch |err| {
        try expectQueuePaths(&queue, &.{ "docs\\a", "docs\\b" });
        try std.testing.expect(queue.contains(revision));
        return err;
    };
    try expectQueuePaths(&queue, &.{ "new\\a", "new\\b" });
}

fn sessionAllocationFailures(gpa: std.mem.Allocator) !void {
    var fs: FakeFs = .{};
    var mount = testMount(gpa, std.testing.io, &fs);
    defer mount.releaseState();
    const items = blk: {
        const items = try gpa.alloc(WindowsMount(FakeFs).DirItem, 1);
        errdefer gpa.free(items);
        items[0] = .{ .name = try utf8Path(gpa, "a"), .is_directory = false, .size = 0 };
        break :blk items;
    };
    try mount.addSession(std.mem.zeroes(GUID), items);
}

fn splitAllocationFailures(gpa: std.mem.Allocator) !void {
    const components = try splitRelative(gpa, std.unicode.utf8ToUtf16LeStringLiteral("a\\b\\c"));
    defer freeComponents(gpa, components);
}

test "queue rename and enumeration ownership survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, queueAllocationFailures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sessionAllocationFailures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, splitAllocationFailures, .{});
}

test "failed notification tracking prevents in-flight publication" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fs: FakeFs = .{};
    const gpa = std.testing.allocator;
    var mount = testMount(gpa, std.testing.io, &fs);
    defer mount.releaseState();
    try mount.pending.enqueue(gpa, "a.txt");
    const revision = mount.pending.items.items[0].revision;
    const data = notificationData(std.unicode.utf8ToUtf16LeStringLiteral("a.txt"));
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    {
        mount.gpa = failing.allocator();
        defer mount.gpa = gpa;
        try std.testing.expectError(error.OutOfMemory, mount.notify(&data, false, NOTIFICATION_FILE_HANDLE_CLOSED_FILE_DELETED, null));
    }
    try std.testing.expect(mount.tracking_failed);
    try std.testing.expectError(error.CaptureTrackingFailed, mount.publishCapture("a.txt", revision, "old"));
    try std.testing.expectEqual(@as(usize, 0), fs.sets);
}

fn fakeStop(handle: Handle) callconv(.winapi) void {
    const stopped: *bool = @ptrCast(@alignCast(handle.?));
    stopped.* = true;
}

test "shutdown stops callbacks and reports capture and commit failures without cleanup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fs: FakeFs = .{};
    var mount = testMount(std.testing.allocator, std.testing.io, &fs);
    defer mount.releaseState();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", mount.gpa);
    defer mount.gpa.free(root);
    const wide = try utf8Path(mount.gpa, root);
    defer mount.gpa.free(wide);
    mount.root_utf8 = root;
    mount.root_wide = wide;
    var stopped = false;
    mount.api.PrjStopVirtualizing = fakeStop;
    mount.handle = &stopped;
    try mount.finish();
    try std.testing.expectEqual(@as(usize, 1), fs.cleanup_calls);
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 1), fs.commits);

    stopped = false;
    mount.handle = &stopped;
    mount.tracking_failed = true;
    try mount.pending.enqueue(mount.gpa, "retained.txt");
    try std.testing.expectError(error.CaptureTrackingFailed, mount.finish());
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 2), fs.commits);
    try expectQueuePaths(&mount.pending, &.{"retained.txt"});

    mount.handle = &stopped;
    fs.fail_commit = true;
    try std.testing.expectError(error.OutOfMemory, mount.finish());
    try std.testing.expect(mount.dirty.load(.acquire));
    try expectQueuePaths(&mount.pending, &.{"retained.txt"});
    // A commit failure independently gates cleanup, even with a successful drain.
    mount.tracking_failed = false;
    mount.pending.removePrefix(mount.gpa, "retained.txt");
    mount.handle = &stopped;
    try std.testing.expectError(error.OutOfMemory, mount.finish());
    try std.testing.expectEqual(@as(usize, 1), fs.cleanup_calls);
}

fn stubDiskState(_: [*:0]const u16, state: *u32) callconv(.winapi) HRESULT {
    state.* = FILE_STATE_FULL;
    return 0;
}

const CleanupTest = struct {
    const Fs = fs_mod.Fs(fs_mod.ByteNames);
    tmp: std.testing.TmpDir,
    fs: Fs,
    root: [:0]u8,
    wide: [:0]u16,

    fn init() !CleanupTest {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "store.data", .data = "" });
        const data = try tmp.dir.realPathFileAlloc(io, "store.data", gpa);
        defer gpa.free(data);
        var fs = try Fs.init(gpa, io, data);
        errdefer fs.deinit();
        try tmp.dir.createDirPath(io, "mount");
        const root = try tmp.dir.realPathFileAlloc(io, "mount", gpa);
        errdefer gpa.free(root);
        return .{ .tmp = tmp, .fs = fs, .root = root, .wide = try utf8Path(gpa, root) };
    }

    fn deinit(self: *CleanupTest) void {
        self.fs.deinit();
        std.testing.allocator.free(self.root);
        std.testing.allocator.free(self.wide);
        self.tmp.cleanup();
    }

    fn mount(self: *CleanupTest) WindowsMount(Fs) {
        var result: WindowsMount(Fs) = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .fs = &self.fs,
            .api = undefined,
            .root_utf8 = self.root,
            .root_wide = self.wide,
            .exe_path = "",
        };
        result.api.PrjGetOnDiskFileState = stubDiskState;
        result.api.PrjStopVirtualizing = fakeStop;
        return result;
    }

    fn write(self: *CleanupTest, path: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    }

    fn expectBytes(self: *CleanupTest, path: []const u8, bytes: []const u8) !void {
        const actual = try self.tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(bytes, actual);
    }

    fn expectMissing(self: *CleanupTest, path: []const u8) !void {
        try std.testing.expectError(error.FileNotFound, self.tmp.dir.access(std.testing.io, path, .{}));
    }
};

test "cleanup clean placeholder decision excludes dirty full tombstone and unknown bits" {
    for ([_]u32{ 1, 2, 3 }) |state| try std.testing.expect(cleanPlaceholderState(state));
    for ([_]u32{ 0, 4, 5, 6, 7, 8, 9, 16, 17, 32, 33, 0xffffffff }) |state|
        try std.testing.expect(!cleanPlaceholderState(state));
    for ([_][]const u8{ "", ".", "..", "..\\outside", "x:y", "a/b", "NUL.txt", "COM1", "LPT¹", "a.", "a ", "a?", "SHORT~1", "a\x00b" }) |name|
        try std.testing.expect(!cleanupComponentValid(name));
    try std.testing.expect(cleanupComponentValid("ordinary.txt"));
}

test "cleanup deletes equal files and empty namespace directories but preserves mismatches and unknown paths" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try CleanupTest.init();
    defer fixture.deinit();
    const nested = try fixture.fs.createDirectory(.root, "nested");
    const deep = try fixture.fs.createDirectory(nested, "deep");
    _ = try fixture.fs.createFileWith(deep, "equal", "archived");
    _ = try fixture.fs.createFileWith(.root, "different", "archived");
    _ = try fixture.fs.createFileWith(.root, "longer", "archived");
    _ = try fixture.fs.createFileWith(.root, "missing", "archived");
    const occupied = try fixture.fs.createDirectory(.root, "occupied");
    _ = try fixture.fs.createFileWith(occupied, "equal", "archived");
    try fixture.tmp.dir.createDirPath(std.testing.io, "mount/nested/deep");
    try fixture.tmp.dir.createDirPath(std.testing.io, "mount/occupied");
    try fixture.write("mount/nested/deep/equal", "archived");
    try fixture.write("mount/different", "modified");
    try fixture.write("mount/longer", "archived plus");
    try fixture.write("mount/unknown", "untracked");
    try fixture.write("mount/occupied/equal", "archived");
    try fixture.write("mount/occupied/unknown", "untracked");
    var mount = fixture.mount();
    defer mount.releaseState();
    var stopped = false;
    mount.handle = &stopped;
    try std.testing.expectError(error.CleanupIncomplete, mount.finish());
    try std.testing.expect(stopped);
    try fixture.expectMissing("mount/nested");
    try fixture.expectMissing("mount/occupied/equal");
    try fixture.expectBytes("mount/different", "modified");
    try fixture.expectBytes("mount/longer", "archived plus");
    try fixture.expectBytes("mount/unknown", "untracked");
    try fixture.expectBytes("mount/occupied/unknown", "untracked");
}

test "cleanup preserves busy writers invalid components alternate streams and readonly files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try CleanupTest.init();
    defer fixture.deinit();
    for ([_][]const u8{ "busy", "streams", "readonly", "..\\outside", "streams:secret" }) |name|
        _ = try fixture.fs.createFileWith(.root, name, "archived");
    try fixture.write("mount/busy", "archived");
    try fixture.write("mount/streams", "archived");
    try fixture.write("mount/streams:secret", "unarchived stream");
    try fixture.write("mount/readonly", "archived");
    try fixture.write("outside", "archived");
    const busy_path = try std.mem.concat(std.testing.allocator, u8, &.{ fixture.root, "\\busy" });
    defer std.testing.allocator.free(busy_path);
    const busy_wide = try utf8Path(std.testing.allocator, busy_path);
    defer std.testing.allocator.free(busy_wide);
    const writer = CreateFileW(busy_wide.ptr, 0x40000000, 7, null, 3, 0, null);
    try std.testing.expect(writer != INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(writer);
    const readonly_path = try std.mem.concat(std.testing.allocator, u8, &.{ fixture.root, "\\readonly" });
    defer std.testing.allocator.free(readonly_path);
    const readonly_wide = try utf8Path(std.testing.allocator, readonly_path);
    defer std.testing.allocator.free(readonly_wide);
    try std.testing.expect(SetFileAttributesW(readonly_wide.ptr, FILE_ATTRIBUTE_READONLY) != 0);
    defer _ = SetFileAttributesW(readonly_wide.ptr, FILE_ATTRIBUTE_NORMAL);
    try fixture.fs.commit();
    var mount = fixture.mount();
    defer mount.releaseState();
    var stats: @TypeOf(mount).CleanupStats = .{};
    try mount.cleanup(&stats);
    try std.testing.expectEqual(@as(usize, 5), stats.retained);
    try std.testing.expectEqual(@as(usize, 0), stats.removed);
    try fixture.expectBytes("mount/busy", "archived");
    try fixture.expectBytes("mount/streams", "archived");
    try fixture.expectBytes("mount/streams:secret", "unarchived stream");
    try fixture.expectBytes("mount/readonly", "archived");
    try fixture.expectBytes("outside", "archived");
}

test "shutdown on real files gates cleanup on drain and commit success" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try CleanupTest.init();
    defer fixture.deinit();
    _ = try fixture.fs.createFileWith(.root, "equal", "archived");
    try fixture.write("mount/equal", "archived");
    var mount = fixture.mount();
    defer mount.releaseState();
    var stopped = false;
    mount.handle = &stopped;
    mount.tracking_failed = true;
    try std.testing.expectError(error.CaptureTrackingFailed, mount.finish());
    try std.testing.expect(stopped);
    try fixture.expectBytes("mount/equal", "archived");

    stopped = false;
    mount.handle = &stopped;
    mount.tracking_failed = false;
    fixture.fs.writer.poisoned = true;
    try std.testing.expectError(error.WriterPoisoned, mount.finish());
    try std.testing.expect(stopped);
    try fixture.expectBytes("mount/equal", "archived");

    stopped = false;
    mount.handle = &stopped;
    fixture.fs.writer.poisoned = false;
    try mount.finish();
    try std.testing.expect(stopped);
    try fixture.expectMissing("mount/equal");
}

test "cleanup retains a file whose archive content cannot be read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var fixture = try CleanupTest.init();
    defer fixture.deinit();
    const id = try fixture.fs.createFileWith(.root, "unreadable", "archived");
    try fixture.write("mount/unreadable", "archived");
    try fixture.fs.ns.setContent(id, .fromIndex(999999));
    var mount = fixture.mount();
    defer mount.releaseState();
    var stats: @TypeOf(mount).CleanupStats = .{};
    try mount.cleanup(&stats);
    try std.testing.expectEqual(@as(usize, 1), stats.retained);
    try std.testing.expectEqual(@as(usize, 0), stats.removed);
    try fixture.expectBytes("mount/unreadable", "archived");
}

test "cleanup never follows a namespace directory junction or a junction root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fixture = try CleanupTest.init();
    defer fixture.deinit();
    const directory = try fixture.fs.createDirectory(.root, "junction");
    _ = try fixture.fs.createFileWith(directory, "equal", "archived");
    _ = try fixture.fs.createFileWith(.root, "equal", "archived");
    try fixture.tmp.dir.createDirPath(io, "outside");
    try fixture.write("outside/equal", "archived");
    const target = try fixture.tmp.dir.realPathFileAlloc(io, "outside", gpa);
    defer gpa.free(target);
    const junction = try std.mem.concat(gpa, u8, &.{ fixture.root, "\\junction" });
    defer gpa.free(junction);
    const junction_wide = try utf8Path(gpa, junction);
    defer gpa.free(junction_wide);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "cmd.exe", "/c", "mklink", "/J", junction, target } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    defer _ = RemoveDirectoryW(junction_wide.ptr);
    var mount = fixture.mount();
    defer mount.releaseState();
    var stats: @TypeOf(mount).CleanupStats = .{};
    try mount.cleanup(&stats);
    try std.testing.expectEqual(@as(usize, 1), stats.retained);
    try std.testing.expectEqual(@as(usize, 0), stats.removed);
    try fixture.expectBytes("outside/equal", "archived");
    // The same guard applies to the mount root, before touching any children.
    mount.root_wide = junction_wide;
    mount.root_utf8 = junction;
    try std.testing.expectError(error.UnsafeReparsePoint, mount.cleanup(&stats));
    try fixture.expectBytes("outside/equal", "archived");
}
