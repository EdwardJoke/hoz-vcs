//! File status tracking for Hoz VCS
//!
//! This module provides file status detection for the working directory,
//! including modified, new, and deleted file tracking.

const std = @import("std");
const Io = std.Io;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;

pub const FileStatus = enum {
    unmodified,
    modified,
    added,
    deleted,
    renamed,
    copied,
    untracked,
    ignored,
    conflicted,
};

pub const WorkDirStatus = struct {
    path: []const u8,
    status: FileStatus,
    index_entry: ?IndexEntry,
};

pub const StatusResult = struct {
    entries: []WorkDirStatus,
    has_changes: bool,
};

pub const StatusError = error{
    FileNotFound,
    PermissionDenied,
    IoError,
    OutOfMemory,
    InvalidPath,
};

pub fn detectStatusWithRetry(
    io: *Io,
    path: []const u8,
    index_entry: ?IndexEntry,
    max_retries: u32,
) !FileStatus {
    var last_error: StatusError = undefined;
    var retry_count: u32 = 0;

    while (retry_count < max_retries) : (retry_count += 1) {
        if (detectStatus(io, path, index_entry)) |status| {
            return status;
        } else |err| {
            last_error = switch (err) {
                error.FileNotFound => error.FileNotFound,
                error.PermissionDenied => error.PermissionDenied,
                else => error.IoError,
            };

            if (retry_count < max_retries - 1) {
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }
    }

    return last_error;
}

pub fn detectStatus(
    io: *Io,
    path: []const u8,
    index_entry: ?IndexEntry,
) !FileStatus {
    const dir = Io.Dir.cwd();

    if (index_entry == null) {
        const exists = dir.openFile(io, path, .{}) catch return .untracked;
        exists.close(io);
        return .added;
    }

    const entry = index_entry.?;
    const file = dir.openFile(io, path, .{}) catch return .deleted;
    defer file.close(io);

    const stat = try file.stat(io);

    const entry_size = @as(u64, entry.file_size);
    if (@as(u64, @intCast(stat.size)) != entry_size) {
        return .modified;
    }

    const entry_mtime_sec = @as(i64, @intCast(entry.mtime_sec));
    const entry_mtime_nsec = @as(i64, @intCast(entry.mtime_nsec));
    const stat_mtime_sec = @as(i64, @intCast(stat.mtime.seconds));
    const stat_mtime_nsec = @as(i64, @intCast(stat.mtime.nanos));

    const mtime_diff = (stat_mtime_sec - entry_mtime_sec) * 1000 + (stat_mtime_nsec - entry_mtime_nsec) / 1000000;
    if (mtime_diff > 1 or mtime_diff < -1) {
        return .modified;
    }

    return .unmodified;
}

pub const NfsTimestampTolerance = struct {
    pub const NFS_TIME_TOLERANCE_MS: i64 = 2000;
};

pub const CaseSensitivity = enum {
    case_sensitive,
    case_insensitive,
    case_preserving,
};

pub fn getFileSystemCaseSensitivity(io: *Io, path: []const u8) CaseSensitivity {
    _ = path;
    const dir = Io.Dir.cwd();
    const test_lower = "hoz_cs_test_lower";
    const test_upper = "HOZ_CS_TEST_UPPER";

    dir.createFile(io, test_lower, .{}) catch return .case_sensitive;
    defer dir.deleteFile(io, test_lower) catch {};

    const exists_upper = dir.openFile(io, test_upper, .{});
    if (exists_upper) |_| {
        dir.deleteFile(io, test_upper) catch {};
        return .case_insensitive;
    }

    return .case_preserving;
}

pub fn comparePaths(
    case_sensitivity: CaseSensitivity,
    path1: []const u8,
    path2: []const u8,
) std.math.Order {
    switch (case_sensitivity) {
        .case_sensitive => return std.mem.order(u8, path1, path2),
        .case_insensitive, .case_preserving => {
            const order = std.ascii.orderIgnoreCase(path1, path2);
            if (order == .eq) {
                return std.mem.order(u8, path1, path2);
            }
            return order;
        },
    }
}

pub fn pathsEqual(
    case_sensitivity: CaseSensitivity,
    path1: []const u8,
    path2: []const u8,
) bool {
    return comparePaths(case_sensitivity, path1, path2) == .eq;
}

pub fn findPathCaseInsensitive(
    io: *Io,
    dir_path: []const u8,
    target_name: []const u8,
    allocator: std.mem.Allocator,
) !?[]u8 {
    const dir = Io.Dir.cwd();
    const subdir = dir.openDir(io, dir_path, .{}) catch return null;
    defer subdir.close(io);

    var iterator = subdir.iterate(io, .{});
    while (try iterator.next(io)) |entry| {
        if (std.ascii.equalIgnoreCase(entry.name, target_name)) {
            return try allocator.dupe(u8, entry.name);
        }
    }

    return null;
}

pub fn detectStatusNfsFriendly(
    io: *Io,
    path: []const u8,
    index_entry: ?IndexEntry,
) !FileStatus {
    const dir = Io.Dir.cwd();

    if (index_entry == null) {
        const exists = dir.openFile(io, path, .{}) catch return .untracked;
        exists.close(io);
        return .added;
    }

    const entry = index_entry.?;
    const file = dir.openFile(io, path, .{}) catch return .deleted;
    defer file.close(io);

    const stat = try file.stat(io);

    const entry_size = @as(u64, entry.file_size);
    if (@as(u64, @intCast(stat.size)) != entry_size) {
        return .modified;
    }

    const entry_ctime = (@as(i64, @intCast(entry.ctime_sec)) << 32) | @as(i64, @intCast(entry.ctime_nsec));
    const stat_ctime = (@as(i64, @intCast(stat.ctime.seconds)) << 32) | @as(i64, @intCast(stat.ctime.nanos));
    const entry_mtime = (@as(i64, @intCast(entry.mtime_sec)) << 32) | @as(i64, @intCast(entry.mtime_nsec));
    const stat_mtime = (@as(i64, @intCast(stat.mtime.seconds)) << 32) | @as(i64, @intCast(stat.mtime.nanos));

    if (stat_ctime != entry_ctime or stat_mtime != entry_mtime) {
        return .modified;
    }

    return .unmodified;
}

pub fn scanWorkDirStatus(
    allocator: std.mem.Allocator,
    io: *Io,
    dir_path: []const u8,
    index_entries: []IndexEntry,
    entry_names: [][]const u8,
) !StatusResult {
    _ = dir_path;
    var statuses = std.ArrayList(WorkDirStatus).init(allocator);
    errdefer statuses.deinit();

    var has_changes = false;

    for (index_entries, entry_names) |entry, name| {
        const status = try detectStatus(io, name, entry);
        if (status != .unmodified) {
            has_changes = true;
        }
        try statuses.append(.{
            .path = try allocator.dupe(u8, name),
            .status = status,
            .index_entry = entry,
        });
    }

    return .{
        .entries = try statuses.toOwnedSlice(),
        .has_changes = has_changes,
    };
}

pub fn formatStatus(status: FileStatus) []const u8 {
    return switch (status) {
        .unmodified => ".",
        .modified => "M",
        .added => "A",
        .deleted => "D",
        .renamed => "R",
        .copied => "C",
        .untracked => "?",
        .ignored => "I",
        .conflicted => "U",
    };
}

pub fn isModified(status: FileStatus) bool {
    return switch (status) {
        .modified, .added, .deleted, .renamed, .copied, .conflicted => true,
        else => false,
    };
}

pub fn shortStatusChar(status: FileStatus) u8 {
    return switch (status) {
        .unmodified => ' ',
        .modified => 'M',
        .added => 'A',
        .deleted => 'D',
        .renamed => 'R',
        .copied => 'C',
        .untracked => '?',
        .ignored => '!',
        .conflicted => 'U',
    };
}

test "detectStatus returns untracked for new file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const status = try detectStatus(io, "new_file.txt", null);
    try std.testing.expect(status == .untracked);
}

test "detectStatus returns unmodified for matching file" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_status.txt";
    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, test_path, .{});
    try file.writeAll(io, "content");
    try file.sync(io);
    file.close(io);
    defer dir.deleteFile(io, test_path) catch {};

    const stat = try file.stat(io);
    const oid: [20]u8 = [_]u8{0} ** 20;
    const entry = IndexEntry.fromStat(stat, oid, test_path, 0);

    const status = try detectStatus(io, test_path, entry);
    try std.testing.expect(status == .unmodified);
}

test "formatStatus returns correct format" {
    try std.testing.expectEqualStrings(".", formatStatus(.unmodified));
    try std.testing.expectEqualStrings("M", formatStatus(.modified));
    try std.testing.expectEqualStrings("A", formatStatus(.added));
    try std.testing.expectEqualStrings("D", formatStatus(.deleted));
    try std.testing.expectEqualStrings("?", formatStatus(.untracked));
}

test "isModified returns correct boolean" {
    try std.testing.expect(!isModified(.unmodified));
    try std.testing.expect(isModified(.modified));
    try std.testing.expect(isModified(.added));
    try std.testing.expect(isModified(.deleted));
    try std.testing.expect(!isModified(.ignored));
    try std.testing.expect(!isModified(.untracked));
}

test "shortStatusChar returns correct character" {
    try std.testing.expectEqual(' ', shortStatusChar(.unmodified));
    try std.testing.expectEqual('M', shortStatusChar(.modified));
    try std.testing.expectEqual('A', shortStatusChar(.added));
    try std.testing.expectEqual('D', shortStatusChar(.deleted));
    try std.testing.expectEqual('?', shortStatusChar(.untracked));
}

test "detectStatus returns modified when size differs" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_modified.txt";
    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, test_path, .{});
    try file.writeAll(io, "original content");
    try file.sync(io);
    file.close(io);
    defer dir.deleteFile(io, test_path) catch {};

    const stat = try file.stat(io);
    const oid: [20]u8 = [_]u8{0} ** 20;
    const entry = IndexEntry.fromStat(stat, oid, test_path, 0);

    const file2 = try dir.openFile(io, test_path, .{});
    try file2.writeAll(io, "longer content that changes size");
    try file2.sync(io);
    file2.close(io);

    const status = try detectStatus(io, test_path, entry);
    try std.testing.expect(status == .modified);
}

test "formatStatus returns all status strings" {
    try std.testing.expectEqualStrings("R", formatStatus(.renamed));
    try std.testing.expectEqualStrings("C", formatStatus(.copied));
    try std.testing.expectEqualStrings("I", formatStatus(.ignored));
    try std.testing.expectEqualStrings("U", formatStatus(.conflicted));
}

test "isModified returns true for all change types" {
    try std.testing.expect(isModified(.renamed));
    try std.testing.expect(isModified(.copied));
    try std.testing.expect(isModified(.conflicted));
}

test "shortStatusChar returns all characters correctly" {
    try std.testing.expectEqual('R', shortStatusChar(.renamed));
    try std.testing.expectEqual('C', shortStatusChar(.copied));
    try std.testing.expectEqual('!', shortStatusChar(.ignored));
    try std.testing.expectEqual('U', shortStatusChar(.conflicted));
}

test "detectStatus returns deleted when file missing" {
    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const test_path = "test_deleted.txt";
    const dir = Io.Dir.cwd();
    const file = try dir.createFile(io, test_path, .{});
    try file.writeAll(io, "content");
    try file.sync(io);
    file.close(io);
    defer dir.deleteFile(io, test_path) catch {};

    const stat = try file.stat(io);
    const oid: [20]u8 = [_]u8{0} ** 20;
    const entry = IndexEntry.fromStat(stat, oid, test_path, 0);

    dir.deleteFile(io, test_path) catch {};

    const status = try detectStatus(io, test_path, entry);
    try std.testing.expect(status == .deleted);
}
