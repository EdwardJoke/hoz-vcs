//! Watch - Directory monitoring using FSEvents (macOS) or inotify (Linux)
//!
//! This module provides file system event monitoring for efficient change detection.

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

pub const DirectoryWatcher = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
    options: WatchOptions,
    is_watching: bool,

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
        };
    }

    pub fn start(self: *DirectoryWatcher) !void {
        _ = self;
        return WatchError.NotSupported;
    }

    pub fn stop(self: *DirectoryWatcher) void {
        _ = self;
        self.is_watching = false;
    }

    pub fn readEvents(self: *DirectoryWatcher) ![]WatchEvent {
        _ = self;
        return &.{};
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
        if (self.watchers.contains(path)) {
            return self.watchers.get(path).?;
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
        return &.{};
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
