//! Lock - Workdir locking mechanism for atomic operations
//!
//! File-based locking using O_EXCL create + PID-based stale detection.

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

    pub fn deinit(self: *LockHandle, keep: bool) void {
        if (self.fd) |fd| {
            fd.close();
            self.fd = null;
        }
        if (!keep and self.path.len > 0) {
            std.fs.cwd().deleteFile(self.path) catch {};
        }
    }
};

pub const WorkDirLock = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    held_locks: std.AutoHashMapUnmanaged([]const u8, LockHandle),
    default_options: LockOptions,

    pub fn init(allocator: std.mem.Allocator, io: *Io) WorkDirLock {
        return .{
            .allocator = allocator,
            .io = io,
            .held_locks = .{},
            .default_options = LockOptions{},
        };
    }

    pub fn deinit(self: *WorkDirLock) void {
        var iter = self.held_locks.valueIterator();
        while (iter.next()) |lock| {
            lock.deinit(self.default_options.keep_lock);
        }
        var key_iter = self.held_locks.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.held_locks.deinit(self.allocator);
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
        const max_attempts = @max(1, (options.timeout_ms / options.retry_interval_ms) + 1);

        while (attempts < max_attempts) : (attempts += 1) {
            if (self.tryAcquireLock(lock_file_path)) |handle| {
                try self.held_locks.put(self.allocator, try self.allocator.dupe(u8, lock_path), handle);
                return handle;
            } else |_| {
                if (attempts < max_attempts - 1) {
                    busyWait(options.retry_interval_ms);
                }
            }
        }

        self.allocator.free(lock_file_path);
        return LockError.LockTimeout;
    }

    fn tryAcquireLock(
        self: *WorkDirLock,
        lock_path: []const u8,
    ) !LockHandle {
        _ = self;

        if (isStaleLock(lock_path)) {
            std.fs.cwd().deleteFile(lock_path) catch {};
        }

        const lock_file = std.fs.cwd().createFile(lock_path, .{
            .exclusive = true,
            .truncate = false,
            .mode = 0o644,
        }) catch |err| {
            if (err == error.PathAlreadyExists) {
                return LockError.LockHeld;
            }
            return err;
        };

        const pid = std.process.getCurrentPid();
        const writer = lock_file.writer();
        writer.print("{d}\n", .{pid}) catch {};

        return LockHandle{
            .path = lock_path,
            .fd = lock_file,
            .lock_type = .exclusive,
        };
    }

    pub fn releaseLock(self: *WorkDirLock, lock_path: []const u8) void {
        const entry = self.held_locks.fetchRemove(lock_path) orelse return;
        self.allocator.free(entry.key);
        entry.value.deinit(self.default_options.keep_lock);
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

fn isStaleLock(lock_path: []const u8) bool {
    const file = std.fs.cwd().openFile(lock_path, .{}) catch return false;
    defer file.close();

    var buf: [64]u8 = undefined;
    const bytes_read = file.read(&buf) catch return false;
    const content = std.mem.trim(u8, buf[0..bytes_read], "\r\n");

    const pid = std.fmt.parseInt(i32, content, 10) catch return false;

    if (comptime @import("builtin").os.tag == .macos or
        comptime @import("builtin").os.tag == .linux)
    {
        const result = std.os.kill(pid, 0);
        return error.ProcessNotFound == result or error.ESRCH == result;
    }

    return false;
}

fn busyWait(ms: u32) void {
    const target_ns = @as(u64, ms) * 1_000_000;
    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < target_ns) {}
}

pub fn acquireSharedLock(
    _: std.mem.Allocator,
    _: *Io,
    lock: *WorkDirLock,
    path: []const u8,
) !LockHandle {
    return lock.acquireLock(path, .shared, lock.default_options);
}

pub fn acquireExclusiveLock(
    _: std.mem.Allocator,
    _: *Io,
    lock: *WorkDirLock,
    path: []const u8,
) !LockHandle {
    return lock.acquireLock(path, .exclusive, lock.default_options);
}

pub fn releaseSharedLock(lock: *WorkDirLock, path: []const u8) void {
    lock.releaseLock(path);
}

pub fn releaseExclusiveLock(lock: *WorkDirLock, path: []const u8) void {
    lock.releaseLock(path);
}

test "WorkDirLock init and deinit" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var lock = WorkDirLock.init(std.testing.allocator, io);
    lock.deinit();
}

test "WorkDirLock acquire and release" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var lock = WorkDirLock.init(std.testing.allocator, io);
    defer lock.deinit();

    const handle = lock.acquireLock("/tmp/test_hoz_lock", .exclusive, .{ .timeout_ms = 1000, .retry_interval_ms = 50 }) catch |err| {
        if (err == error.PermissionDenied or err == error.IoError) return;
        return err;
    };
    defer lock.releaseLock("/tmp/test_hoz_lock");

    try std.testing.expect(lock.isLocked("/tmp/test_hoz_lock"));
    try std.testing.expect(handle.fd != null);
}

test "WorkDirLock double acquire fails" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var lock1 = WorkDirLock.init(std.testing.allocator, io);
    defer lock1.deinit();

    var lock2 = WorkDirLock.init(std.testing.allocator, io);
    defer lock2.deinit();

    const h1 = lock1.acquireLock("/tmp/test_hoz_lock_race", .exclusive, .{ .timeout_ms = 1000, .retry_interval_ms = 50 }) catch |err| {
        if (err == error.PermissionDenied or err == error.IoError) return;
        return err;
    };
    defer lock1.releaseLock("/tmp/test_hoz_lock_race");

    const result = lock2.acquireLock("/tmp/test_hoz_lock_race", .exclusive, .{ .timeout_ms = 100, .retry_interval_ms = 20 });

    try std.testing.expectError(error.LockTimeout, result);
}

test "WorkDirLock shared lock acquire/release cycle" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var lock = WorkDirLock.init(std.testing.allocator, io);
    defer lock.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const handle = lock.acquireLock("/tmp/test_hoz_lock_cycle", .shared, .{ .timeout_ms = 500, .retry_interval_ms = 20 }) catch |err| {
            if (err == error.PermissionDenied or err == error.IoError) return;
            return err;
        };
        _ = handle;
        lock.releaseLock("/tmp/test_hoz_lock_cycle");
    }
}

test "WorkDirLock stale PID detection" {
    try std.testing.expect(isPidAlive(999999999) == false);
}
