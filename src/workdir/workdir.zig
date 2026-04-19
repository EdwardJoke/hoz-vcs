//! WorkDir - Working directory module for Hoz VCS
//!
//! This is the main entry point for the workdir module, providing a unified
//! interface to working directory operations.

const std = @import("std");
const Io = std.Io;

pub const file = @import("file.zig");
pub const dirent = @import("dirent.zig");
pub const status = @import("status.zig");
pub const scanner = @import("scanner.zig");
pub const ignore = @import("ignore.zig");
pub const sparse = @import("sparse.zig");

pub const WorkDirError = error{
    NotARepository,
    DirectoryNotFound,
    PermissionDenied,
    IoError,
};

pub const RepositoryLayout = struct {
    git_dir: []const u8,
    working_dir: []const u8,
    work_tree: []const u8,
};

pub fn findRepositoryRoot(
    allocator: std.mem.Allocator,
    io: *Io,
    start_path: []const u8,
) !RepositoryLayout {
    const dir = Io.Dir.cwd();
    var current_path: []u8 = try allocator.dupe(u8, start_path);
    defer allocator.free(current_path);

    while (current_path.len > 0) {
        const git_path = try std.mem.concat(allocator, u8, &.{ current_path, "/.git" });
        defer allocator.free(git_path);

        const git_dir = dir.openDir(io, git_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    const parent = std.fs.path.dirname(current_path);
                    if (parent == null) {
                        return WorkDirError.NotARepository;
                    }
                    current_path = @constCast(parent.?);
                    continue;
                },
                else => return WorkDirError.IoError,
            }
        };
        git_dir.close(io);

        return .{
            .git_dir = try allocator.dupe(u8, git_path),
            .working_dir = try allocator.dupe(u8, current_path),
            .work_tree = try allocator.dupe(u8, current_path),
        };
    }

    return WorkDirError.NotARepository;
}

test "findRepositoryRoot finds .git directory" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    const result = findRepositoryRoot(gpa.allocator(), io, ".");
    if (result) |repo| {
        try std.testing.expectEqualStrings(".git", repo.git_dir);
        try std.testing.expectEqualStrings(".", repo.working_dir);
    }
}

test "findRepositoryRoot returns error for non-repo" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    const result = findRepositoryRoot(gpa.allocator(), io, "/tmp");
    try std.testing.expectError(WorkDirError.NotARepository, result);
}
