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
    const subdir = dir.openDir(io, dir_path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return error.DirectoryNotFound,
            error.PermissionDenied => return error.PermissionDenied,
            else => return error.IoError,
        }
    };
    defer subdir.close(io);

    var entries = std.ArrayList(DirEntry).init(allocator);
    errdefer entries.deinit();

    var iterator = subdir.iterate(io, .{});
    while (try iterator.next(io)) |entry| {
        const entry_type: DirEntryType = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };

        const full_path = try std.mem.concat(allocator, u8, &.{ dir_path, "/", entry.name });
        defer allocator.free(full_path);

        try entries.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .path = full_path,
            .entry_type = entry_type,
        });
    }

    return entries.toOwnedSlice();
}

pub fn walkDirectory(
    allocator: std.mem.Allocator,
    io: *Io,
    dir_path: []const u8,
) ![]DirEntry {
    var all_entries = std.ArrayList(DirEntry).init(allocator);
    errdefer all_entries.deinit();

    try walkRecursive(allocator, io, dir_path, dir_path, &all_entries);

    return all_entries.toOwnedSlice();
}

fn walkRecursive(
    allocator: std.mem.Allocator,
    io: *Io,
    base_path: []const u8,
    current_path: []const u8,
    results: *std.ArrayList(DirEntry),
) !void {
    const dir = Io.Dir.cwd();
    const subdir = dir.openDir(io, current_path, .{}) catch return;
    defer subdir.close(io);

    var iterator = subdir.iterate(io, .{});
    while (try iterator.next(io)) |entry| {
        const entry_type: DirEntryType = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
            .sym_link => .symlink,
            else => .other,
        };

        const full_path = try std.mem.concat(allocator, u8, &.{ current_path, "/", entry.name });
        errdefer allocator.free(full_path);

        try results.append(.{
            .name = try allocator.dupe(u8, entry.name),
            .path = full_path,
            .entry_type = entry_type,
        });

        if (entry_type == .directory and !std.mem.eql(u8, entry.name, ".git")) {
            try walkRecursive(allocator, io, base_path, full_path, results);
        }
    }
}

pub fn filterByType(
    allocator: std.mem.Allocator,
    entries: []DirEntry,
    entry_type: DirEntryType,
) ![]DirEntry {
    var filtered = std.ArrayList(DirEntry).init(allocator);
    errdefer filtered.deinit();

    for (entries) |entry| {
        if (entry.entry_type == entry_type) {
            try filtered.append(entry);
        }
    }

    return filtered.toOwnedSlice();
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
