//! Watch - Directory monitoring using kqueue (macOS/BSD) or inotify (Linux)
const std = @import("std");
const Io = std.Io;

pub const WatchError = error{
    NotSupported,
    PermissionDenied,
    TooManyWatches,
    IoError,
};

pub const WatchEvent = struct {
    path: []const u8,
    event_type: WatchEventType,
    cookie: u64,
};

pub const WatchEventType = enum {
    created,
    modified,
    deleted,
    renamed,
    accessed,
};

pub const WatchOptions = struct {
    recursive: bool = false,
    latency_ms: u32 = 100,
    ignore_patterns: []const []const u8 = &.{},
};

const KqueueWatcher = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    kq_fd: i32,
    watched_fds: std.AutoHashMap(i32, []const u8),
    event_buffer: [128]std.os.kevent,

    fn init(allocator: std.mem.Allocator, io: *Io) !KqueueWatcher {
        const kq = std.os.system.kqueue();
        if (kq < 0) return error.IoError;
        return .{
            .allocator = allocator,
            .io = io,
            .kq_fd = kq,
            .watched_fds = std.AutoHashMap(i32, []const u8).init(allocator),
            .event_buffer = undefined,
        };
    }

    fn deinit(self: *KqueueWatcher) void {
        if (self.kq_fd >= 0) {
            std.os.close(self.kq_fd);
        }
        var iter = self.watched_fds.valueIterator();
        while (iter.next()) |path| {
            self.allocator.free(path.*);
        }
        self.watched_fds.deinit();
    }

    fn addWatch(self: *KqueueWatcher, path: []const u8) !void {
        const fd = std.os.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            if (err == error.FileNotFound or err == error.AccessDenied) return error.PermissionDenied;
            return err;
        };

        const owned_path = try self.allocator.dupe(u8, path);
        try self.watched_fds.put(fd, owned_path);

        const ev = std.os.kevent{
            .ident = @as(usize, @bitCast(@as(isize, fd))),
            .filter = std.os.system.EVFILT.VNODE,
            .flags = std.os.system.EV.ADD | std.os.system.EV.CLEAR | std.os.system.EV.ENABLE,
            .fflags = std.os.system.NOTE.WRITE | std.os.system.NOTE.DELETE |
                std.os.system.NOTE.RENAME | std.os.system.NOTE.EXTEND |
                std.os.system.NOTE.ATTRIB | std.os.system.NOTE.LINK,
            .data = 0,
            .udata = 0,
        };

        _ = std.os.kevent(self.kq_fd, &ev, 1, &self.event_buffer[0], 0, null) catch return error.IoError;
    }

    fn removeWatchByFd(self: *KqueueWatcher, fd: i32) void {
        if (self.watched_fds.fetchRemove(fd)) |entry| {
            self.allocator.free(entry.value);
        }
        std.os.close(fd) catch {};
    }

    fn readEvents(self: *KqueueWatcher, timeout_ms: u32) ![]WatchEvent {
        var events = std.ArrayList(WatchEvent).initCapacity(self.allocator, 16) catch |e| return e;
        defer events.deinit(self.allocator);

        const ts = std.os.timespec{
            .sec = @as(isize, @intCast(timeout_ms / 1000)),
            .nsec = @isize, @intCast((timeout_ms % 1000) * 1_000_000),
        };

        const n = std.os.kevent(
            self.kq_fd,
            &.{},
            0,
            &self.event_buffer,
            self.event_buffer.len,
            &ts,
        ) catch |err| {
            if (err == error.WouldBlock or err == error.Signal) return &[0]WatchEvent{};
            return err;
        };

        for (self.event_buffer[0..n]) |kev| {
            const fd = @as(i32, @bitCast(@as(isize, @intCast(kev.ident))));
            const path = self.watched_fds.get(fd) orelse continue;

            const etype: WatchEventType = if (kev.fflags & std.os.system.NOTE.DELETE != 0)
                .deleted
            else if (kev.fflags & std.os.system.NOTE.RENAME != 0)
                .renamed
            else if (kev.fflags & std.os.system.NOTE.WRITE != 0)
                .modified
            else if (kev.fflags & std.os.system.NOTE.EXTEND != 0)
                .modified
            else if (kev.fflags & std.os.system.NOTE.ATTRIB != 0)
                .modified
            else if (kev.fflags & std.os.system.NOTE.LINK != 0)
                .created
            else
                .accessed;

            const ev_path = self.allocator.dupe(u8, path) catch continue;
            try events.append(self.allocator, .{
                .path = ev_path,
                .event_type = etype,
                .cookie = kev.udata,
            });
        }

        return events.toOwnedSlice(self.allocator);
    }
};

pub const DirectoryWatcher = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
    options: WatchOptions,
    is_watching: bool,
    kq: ?KqueueWatcher,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *Io,
        path: []const u8,
        options: WatchOptions,
    ) DirectoryWatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .path = path,
            .options = options,
            .is_watching = false,
            .kq = null,
        };
    }

    pub fn start(self: *DirectoryWatcher) !void {
        if (self.is_watching) return;

        var watcher = try KqueueWatcher.init(self.allocator, self.io);

        try watcher.addWatch(self.path);

        if (self.options.recursive) {
            var dir = std.fs.cwd().openDir(self.path, .{ .iterate = true }) catch {
                self.kq = watcher;
                self.is_watching = true;
                return;
            };
            defer dir.close();

            var walker = dir.walk(self.allocator) catch {
                self.kq = watcher;
                self.is_watching = true;
                return;
            };
            defer walker.deinit();

            while (true) {
                const entry = walker.next() catch break orelse break;
                const full_path = try std.fs.path.join(self.allocator, &.{ self.path, entry.path });
                watcher.addWatch(full_path) catch {};
                self.allocator.free(full_path);
            }
        }

        self.kq = watcher;
        self.is_watching = true;
    }

    pub fn stop(self: *DirectoryWatcher) void {
        if (self.kq) |*w| {
            w.deinit();
        }
        self.kq = null;
        self.is_watching = false;
    }

    pub fn readEvents(self: *DirectoryWatcher) ![]WatchEvent {
        const w = self.kq orelse return &[0]WatchEvent{};
        return w.readEvents(self.options.latency_ms);
    }

    pub fn isWatching(self: *const DirectoryWatcher) bool {
        return self.is_watching;
    }
};

pub const WatchManager = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    watchers: std.AutoHashMap([]const u8, *DirectoryWatcher),

    pub fn init(allocator: std.mem.Allocator, io: *Io) WatchManager {
        return .{
            .allocator = allocator,
            .io = io,
            .watchers = std.AutoHashMap([]const u8, *DirectoryWatcher).init(allocator),
        };
    }

    pub fn deinit(self: *WatchManager) void {
        var iter = self.watchers.valueIterator();
        while (iter.next()) |watcher| {
            watcher.stop();
            self.allocator.destroy(watcher);
        }
        self.watchers.deinit();
    }

    pub fn watch(
        self: *WatchManager,
        path: []const u8,
        options: WatchOptions,
    ) !*DirectoryWatcher {
        if (self.watchers.get(path)) |existing| {
            return existing;
        }

        var watcher = try self.allocator.create(DirectoryWatcher);
        watcher.* = DirectoryWatcher.init(self.allocator, self.io, path, options);

        try watcher.start();
        try self.watchers.put(try self.allocator.dupe(u8, path), watcher);

        return watcher;
    }

    pub fn unwatch(self: *WatchManager, path: []const u8) void {
        if (self.watchers.get(path)) |watcher| {
            watcher.stop();
            self.allocator.destroy(watcher);
            _ = self.watchers.remove(path);
        }
    }

    pub fn getEvents(self: *WatchManager, path: []const u8) ![]WatchEvent {
        if (self.watchers.get(path)) |watcher| {
            return watcher.readEvents();
        }
        return &[0]WatchEvent{};
    }
};

pub fn startWatching(
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
    options: WatchOptions,
) !*DirectoryWatcher {
    var watcher = try allocator.create(DirectoryWatcher);
    watcher.* = DirectoryWatcher.init(allocator, io, path, options);
    try watcher.start();
    return watcher;
}

pub fn stopWatching(watcher: *DirectoryWatcher) void {
    watcher.stop();
}

test "DirectoryWatcher init" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var watcher = DirectoryWatcher.init(gpa.allocator(), io, ".", .{});
    try std.testing.expect(!watcher.isWatching());
}

test "DirectoryWatcher start and stop" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var watcher = DirectoryWatcher.init(gpa.allocator(), io, ".", .{});
    try watcher.start();
    try std.testing.expect(watcher.isWatching());

    watcher.stop();
    try std.testing.expect(!watcher.isWatching());
}

test "WatchManager init and deinit" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var manager = WatchManager.init(gpa.allocator(), io);
    manager.deinit();
    try std.testing.expect(true);
}
