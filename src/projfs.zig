const std = @import("std");
const builtin = @import("builtin");
const DefaultFs = @import("root.zig").DefaultFs;

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_FILENOTFOUND: HRESULT = @bitCast(@as(u32, 0x80070002));
pub const E_INSUFFICIENT_BUFFER: HRESULT = @bitCast(@as(u32, 0x8007007A));
pub const E_ALREADY_EXISTS: HRESULT = @bitCast(@as(u32, 0x800700B7));

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
    EaInformation: extern struct {
        EaBufferSize: u32 = 0,
        OffsetToFirstEa: u32 = 0,
    } = .{},
    SecurityInformation: extern struct {
        SecurityBufferSize: u32 = 0,
        OffsetToSecurityDescriptor: u32 = 0,
    } = .{},
    StreamsInformation: extern struct {
        StreamsInfoBufferSize: u32 = 0,
        OffsetToFirstStreamInfo: u32 = 0,
    } = .{},
    VersionInfo: extern struct {
        ProviderID: [128]u8 = @splat(0),
        ContentID: [128]u8 = @splat(0),
    } = .{},
    VariableData: [1]u8 = @splat(0),
};

const PRJ_START_DIRECTORY_ENUMERATION_CB = *const fn (
    data: *const PRJ_CALLBACK_DATA,
    enumerationId: *const GUID,
) callconv(.winapi) HRESULT;

const PRJ_END_DIRECTORY_ENUMERATION_CB = *const fn (
    data: *const PRJ_CALLBACK_DATA,
    enumerationId: *const GUID,
) callconv(.winapi) HRESULT;

const PRJ_GET_DIRECTORY_ENUMERATION_CB = *const fn (
    data: *const PRJ_CALLBACK_DATA,
    enumerationId: *const GUID,
    searchExpression: ?[*:0]const u16,
    dirEntryBufferHandle: ?*anyopaque,
) callconv(.winapi) HRESULT;

const PRJ_GET_PLACEHOLDER_INFO_CB = *const fn (
    data: *const PRJ_CALLBACK_DATA,
) callconv(.winapi) HRESULT;

const PRJ_GET_FILE_DATA_CB = *const fn (
    data: *const PRJ_CALLBACK_DATA,
    byteOffset: u64,
    length: u32,
) callconv(.winapi) HRESULT;

const PRJ_CALLBACKS = extern struct {
    StartDirectoryEnumerationCallback: PRJ_START_DIRECTORY_ENUMERATION_CB,
    EndDirectoryEnumerationCallback: PRJ_END_DIRECTORY_ENUMERATION_CB,
    GetDirectoryEnumerationCallback: PRJ_GET_DIRECTORY_ENUMERATION_CB,
    GetPlaceholderInfoCallback: PRJ_GET_PLACEHOLDER_INFO_CB,
    GetFileDataCallback: PRJ_GET_FILE_DATA_CB,
    QueryFileNameCallback: ?*anyopaque = null,
    NotificationCallback: ?*anyopaque = null,
    CancelCommandCallback: ?*anyopaque = null,
};

extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(hLibModule: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *anyopaque) callconv(.winapi) void;

const FnPrjStartVirtualizing = *const fn (
    [*:0]const u16,
    *const PRJ_CALLBACKS,
    ?*const anyopaque,
    ?*const anyopaque,
    *?*anyopaque,
) callconv(.winapi) HRESULT;

const FnPrjStopVirtualizing = *const fn (?*anyopaque) callconv(.winapi) void;

const FnPrjMarkDirectoryAsPlaceholder = *const fn (
    [*:0]const u16,
    ?[*:0]const u16,
    ?*const anyopaque,
    *const GUID,
) callconv(.winapi) HRESULT;

const FnPrjFillDirEntryBuffer = *const fn (
    [*:0]const u16,
    *const PRJ_FILE_BASIC_INFO,
    ?*anyopaque,
) callconv(.winapi) HRESULT;

const FnPrjWriteFileData = *const fn (
    ?*anyopaque,
    *const GUID,
    *const anyopaque,
    u64,
    u32,
) callconv(.winapi) HRESULT;

const FnPrjWritePlaceholderInfo = *const fn (
    ?*anyopaque,
    [*:0]const u16,
    *const PRJ_PLACEHOLDER_INFO,
    u32,
) callconv(.winapi) HRESULT;

const FnPrjFileNameMatch = *const fn ([*:0]const u16, [*:0]const u16) callconv(.winapi) bool;
const FnPrjFileNameCompare = *const fn ([*:0]const u16, [*:0]const u16) callconv(.winapi) i32;

const Api = struct {
    handle: *anyopaque,
    PrjStartVirtualizing: FnPrjStartVirtualizing,
    PrjStopVirtualizing: FnPrjStopVirtualizing,
    PrjMarkDirectoryAsPlaceholder: FnPrjMarkDirectoryAsPlaceholder,
    PrjFillDirEntryBuffer: FnPrjFillDirEntryBuffer,
    PrjWriteFileData: FnPrjWriteFileData,
    PrjWritePlaceholderInfo: FnPrjWritePlaceholderInfo,
    PrjFileNameMatch: FnPrjFileNameMatch,
    PrjFileNameCompare: FnPrjFileNameCompare,

    fn load() !Api {
        const h = LoadLibraryA("ProjectedFSLib.dll") orelse return error.ProjFsNotAvailable;

        const Cast = struct {
            inline fn fnPtr(comptime T: type, handle: *anyopaque, name: [*:0]const u8) !T {
                const p = GetProcAddress(handle, name) orelse return error.SymbolNotFound;
                return @ptrCast(@alignCast(p));
            }
        };

        return Api{
            .handle = h,
            .PrjStartVirtualizing = try Cast.fnPtr(FnPrjStartVirtualizing, h, "PrjStartVirtualizing"),
            .PrjStopVirtualizing = try Cast.fnPtr(FnPrjStopVirtualizing, h, "PrjStopVirtualizing"),
            .PrjMarkDirectoryAsPlaceholder = try Cast.fnPtr(FnPrjMarkDirectoryAsPlaceholder, h, "PrjMarkDirectoryAsPlaceholder"),
            .PrjFillDirEntryBuffer = try Cast.fnPtr(FnPrjFillDirEntryBuffer, h, "PrjFillDirEntryBuffer"),
            .PrjWriteFileData = try Cast.fnPtr(FnPrjWriteFileData, h, "PrjWriteFileData"),
            .PrjWritePlaceholderInfo = try Cast.fnPtr(FnPrjWritePlaceholderInfo, h, "PrjWritePlaceholderInfo"),
            .PrjFileNameMatch = try Cast.fnPtr(FnPrjFileNameMatch, h, "PrjFileNameMatch"),
            .PrjFileNameCompare = try Cast.fnPtr(FnPrjFileNameCompare, h, "PrjFileNameCompare"),
        };
    }
};

extern "kernel32" fn GetFullPathNameW(
    lpFileName: [*:0]const u16,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?*anyopaque,
) callconv(.winapi) u32;

extern "kernel32" fn CreateEventA(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u8,
) callconv(.winapi) ?*anyopaque;

extern "kernel32" fn SetEvent(hEvent: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (u32) callconv(.winapi) i32,
    Add: i32,
) callconv(.winapi) i32;

const INFINITE: u32 = 0xFFFFFFFF;

const DirItem = struct {
    name_w: [260:0]u16,
    is_dir: bool,
    size: u64,
};

const EnumSession = struct {
    items: std.ArrayList(DirItem),
    cursor: usize,
    pattern: [260:0]u16,
    pattern_set: bool,
};

const Mutex = struct {
    srw: ?*anyopaque = null,
    pub fn lock(self: *Mutex) void {
        AcquireSRWLockExclusive(@ptrCast(&self.srw));
    }
    pub fn unlock(self: *Mutex) void {
        ReleaseSRWLockExclusive(@ptrCast(&self.srw));
    }
};

const Context = struct {
    fs: *DefaultFs,
    allocator: std.mem.Allocator,
    root_path: []const u8,
    sessions: std.AutoHashMap(GUID, EnumSession),
    mutex: Mutex = .{},
};

var global_ctx: Context = undefined;
var api: Api = undefined;
var global_shutdown_event: ?*anyopaque = null;

fn ctrlHandler(_: u32) callconv(.winapi) i32 {
    if (global_shutdown_event) |event| {
        _ = SetEvent(event);
        return 1;
    }
    return 0;
}

fn u16ToUtf8(out: []u8, maybe_src: ?[*:0]const u16) []const u8 {
    const src = maybe_src orelse return "";
    var len: usize = 0;
    while (src[len] != 0) : (len += 1) {}
    const end = std.unicode.utf16LeToUtf8(out, src[0..len]) catch 0;
    for (out[0..end]) |*b| {
        if (b.* == '\\') b.* = '/';
    }
    return out[0..end];
}

fn isVirtualDirectory(dir_path: []const u8) bool {
    if (dir_path.len == 0) return true;
    for (global_ctx.fs.entries.items) |entry| {
        if (entry.path.len > dir_path.len and
            std.mem.startsWith(u8, entry.path, dir_path) and
            entry.path[dir_path.len] == '/')
        {
            return true;
        }
    }
    return false;
}

fn onStartDir(data: *const PRJ_CALLBACK_DATA, id: *const GUID) callconv(.winapi) HRESULT {
    global_ctx.mutex.lock();
    defer global_ctx.mutex.unlock();

    var path_buf: [512]u8 = undefined;
    const dir_path = u16ToUtf8(&path_buf, data.FilePathName);

    var session = EnumSession{
        .items = std.ArrayList(DirItem).initCapacity(global_ctx.allocator, 16) catch return E_INSUFFICIENT_BUFFER,
        .cursor = 0,
        .pattern = undefined,
        .pattern_set = false,
    };
    errdefer session.items.deinit(global_ctx.allocator);

    var seen_dirs = std.StringHashMap(void).init(global_ctx.allocator);
    defer seen_dirs.deinit();

    for (global_ctx.fs.entries.items) |entry| {
        const rel = if (dir_path.len == 0)
            entry.path
        else if (std.mem.startsWith(u8, entry.path, dir_path) and
            entry.path.len > dir_path.len and
            entry.path[dir_path.len] == '/')
            entry.path[dir_path.len + 1 ..]
        else
            continue;

        if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
            const sub = rel[0..slash];
            if (!seen_dirs.contains(sub)) {
                seen_dirs.put(sub, {}) catch continue;
                var item = DirItem{ .name_w = undefined, .is_dir = true, .size = 0 };
                const u16_len = std.unicode.utf8ToUtf16Le(&item.name_w, sub) catch continue;
                item.name_w[u16_len] = 0;
                session.items.append(global_ctx.allocator, item) catch continue;
            }
        } else {
            var item = DirItem{ .name_w = undefined, .is_dir = false, .size = entry.size };
            const u16_len = std.unicode.utf8ToUtf16Le(&item.name_w, rel) catch continue;
            item.name_w[u16_len] = 0;
            session.items.append(global_ctx.allocator, item) catch continue;
        }
    }

    const Sorter = struct {
        fn lessThan(_: void, a: DirItem, b: DirItem) bool {
            return api.PrjFileNameCompare(&a.name_w, &b.name_w) < 0;
        }
    };
    std.mem.sort(DirItem, session.items.items, {}, Sorter.lessThan);

    global_ctx.sessions.put(id.*, session) catch return E_INSUFFICIENT_BUFFER;
    return S_OK;
}

fn onEndDir(_: *const PRJ_CALLBACK_DATA, id: *const GUID) callconv(.winapi) HRESULT {
    global_ctx.mutex.lock();
    defer global_ctx.mutex.unlock();

    if (global_ctx.sessions.fetchRemove(id.*)) |kv| {
        var s = kv.value;
        s.items.deinit(global_ctx.allocator);
    }
    return S_OK;
}

fn onGetDir(
    data: *const PRJ_CALLBACK_DATA,
    id: *const GUID,
    searchExpr: ?[*:0]const u16,
    dirBuffer: ?*anyopaque,
) callconv(.winapi) HRESULT {
    global_ctx.mutex.lock();
    defer global_ctx.mutex.unlock();

    const session = global_ctx.sessions.getPtr(id.*) orelse return E_FILENOTFOUND;

    const restart = (data.Flags & 1) != 0;
    if (!session.pattern_set or restart) {
        session.cursor = 0;
        if (searchExpr) |expr| {
            var i: usize = 0;
            while (expr[i] != 0 and i < 259) : (i += 1) {
                session.pattern[i] = expr[i];
            }
            session.pattern[i] = 0;
        } else {
            session.pattern[0] = '*';
            session.pattern[1] = 0;
        }
        session.pattern_set = true;
    }

    var added: usize = 0;
    while (session.cursor < session.items.items.len) {
        const it = &session.items.items[session.cursor];

        if (api.PrjFileNameMatch(&it.name_w, &session.pattern)) {
            const info = PRJ_FILE_BASIC_INFO{
                .IsDirectory = if (it.is_dir) 1 else 0,
                .FileSize = if (it.is_dir) 0 else @intCast(it.size),
                .FileAttributes = if (it.is_dir) 0x10 else 0x80,
            };

            const fill_hr = api.PrjFillDirEntryBuffer(&it.name_w, &info, dirBuffer);
            if (fill_hr == E_INSUFFICIENT_BUFFER) {
                return if (added == 0) E_INSUFFICIENT_BUFFER else S_OK;
            }
            added += 1;
        }
        session.cursor += 1;
    }

    return S_OK;
}

fn onGetPlaceholder(data: *const PRJ_CALLBACK_DATA) callconv(.winapi) HRESULT {
    var path_buf: [512]u8 = undefined;
    const path = u16ToUtf8(&path_buf, data.FilePathName);

    var info = std.mem.zeroes(PRJ_PLACEHOLDER_INFO);

    if (global_ctx.fs.findEntry(path)) |entry| {
        info.FileBasicInfo.IsDirectory = 0;
        info.FileBasicInfo.FileSize = @intCast(entry.size);
        info.FileBasicInfo.FileAttributes = 0x80;
    } else if (isVirtualDirectory(path)) {
        info.FileBasicInfo.IsDirectory = 1;
        info.FileBasicInfo.FileSize = 0;
        info.FileBasicInfo.FileAttributes = 0x10;
    } else {
        return E_FILENOTFOUND;
    }

    const path_name = data.FilePathName orelse return E_FILENOTFOUND;
    return api.PrjWritePlaceholderInfo(
        data.NamespaceVirtualizationContext,
        path_name,
        &info,
        @sizeOf(PRJ_PLACEHOLDER_INFO),
    );
}

fn onGetFileData(
    data: *const PRJ_CALLBACK_DATA,
    byteOffset: u64,
    length: u32,
) callconv(.winapi) HRESULT {
    var path_buf: [512]u8 = undefined;
    const path = u16ToUtf8(&path_buf, data.FilePathName);

    const file_buf = global_ctx.allocator.alloc(u8, length) catch return E_INSUFFICIENT_BUFFER;
    defer global_ctx.allocator.free(file_buf);

    const bytes_read = global_ctx.fs.read(global_ctx.allocator, path, byteOffset, file_buf) catch {
        return E_FILENOTFOUND;
    };

    return api.PrjWriteFileData(
        data.NamespaceVirtualizationContext,
        &data.DataStreamId,
        file_buf.ptr,
        byteOffset,
        @intCast(bytes_read),
    );
}

pub fn mount(
    allocator: std.mem.Allocator,
    fs: *DefaultFs,
    root_path: []const u8,
) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    api = try Api.load();
    defer _ = FreeLibrary(api.handle);

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

    const mark_hr = api.PrjMarkDirectoryAsPlaceholder(&abs_w, null, null, &guid);
    if (mark_hr != S_OK and mark_hr != E_ALREADY_EXISTS) return error.PlaceholderMarkFailed;

    const callbacks = PRJ_CALLBACKS{
        .StartDirectoryEnumerationCallback = onStartDir,
        .EndDirectoryEnumerationCallback = onEndDir,
        .GetDirectoryEnumerationCallback = onGetDir,
        .GetPlaceholderInfoCallback = onGetPlaceholder,
        .GetFileDataCallback = onGetFileData,
        .QueryFileNameCallback = null,
    };

    global_ctx = Context{
        .fs = fs,
        .allocator = allocator,
        .root_path = root_path,
        .sessions = std.AutoHashMap(GUID, EnumSession).init(allocator),
    };
    defer {
        var it = global_ctx.sessions.valueIterator();
        while (it.next()) |s| {
            s.items.deinit(allocator);
        }
        global_ctx.sessions.deinit();
    }

    var session: ?*anyopaque = null;
    const start_hr = api.PrjStartVirtualizing(&abs_w, &callbacks, null, null, &session);
    if (start_hr != S_OK) return error.VirtualizationStartFailed;
    defer api.PrjStopVirtualizing(session);

    const shutdown_event = CreateEventA(null, 1, 0, null) orelse return error.EventCreationFailed;
    defer _ = CloseHandle(shutdown_event);

    global_shutdown_event = shutdown_event;
    defer global_shutdown_event = null;

    _ = SetConsoleCtrlHandler(ctrlHandler, 1);
    defer _ = SetConsoleCtrlHandler(ctrlHandler, 0);

    std.debug.print("Virtual filesystem mounted on '{s}'. Press Ctrl+C to unmount...\n", .{root_path});

    _ = WaitForSingleObject(shutdown_event, INFINITE);

    std.debug.print("\nUnmounted '{s}'.\n", .{root_path});
}
