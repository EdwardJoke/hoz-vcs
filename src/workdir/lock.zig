//! Lock - Workdir locking mechanism for atomic operations
//!
//! This module provides file-based locking for safe concurrent operations.
//! Locks are implemented as atomic file operations using standard Unix patterns.

const std = @import("std");
const Io = std.Io;

pub const LockError = error{
    LockHeld,
    LockTimeout,
    PermissionDenied,
    IoError,
    InvalidPath,
};

pub const LockOptions = struct {
    timeout_ms: u32 = 5000,
    retry_interval_ms: u32 = 100,
    keep_lock: bool = false,
};

pub const LockHandle = struct {
    path: []const u8,
    fd: ?std.fs.File = null,
    lock_type: LockType,

    pub const LockType = enum {
        shared,
        exclusive,
    };
};

pub const WorkDirLock = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    held_locks: std.AutoHashMap([]const u8, LockHandle),
    default_options: LockOptions,

    pub fn init(allocator: std.mem.Allocator, io: *Io) WorkDirLock {
        return .{
            .allocator = allocator,
            .io = io,
            .held_locks = std.AutoHashMap([]const u8, LockHandle).init(allocator),
            .default_options = LockOptions{},
        };
    }

    pub fn deinit(self: *WorkDirLock) void {
        var iter = self.held_locks.valueIterator();
        while (iter.next()) |lock| {
            self.releaseLock(lock.path) catch {};
        }
        self.held_locks.deinit();
    }

    pub fn acquireLock(
        self: *WorkDirLock,
        lock_path: []const u8,
        lock_type: LockHandle.LockType,
        options: LockOptions,
    ) !LockHandle {
        const lock_file_path = try std.mem.concat(self.allocator, u8, &.{ lock_path, ".lock" });
        errdefer self.allocator.free(lock_file_path);

        var attempts: u32 = 0;
        const max_attempts = (options.timeout_ms / options.retry_interval_ms) + 1;

        while (attempts < max_attempts) : (attempts += 1) {
            const result = self.tryAcquireLock(lock_file_path, lock_type);
            if (result) |handle| {
                try self.held_locks.put(try self.allocator.dupe(u8, lock_path), handle);
                return handle;
            } else |err| {
                if (err == error.LockHeld and attempts < max_attempts - 1) {
                    std.time.sleep(options.retry_interval_ms * std.time.ns_per_ms);
                    continue;
                }
                return err;
            }
        }

        return LockError.LockTimeout;
    }

    fn tryAcquireLock(
        self: *WorkDirLock,
        lock_path: []const u8,
        lock_type: LockHandle.LockType,
    ) !LockHandle {
        _ = self;
        const dir = std.fs.cwd();

        const open_flags: std.fs.File.OpenFlags = switch (lock_type) {
            .shared => .{ .mode = .read_only },
            .exclusive => .{ .mode = .write_only },
        };

        const lock_file = dir.createFile(lock_path, .{
            .exclusive = true,
            .truncate = false,
        }) catch |err| {
            if (err == error.PathAlreadyExists) {
                return LockError.LockHeld;
            }
            return err;
        };

        return LockHandle{
            .path = lock_path,
            .fd = lock_file,
            .lock_type = lock_type,
        };
    }

    pub fn releaseLock(self: *WorkDirLock, lock_path: []const u8) !void {
        const handle = self.held_locks.get(lock_path) orelse return;
        if (handle.fd) |fd| {
            fd.close();
        }
        if (!self.default_options.keep_lock) {
            std.fs.cwd().deleteFile(handle.path) catch {};
        }
        _ = self.held_locks.remove(lock_path);
    }

    pub fn isLocked(self: *WorkDirLock, lock_path: []const u8) bool {
        return self.held_locks.contains(lock_path);
    }

    pub fn holdIndexLock(
        self: *WorkDirLock,
        git_dir: []const u8,
        options: LockOptions,
    ) !LockHandle {
        const index_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/index" });
        defer self.allocator.free(index_path);
        return self.acquireLock(index_path, .exclusive, options);
    }

    pub fn holdRefLock(
        self: *WorkDirLock,
        git_dir: []const u8,
        ref_name: []const u8,
        options: LockOptions,
    ) !LockHandle {
        const ref_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/refs/heads/", ref_name });
        defer self.allocator.free(ref_path);
        return self.acquireLock(ref_path, .exclusive, options);
    }

    pub fn holdCommitLock(
        self: *WorkDirLock,
        git_dir: []const u8,
        options: LockOptions,
    ) !LockHandle {
        const commit_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/COMMIT_EDITMSG" });
        defer self.allocator.free(commit_path);
        return self.acquireLock(commit_path, .exclusive, options);
    }

    pub fn holdPackLock(
        self: *WorkDirLock,
        git_dir: []const u8,
        pack_name: []const u8,
        options: LockOptions,
    ) !LockHandle {
        const pack_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/objects/pack/", pack_name });
        defer self.allocator.free(pack_path);
        return self.acquireLock(pack_path, .shared, options);
    }
};

pub fn acquireSharedLock(
    allocator: std.mem.Allocator,
    io: *Io,
    lock: *WorkDirLock,
    path: []const u8,
) !LockHandle {
    return lock.acquireLock(path, .shared, lock.default_options);
}

pub fn acquireExclusiveLock(
    allocator: std.mem.Allocator,
    io: *Io,
    lock: *WorkDirLock,
    path: []const u8,
) !LockHandle {
    return lock.acquireLock(path, .exclusive, lock.default_options);
}

pub fn releaseSharedLock(lock: *WorkDirLock, path: []const u8) !void {
    try lock.releaseLock(path);
}

pub fn releaseExclusiveLock(lock: *WorkDirLock, path: []const u8) !void {
    try lock.releaseLock(path);
}

test "WorkDirLock init and deinit" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var lock = WorkDirLock.init(gpa.allocator(), io);
    lock.deinit();
    try std.testing.expect(lock.held_locks.count() == 0);
}
