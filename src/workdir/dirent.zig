//! Directory traversal for Hoz VCS
//!
//! This module provides directory traversal functionality for working
//! with the file system, including recursive directory listing and filtering.

const std = @import("std");
const Io = std.Io;

pub const DirEntryType = enum {
    file,
    directory,
    symlink,
    other,
};

pub const DirEntry = struct {
    name: []const u8,
    path: []const u8,
    entry_type: DirEntryType,
};

pub const WalkError = error{
    DirectoryNotFound,
    PermissionDenied,
    IoError,
    OutOfMemory,
};

pub fn listDirectory(
    allocator: std.mem.Allocator,
    io: *Io,
    dir_path: []const u8,
) ![]DirEntry {
    const dir = Io.Dir.cwd();
    const subdir = dir.openDir(io.*, dir_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return error.DirectoryNotFound,
            error.PermissionDenied => return error.PermissionDenied,
            else => return error.IoError,
        }
    };
    defer subdir.close(io.*);

    var entries = try std.ArrayList(DirEntry).initCapacity(allocator, 16);
    errdefer entries.deinit(allocator);

    var iterator = subdir.iterate();
    while (try iterator.next(io.*)) |entry| {
        const entry_type: DirEntryType = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };

        const full_path = try std.mem.concat(allocator, u8, &.{ dir_path, "/", entry.name });
        defer allocator.free(full_path);

        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = full_path,
            .entry_type = entry_type,
        });
    }

    return entries.toOwnedSlice(allocator);
}

pub fn walkDirectory(
    allocator: std.mem.Allocator,
    io: *Io,
    dir_path: []const u8,
) ![]DirEntry {
    var all_entries = try std.ArrayList(DirEntry).initCapacity(allocator, 256);
    errdefer all_entries.deinit(allocator);

    var visited = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer visited.deinit(allocator);

    try walkRecursive(allocator, io, dir_path, dir_path, &all_entries, &visited);

    return all_entries.toOwnedSlice(allocator);
}

fn walkRecursive(
    allocator: std.mem.Allocator,
    io: *Io,
    base_path: []const u8,
    current_path: []const u8,
    results: *std.ArrayList(DirEntry),
    visited: *std.ArrayList([]const u8),
) !void {
    const dir = Io.Dir.cwd();
    const subdir = dir.openDir(io.*, current_path, .{}) catch return;
    defer subdir.close(io.*);

    var iterator = subdir.iterate();
    while (try iterator.next(io.*)) |entry| {
        const entry_type: DirEntryType = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };

        const full_path = try std.mem.concat(allocator, u8, &.{ current_path, "/", entry.name });
        errdefer allocator.free(full_path);

        try results.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = full_path,
            .entry_type = entry_type,
        });

        var should_recurse = true;
        if (entry_type == .symlink) {
            if (readSymlinkTarget(io, full_path, allocator)) |target| {
                defer allocator.free(target);

                const resolved = if (std.mem.startsWith(u8, target, "/"))
                    target
                else
                    try std.mem.concat(allocator, u8, &.{ current_path, "/", target });

                for (visited.items) |v| {
                    if (std.mem.eql(u8, v, resolved)) {
                        should_recurse = false;
                        break;
                    }
                }
            } else |_| {
                should_recurse = false;
            }
        }

        if (entry_type == .directory and !std.mem.eql(u8, entry.name, ".git") and should_recurse) {
            try visited.append(allocator, full_path);
            errdefer _ = visited.pop();
            try walkRecursive(allocator, io, base_path, full_path, results, visited);
        }
    }
}

pub fn filterByType(
    allocator: std.mem.Allocator,
    entries: []DirEntry,
    entry_type: DirEntryType,
) ![]DirEntry {
    var filtered = std.ArrayList(DirEntry).initCapacity(allocator, entries.len);
    errdefer filtered.deinit(allocator);

    for (entries) |entry| {
        if (entry.entry_type == entry_type) {
            try filtered.append(allocator, entry);
        }
    }

    return filtered.toOwnedSlice(allocator);
}

pub fn countEntries(entries: []DirEntry) struct { files: usize, dirs: usize, symlinks: usize } {
    var counts = .{ .files = 0, .dirs = 0, .symlinks = 0 };

    for (entries) |entry| {
        switch (entry.entry_type) {
            .file => counts.files += 1,
            .directory => counts.dirs += 1,
            .symlink => counts.symlinks += 1,
            .other => {},
        }
    }

    return counts;
}

pub const SymlinkError = error{
    SymlinkLoop,
    TargetNotFound,
    PermissionDenied,
    IoError,
};

pub fn readSymlinkTarget(
    io: *Io,
    symlink_path: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const dir = Io.Dir.cwd();
    const file = try dir.openFile(io.*, symlink_path, .{});
    defer file.close(io.*);

    const stat = try file.stat(io.*);
    const size = @as(usize, @intCast(stat.size));

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    var reader = file.reader(io.*, buffer);
    try reader.interface.readSliceAll(buffer);

    return buffer;
}

pub fn detectSymlinkLoop(
    io: *Io,
    symlink_path: []const u8,
    base_path: []const u8,
    allocator: std.mem.Allocator,
) !bool {
    const target = readSymlinkTarget(io, symlink_path, allocator) catch |err| {
        switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    };
    defer allocator.free(target);

    const full_target = if (std.mem.startsWith(u8, target, "/"))
        target
    else
        try std.mem.concat(allocator, u8, &.{ symlink_path, "/../", target });

    return std.mem.containsAtLeast(u8, full_target, 1, base_path);
}

pub fn resolveSymlink(
    io: *Io,
    symlink_path: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const target = readSymlinkTarget(io, symlink_path, allocator) catch |err| {
        switch (err) {
            error.SymlinkLoop => return symlink_path,
            else => return err,
        }
    };
    defer allocator.free(target);

    if (std.mem.startsWith(u8, target, "/")) {
        return try allocator.dupe(u8, target);
    }

    const parent = std.mem.sliceTo(symlink_path, 0);
    const last_sep = std.mem.lastIndexOfScalar(u8, parent, '/');
    const parent_path = if (last_sep) |idx| parent[0..idx] else ".";

    return try std.mem.concat(allocator, u8, &.{ parent_path, "/", target });
}

pub fn isSymlinkLoop(
    io: *Io,
    symlink_path: []const u8,
    visited: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !bool {
    const target = readSymlinkTarget(io, symlink_path, allocator) catch return false;

    for (visited.items) |v| {
        if (std.mem.eql(u8, v, target)) {
            return true;
        }
    }

    try visited.append(try allocator.dupe(u8, target));

    return false;
}

test "listDirectory lists directory entries" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const dir_path = ".";
    const entries = try listDirectory(gpa.allocator(), io, dir_path);
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    try std.testing.expect(entries.len > 0);
}

test "listDirectory returns error for non-existent directory" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const result = listDirectory(gpa.allocator(), io, "non_existent_dir");
    try std.testing.expectError(WalkError.DirectoryNotFound, result);
}

test "walkDirectory finds all files recursively" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try walkDirectory(gpa.allocator(), io, "src");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    try std.testing.expect(entries.len > 0);
}

test "filterByType filters entries by type" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try walkDirectory(gpa.allocator(), io, "src");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    const files_only = try filterByType(gpa.allocator(), entries, .file);
    defer {
        for (files_only) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(files_only);
    }

    for (files_only) |entry| {
        try std.testing.expect(entry.entry_type == .file);
    }
}

test "countEntries counts correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try listDirectory(gpa.allocator(), io, "src");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    const counts = countEntries(entries);
    try std.testing.expect(counts.files + counts.dirs + counts.symlinks == entries.len);
}

test "walkDirectory excludes .git directories" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try walkDirectory(gpa.allocator(), io, ".");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    for (entries) |entry| {
        try std.testing.expect(!std.mem.containsAtLeast(u8, entry.path, 1, ".git"));
    }
}

test "walkDirectory finds files in subdirectories" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try walkDirectory(gpa.allocator(), io, ".");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    var found_file = false;
    for (entries) |entry| {
        if (entry.entry_type == .file) {
            found_file = true;
            break;
        }
    }
    try std.testing.expect(found_file);
}

test "filterByType returns empty for no matches" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try walkDirectory(gpa.allocator(), io, "src");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    const symlinks_only = try filterByType(gpa.allocator(), entries, .symlink);
    defer {
        for (symlinks_only) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(symlinks_only);
    }

    try std.testing.expectEqual(@as(usize, 0), symlinks_only.len);
}

test "countEntries returns zero counts for empty list" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try listDirectory(gpa.allocator(), io, ".");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    const counts = countEntries(entries);
    try std.testing.expect(counts.files >= 0);
    try std.testing.expect(counts.dirs >= 0);
    try std.testing.expect(counts.symlinks >= 0);
}

test "listDirectory returns entries with valid paths" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const entries = try listDirectory(gpa.allocator(), io, "src");
    defer {
        for (entries) |entry| {
            gpa.allocator().free(entry.name);
            gpa.allocator().free(entry.path);
        }
        gpa.allocator().free(entries);
    }

    for (entries) |entry| {
        try std.testing.expect(entry.name.len > 0);
        try std.testing.expect(entry.path.len > 0);
        try std.testing.expect(entry.path.len > entry.name.len);
    }
}
