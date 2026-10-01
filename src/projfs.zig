const std = @import("std");
const builtin = @import("builtin");

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_FILENOTFOUND: HRESULT = -2147024894;
pub const E_INSUFFICIENT_BUFFER: HRESULT = -2147024774;
pub const E_ALREADY_EXISTS: HRESULT = -2147024713;

pub const PRJ_NOTIFY_FILE_OPENED: u32 = 0x00000002;
pub const PRJ_NOTIFY_NEW_FILE_CREATED: u32 = 0x00000004;
pub const PRJ_NOTIFY_FILE_OVERWRITTEN: u32 = 0x00000008;
pub const PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_MODIFIED: u32 = 0x00000400;
pub const PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_DELETED: u32 = 0x00000800;

pub const EntryInfo = struct {
    root: u32,
    size: u64,
};

pub const DirEntryInfo = struct {
    path: []const u8,
    size: u64,
};

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const PRJ_CALLBACK_DATA = extern struct {
    Size: u32,
    Flags: u32,
    NamespaceVirtualizationContext: ?*anyopaque,
    CommandId: i32,
    FileId: GUID,
    DataStreamId: GUID,
    FilePathName: ?[*:0]const u16,
    VersionInfo: ?*anyopaque,
    TriggeringProcessId: u32,
    TriggeringProcessImageFileName: ?[*:0]const u16,
    InstanceContext: ?*anyopaque,
};

const PRJ_NOTIFICATION_PARAMETERS = extern struct {
    PostCreate: extern struct {
        NotificationMask: u32,
    },
    FileRenamed: extern struct {
        NotificationMask: u32,
    },
    FileDeletedOnHandleClose: extern struct {
        IsDirectory: u8,
    },
};

const PRJ_FILE_BASIC_INFO = extern struct {
    IsDirectory: u8,
    _pad1: [7]u8 = @splat(0),
    FileSize: i64,
    CreationTime: i64 = 0,
    LastAccessTime: i64 = 0,
    LastWriteTime: i64 = 0,
    ChangeTime: i64 = 0,
    FileAttributes: u32,
    _pad2: [4]u8 = @splat(0),
};

const PRJ_PLACEHOLDER_INFO = extern struct {
    FileBasicInfo: PRJ_FILE_BASIC_INFO,
    EaBufferSize: u32 = 0,
    OffsetToFirstEa: u32 = 0,
    SecurityBufferSize: u32 = 0,
    OffsetToSecurityDescriptor: u32 = 0,
    StreamsInfoBufferSize: u32 = 0,
    OffsetToFirstStreamInfo: u32 = 0,
    ProviderID: [128]u8 = @splat(0),
    ContentID: [128]u8 = @splat(0),
    VariableData: [1]u8 = @splat(0),
};

const PRJ_NOTIFICATION_MAPPING = extern struct {
    NotificationBitMask: u32,
    NotificationRoot: [*:0]const u16,
};

const PRJ_START_VIRTUALIZING_OPTIONS = extern struct {
    Flags: u32 = 0,
    PoolThreadCount: u32 = 0,
    ConcurrentThreadCount: u32 = 0,
    NotificationMappings: ?[*]const PRJ_NOTIFICATION_MAPPING = null,
    NotificationMappingsCount: u32 = 0,
};

const PRJ_CALLBACKS = extern struct {
    StartDirectoryEnumerationCallback: *const fn (*const PRJ_CALLBACK_DATA, *const GUID) callconv(.winapi) HRESULT,
    EndDirectoryEnumerationCallback: *const fn (*const PRJ_CALLBACK_DATA, *const GUID) callconv(.winapi) HRESULT,
    GetDirectoryEnumerationCallback: *const fn (*const PRJ_CALLBACK_DATA, *const GUID, ?[*:0]const u16, ?*anyopaque) callconv(.winapi) HRESULT,
    GetPlaceholderInfoCallback: *const fn (*const PRJ_CALLBACK_DATA) callconv(.winapi) HRESULT,
    GetFileDataCallback: *const fn (*const PRJ_CALLBACK_DATA, u64, u32) callconv(.winapi) HRESULT,
    QueryFileNameCallback: ?*anyopaque = null,
    NotificationCallback: ?*const fn (*const PRJ_CALLBACK_DATA, u8, u32, ?[*:0]const u16, *PRJ_NOTIFICATION_PARAMETERS) callconv(.winapi) HRESULT = null,
    CancelCommandCallback: ?*anyopaque = null,
};

const PrjApi = struct {
    StartVirtualizing: *const fn ([*:0]const u16, *const PRJ_CALLBACKS, ?*const anyopaque, ?*const PRJ_START_VIRTUALIZING_OPTIONS, *?*anyopaque) callconv(.winapi) HRESULT,
    StopVirtualizing: *const fn (?*anyopaque) callconv(.winapi) void,
    MarkDirectoryAsPlaceholder: *const fn ([*:0]const u16, ?[*:0]const u16, ?*const anyopaque, *const GUID) callconv(.winapi) HRESULT,
    FillDirEntryBuffer: *const fn ([*:0]const u16, *const PRJ_FILE_BASIC_INFO, ?*anyopaque) callconv(.winapi) HRESULT,
    WriteFileData: *const fn (?*anyopaque, *const GUID, *const anyopaque, u64, u32) callconv(.winapi) HRESULT,
    WritePlaceholderInfo: *const fn (?*anyopaque, [*:0]const u16, *const PRJ_PLACEHOLDER_INFO, u32) callconv(.winapi) HRESULT,
    FileNameMatch: *const fn ([*:0]const u16, [*:0]const u16) callconv(.winapi) bool,
    FileNameCompare: *const fn ([*:0]const u16, [*:0]const u16) callconv(.winapi) i32,

    fn load() !PrjApi {
        const h = LoadLibraryA("ProjectedFSLib.dll") orelse return error.ProjFsUnavailable;
        const Cast = struct {
            inline fn proc(comptime T: type, handle: *anyopaque, name: [*:0]const u8) !T {
                const ptr = GetProcAddress(handle, name) orelse return error.SymbolMissing;
                return @ptrCast(@alignCast(ptr));
            }
        };

        return .{
            .StartVirtualizing = try Cast.proc(@TypeOf(@as(PrjApi, undefined).StartVirtualizing), h, "PrjStartVirtualizing"),
            .StopVirtualizing = try Cast.proc(@TypeOf(@as(PrjApi, undefined).StopVirtualizing), h, "PrjStopVirtualizing"),
            .MarkDirectoryAsPlaceholder = try Cast.proc(@TypeOf(@as(PrjApi, undefined).MarkDirectoryAsPlaceholder), h, "PrjMarkDirectoryAsPlaceholder"),
            .FillDirEntryBuffer = try Cast.proc(@TypeOf(@as(PrjApi, undefined).FillDirEntryBuffer), h, "PrjFillDirEntryBuffer"),
            .WriteFileData = try Cast.proc(@TypeOf(@as(PrjApi, undefined).WriteFileData), h, "PrjWriteFileData"),
            .WritePlaceholderInfo = try Cast.proc(@TypeOf(@as(PrjApi, undefined).WritePlaceholderInfo), h, "PrjWritePlaceholderInfo"),
            .FileNameMatch = try Cast.proc(@TypeOf(@as(PrjApi, undefined).FileNameMatch), h, "PrjFileNameMatch"),
            .FileNameCompare = try Cast.proc(@TypeOf(@as(PrjApi, undefined).FileNameCompare), h, "PrjFileNameCompare"),
        };
    }
};

extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn CreateEventA(?*anyopaque, i32, i32, ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(?*anyopaque, u32) callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCtrlHandler(?*const fn (u32) callconv(.winapi) i32, i32) callconv(.winapi) i32;
extern "kernel32" fn AcquireSRWLockExclusive(*anyopaque) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*anyopaque) callconv(.winapi) void;

const DirItem = struct {
    name_w: [260:0]u16,
    is_dir: bool,
    size: u64,
};

const Session = struct {
    id: GUID,
    items: []DirItem,
    cursor: usize,
};

pub const MountCallbacks = struct {
    find_fn: *const fn (*anyopaque, []const u8) ?EntryInfo,
    read_fn: *const fn (*const anyopaque, u32, u64, []u8) usize,
    entries_fn: *const fn (*const anyopaque, usize) ?DirEntryInfo,
    on_file_write_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
    on_file_delete_fn: *const fn (*anyopaque, []const u8) anyerror!void,
};

const MountState = struct {
    archive: *anyopaque,
    allocator: std.mem.Allocator,
    mount_dir: []const u8,
    callbacks: MountCallbacks,
    sessions: [16]?Session = [_]?Session{null} ** 16,
    lock: ?*anyopaque = null,
};

var state: MountState = undefined;
var prj: PrjApi = undefined;
var shutdown_event: ?*anyopaque = null;

fn toUtf8(out: []u8, src: ?[*:0]const u16) []const u8 {
    const s = src orelse return "";
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    const n = std.unicode.utf16LeToUtf8(out, s[0..len]) catch 0;
    for (out[0..n]) |*b| if (b.* == '\\') {
        b.* = '/';
    };
    return out[0..n];
}

fn isDir(dir: []const u8) bool {
    if (dir.len == 0) return true;
    var idx: usize = 0;
    while (state.callbacks.entries_fn(state.archive, idx)) |e| : (idx += 1) {
        if (e.path.len > dir.len and std.mem.startsWith(u8, e.path, dir) and e.path[dir.len] == '/') return true;
    }
    return false;
}

fn readRangeWalk(buffer: anytype, id: u32, skip: *u64, dest: []u8, written: *usize) void {
    if (written.* >= dest.len) return;
    if ((id & 0x8000_0000) != 0) {
        const pair = buffer.readPair(id);
        readRangeWalk(buffer, pair[0], skip, dest, written);
        readRangeWalk(buffer, pair[1], skip, dest, written);
    } else {
        const slice = buffer.readBytes(id);
        if (skip.* >= slice.len) {
            skip.* -= slice.len;
            return;
        }
        const chunk = slice[skip.*..];
        skip.* = 0;
        const n = @min(dest.len - written.*, chunk.len);
        @memcpy(dest[written.*..][0..n], chunk[0..n]);
        written.* += n;
    }
}

fn onStartDir(data: *const PRJ_CALLBACK_DATA, id: *const GUID) callconv(.winapi) HRESULT {
    AcquireSRWLockExclusive(@ptrCast(&state.lock));
    defer ReleaseSRWLockExclusive(@ptrCast(&state.lock));

    var path_buf: [512]u8 = undefined;
    const dir = toUtf8(&path_buf, data.FilePathName);

    var list: std.ArrayListUnmanaged(DirItem) = .empty;
    defer list.deinit(state.allocator);

    var idx: usize = 0;
    while (state.callbacks.entries_fn(state.archive, idx)) |e| : (idx += 1) {
        const rel = if (dir.len == 0) e.path else if (std.mem.startsWith(u8, e.path, dir) and e.path.len > dir.len and e.path[dir.len] == '/') e.path[dir.len + 1 ..] else continue;
        const slash = std.mem.indexOfScalar(u8, rel, '/');
        const name = if (slash) |s| rel[0..s] else rel;
        const item_is_dir = (slash != null);

        var exists = false;
        for (list.items) |it| {
            var buf: [260]u8 = undefined;
            const existing_name = toUtf8(&buf, &it.name_w);
            if (std.mem.eql(u8, existing_name, name)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;

        var it = DirItem{ .name_w = undefined, .is_dir = item_is_dir, .size = if (item_is_dir) 0 else e.size };
        const u16_len = std.unicode.utf8ToUtf16Le(&it.name_w, name) catch continue;
        it.name_w[u16_len] = 0;
        list.append(state.allocator, it) catch return E_INSUFFICIENT_BUFFER;
    }

    const Sorter = struct {
        fn cmp(_: void, a: DirItem, b: DirItem) bool {
            return prj.FileNameCompare(&a.name_w, &b.name_w) < 0;
        }
    };
    std.mem.sort(DirItem, list.items, {}, Sorter.cmp);

    for (&state.sessions) |*slot| {
        if (slot.* == null) {
            slot.* = .{
                .id = id.*,
                .items = list.toOwnedSlice(state.allocator) catch return E_INSUFFICIENT_BUFFER,
                .cursor = 0,
            };
            return S_OK;
        }
    }
    return E_INSUFFICIENT_BUFFER;
}

fn onEndDir(_: *const PRJ_CALLBACK_DATA, id: *const GUID) callconv(.winapi) HRESULT {
    AcquireSRWLockExclusive(@ptrCast(&state.lock));
    defer ReleaseSRWLockExclusive(@ptrCast(&state.lock));

    for (&state.sessions) |*slot| {
        if (slot.*) |s| {
            if (std.mem.eql(u8, std.mem.asBytes(&s.id), std.mem.asBytes(id))) {
                state.allocator.free(s.items);
                slot.* = null;
                return S_OK;
            }
        }
    }
    return S_OK;
}

fn onGetDir(data: *const PRJ_CALLBACK_DATA, id: *const GUID, search: ?[*:0]const u16, buf: ?*anyopaque) callconv(.winapi) HRESULT {
    AcquireSRWLockExclusive(@ptrCast(&state.lock));
    defer ReleaseSRWLockExclusive(@ptrCast(&state.lock));

    var s_ptr: ?*Session = null;
    for (&state.sessions) |*slot| {
        if (slot.*) |*s| {
            if (std.mem.eql(u8, std.mem.asBytes(&s.id), std.mem.asBytes(id))) {
                s_ptr = s;
                break;
            }
        }
    }
    const session = s_ptr orelse return E_FILENOTFOUND;
    if ((data.Flags & 1) != 0) session.cursor = 0;

    var pattern_buf: [260:0]u16 = undefined;
    const pattern: [*:0]const u16 = if (search) |p| p else blk: {
        pattern_buf[0] = '*';
        pattern_buf[1] = 0;
        break :blk &pattern_buf;
    };

    while (session.cursor < session.items.len) : (session.cursor += 1) {
        const it = &session.items[session.cursor];
        if (!prj.FileNameMatch(&it.name_w, pattern)) continue;

        const info = PRJ_FILE_BASIC_INFO{
            .IsDirectory = if (it.is_dir) 1 else 0,
            .FileSize = if (it.is_dir) 0 else @intCast(it.size),
            .FileAttributes = if (it.is_dir) 0x10 else 0x80,
        };
        if (prj.FillDirEntryBuffer(&it.name_w, &info, buf) == E_INSUFFICIENT_BUFFER) return S_OK;
    }
    return S_OK;
}

fn onGetPlaceholder(data: *const PRJ_CALLBACK_DATA) callconv(.winapi) HRESULT {
    var path_buf: [512]u8 = undefined;
    const path = toUtf8(&path_buf, data.FilePathName);

    var info = std.mem.zeroes(PRJ_PLACEHOLDER_INFO);
    if (state.callbacks.find_fn(state.archive, path)) |entry| {
        info.FileBasicInfo.IsDirectory = 0;
        info.FileBasicInfo.FileSize = @intCast(entry.size);
        info.FileBasicInfo.FileAttributes = 0x80;
    } else if (isDir(path)) {
        info.FileBasicInfo.IsDirectory = 1;
        info.FileBasicInfo.FileAttributes = 0x10;
    } else return E_FILENOTFOUND;

    return prj.WritePlaceholderInfo(data.NamespaceVirtualizationContext, data.FilePathName.?, &info, @sizeOf(PRJ_PLACEHOLDER_INFO));
}

fn onGetFileData(data: *const PRJ_CALLBACK_DATA, offset: u64, len: u32) callconv(.winapi) HRESULT {
    var path_buf: [512]u8 = undefined;
    const path = toUtf8(&path_buf, data.FilePathName);

    const entry = state.callbacks.find_fn(state.archive, path) orelse return E_FILENOTFOUND;
    const buf = state.allocator.alloc(u8, len) catch return E_INSUFFICIENT_BUFFER;
    defer state.allocator.free(buf);

    const n = state.callbacks.read_fn(state.archive, entry.root, offset, buf);
    return prj.WriteFileData(data.NamespaceVirtualizationContext, &data.DataStreamId, buf.ptr, offset, @intCast(n));
}

fn onNotification(
    data: *const PRJ_CALLBACK_DATA,
    _: u8,
    notification: u32,
    _: ?[*:0]const u16,
    _: *PRJ_NOTIFICATION_PARAMETERS,
) callconv(.winapi) HRESULT {
    var path_buf: [512]u8 = undefined;
    const rel_path = toUtf8(&path_buf, data.FilePathName);
    if (rel_path.len == 0) return S_OK;

    if ((notification & PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_MODIFIED) != 0) {
        var full_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ state.mount_dir, rel_path }) catch return S_OK;
        state.callbacks.on_file_write_fn(state.archive, rel_path, full_path) catch {};
    } else if ((notification & PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_DELETED) != 0) {
        AcquireSRWLockExclusive(@ptrCast(&state.lock));
        defer ReleaseSRWLockExclusive(@ptrCast(&state.lock));
        state.callbacks.on_file_delete_fn(state.archive, rel_path) catch {};
    }
    return S_OK;
}

fn ctrlHandler(_: u32) callconv(.winapi) i32 {
    if (shutdown_event) |e| _ = SetEvent(e);
    return 1;
}

pub fn mount(
    allocator: std.mem.Allocator,
    archive: anytype,
    root_path: []const u8,
    on_write: anytype,
    on_delete: anytype,
) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    prj = try PrjApi.load();

    const ArchiveType = @TypeOf(archive.*);
    const WriteFn = *const fn (*ArchiveType, []const u8, []const u8) anyerror!void;
    const DeleteFn = *const fn (*ArchiveType, []const u8) anyerror!void;

    const Helper = struct {
        var write_ctx: WriteFn = undefined;
        var delete_ctx: DeleteFn = undefined;

        fn find(ctx: *anyopaque, path: []const u8) ?EntryInfo {
            const a: *ArchiveType = @ptrCast(@alignCast(ctx));
            const e = a.find(path) orelse return null;
            return .{ .root = e.root, .size = e.size };
        }
        fn read(ctx: *const anyopaque, root: u32, offset: u64, dest: []u8) usize {
            const a: *const ArchiveType = @ptrCast(@alignCast(ctx));
            var skip = offset;
            var written: usize = 0;
            readRangeWalk(&a.buffer, root, &skip, dest, &written);
            return written;
        }
        fn entryAt(ctx: *const anyopaque, idx: usize) ?DirEntryInfo {
            const a: *const ArchiveType = @ptrCast(@alignCast(ctx));
            if (idx >= a.entries.items.len) return null;
            const e = a.entries.items[idx];
            return .{ .path = e.path, .size = e.size };
        }
        fn onWrite(ctx: *anyopaque, rel_path: []const u8, full_path: []const u8) anyerror!void {
            const a: *ArchiveType = @ptrCast(@alignCast(ctx));
            try write_ctx(a, rel_path, full_path);
        }
        fn onDelete(ctx: *anyopaque, rel_path: []const u8) anyerror!void {
            const a: *ArchiveType = @ptrCast(@alignCast(ctx));
            try delete_ctx(a, rel_path);
        }
    };
    Helper.write_ctx = on_write;
    Helper.delete_ctx = on_delete;

    state = .{
        .archive = archive,
        .allocator = allocator,
        .mount_dir = root_path,
        .callbacks = .{
            .find_fn = Helper.find,
            .read_fn = Helper.read,
            .entries_fn = Helper.entryAt,
            .on_file_write_fn = Helper.onWrite,
            .on_file_delete_fn = Helper.onDelete,
        },
    };

    const rel_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, root_path);
    defer allocator.free(rel_w);

    var abs_w: [std.fs.max_path_bytes:0]u16 = undefined;
    const full_len = GetFullPathNameW(rel_w.ptr, abs_w.len, &abs_w, null);
    if (full_len == 0 or full_len >= abs_w.len) return error.PathResolutionFailed;
    abs_w[full_len] = 0;

    var guid = GUID{
        .Data1 = 0x74667331,
        .Data2 = 0xABCD,
        .Data3 = 0x4EF0,
        .Data4 = .{ 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67 },
    };

    const mark_hr = prj.MarkDirectoryAsPlaceholder(&abs_w, null, null, &guid);
    if (mark_hr != S_OK and mark_hr != E_ALREADY_EXISTS) {
        std.debug.print("PrjMarkDirectoryAsPlaceholder failed: 0x{X:0>8}\n", .{@as(u32, @bitCast(mark_hr))});
        return error.PlaceholderMarkFailed;
    }

    const callbacks = PRJ_CALLBACKS{
        .StartDirectoryEnumerationCallback = onStartDir,
        .EndDirectoryEnumerationCallback = onEndDir,
        .GetDirectoryEnumerationCallback = onGetDir,
        .GetPlaceholderInfoCallback = onGetPlaceholder,
        .GetFileDataCallback = onGetFileData,
        .NotificationCallback = onNotification,
    };

    const empty_root: [:0]const u16 = &[0:0]u16{};
    const notif_mask: u32 = PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_MODIFIED |
        PRJ_NOTIFY_FILE_HANDLE_CLOSED_FILE_DELETED;
    const notif_mapping = [_]PRJ_NOTIFICATION_MAPPING{
        .{
            .NotificationBitMask = notif_mask,
            .NotificationRoot = empty_root.ptr,
        },
    };

    const options = PRJ_START_VIRTUALIZING_OPTIONS{
        .NotificationMappings = &notif_mapping,
        .NotificationMappingsCount = 1,
    };

    var handle: ?*anyopaque = null;
    const start_hr = prj.StartVirtualizing(&abs_w, &callbacks, null, &options, &handle);
    if (start_hr != S_OK) {
        std.debug.print("PrjStartVirtualizing failed: 0x{X:0>8}\n", .{@as(u32, @bitCast(start_hr))});
        return error.VirtualizationStartFailed;
    }
    defer prj.StopVirtualizing(handle);

    shutdown_event = CreateEventA(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = CloseHandle(shutdown_event);
    _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    defer _ = SetConsoleCtrlHandler(ctrlHandler, 0);

    _ = WaitForSingleObject(shutdown_event, 0xFFFFFFFF);
}

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