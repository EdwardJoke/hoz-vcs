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
    const current_size: u32 = @intCast(stat.size);
    const current_mtime = @as(u64, @intCast(stat.mtime));

    if (current_size != entry.file_size) {
        return .modified;
    }

    const entry_mtime = (@as(u64, entry.mtime_sec) << 32) | entry.mtime_nsec;
    if (current_mtime != entry_mtime) {
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
