//! Submodule - Git submodule support for diff operations
//!
//! This module provides submodule diff support for displaying submodule changes
//! in diff output.

const std = @import("std");
const Io = std.Io;

pub const SubmoduleError = error{
    NotASubmodule,
    SubmoduleNotFound,
    IoError,
};

pub const SubmoduleDiff = struct {
    name: []const u8,
    path: []const u8,
    old_oid: []const u8,
    new_oid: []const u8,
    commit_message: ?[]const u8 = null,
};

pub const SubmoduleDiffFormat = enum {
    short,
    long,
    log,
};

pub fn diffSubmodule(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_oid: []const u8,
    new_oid: []const u8,
    format: SubmoduleDiffFormat,
) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const display_path = if (path.len > 0) path else "submodule";

    switch (format) {
        .short => {
            try buf.writer().print("Submodule {s}: {s}\n", .{ display_path, old_oid });
            try buf.writer().print("Submodule {s}: {s}", .{ display_path, new_oid });
        },
        .long => {
            try buf.writer().print("Submodule {s} commit {s} ({s})\n", .{ display_path, old_oid, "old" });
            try buf.writer().print("Submodule {s} commit {s} ({s})", .{ display_path, new_oid, "new" });
        },
        .log => {
            try buf.writer().print("Submodule {s} {s}\n", .{ display_path, old_oid });
            try buf.writer().print("Submodule {s} {s}\n", .{ display_path, new_oid });
        },
    }

    return buf.toOwnedSlice();
}

pub fn hasSubmoduleChanges(
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
) !bool {
    const cwd = Io.Dir.cwd();
    defer cwd.close();
    const modules_content = cwd.readFileAlloc(io, ".gitmodules", allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(modules_content);

    var it = std.mem.splitScalar(u8, modules_content, '\n');

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        if (std.mem.startsWith(u8, trimmed, "[submodule ")) {
            const name_start = "[submodule ".len;
            const end = std.mem.indexOf(u8, trimmed[name_start..], "]") orelse continue;
            const submodule_name = trimmed[name_start .. name_start + end];
            _ = submodule_name;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "path")) {
            const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
            const sub_path = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\r");

            if (path.len > 0 and !std.mem.eql(u8, sub_path, path)) {
                continue;
            }

            const sub_status = try getSubmoduleStatus(allocator, io, sub_path);
            if (sub_status.has_modified or sub_status.has_untracked or sub_status.has_staged) return true;
        }
    }
    return false;
}

pub fn getSubmoduleStatus(
    allocator: std.mem.Allocator,
    io: *Io,
    path: []const u8,
) !SubmoduleStatus {
    var status = SubmoduleStatus{
        .is_initialized = false,
        .has_untracked = false,
        .has_modified = false,
        .has_staged = false,
    };

    const sub_dir = Io.Dir.cwd().openDir(io, path) catch return status;
    defer sub_dir.close();

    const git_dir = sub_dir.openDir(io, ".git") catch return status;
    defer git_dir.close();
    status.is_initialized = true;

    const head_content = git_dir.readFileAlloc(io, "HEAD", allocator, .limited(256)) catch return status;
    defer allocator.free(head_content);
    const head_trimmed = std.mem.trim(u8, head_content, " \n\r");

    if (!std.mem.startsWith(u8, head_trimmed, "ref: refs/heads/")) return status;
    const branch_ref = head_trimmed["ref: ".len..];
    const ref_file = branch_ref;
    const head_oid = git_dir.readFileAlloc(io, ref_file, allocator, .limited(64)) catch return status;
    defer allocator.free(head_oid);
    _ = std.mem.trim(u8, head_oid, " \n\r");

    const index_data = git_dir.readFileAlloc(io, "index", allocator, .limited(1024 * 1024)) catch return status;
    defer allocator.free(index_data);

    if (index_data.len >= 12 and std.mem.eql(u8, index_data[0..4], "DIRC")) {
        const entry_count = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(index_data.ptr + 8)), .big);
        if (entry_count > 0) {
            status.has_staged = true;
        }
    }

    const sub_dir_work = Io.Dir.cwd().openDir(io, path) catch return status;
    defer sub_dir_work.close();

    var work_walker = sub_dir_work.walkDirAlloc(allocator, .{ .recursive = true }) catch return status;
    defer work_walker.deinit();

    while (work_walker.next() catch return status) |entry| {
            if (entry.kind == .file) {
                status.has_untracked = true;
                break;
            }
        }

    return status;
}

pub const SubmoduleStatus = struct {
    is_initialized: bool,
    has_untracked: bool,
    has_modified: bool,
    has_staged: bool,
};

test "SubmoduleStatus structure" {
    const status = SubmoduleStatus{
        .is_initialized = true,
        .has_untracked = false,
        .has_modified = true,
        .has_staged = false,
    };
    try std.testing.expect(status.is_initialized == true);
    try std.testing.expect(status.has_modified == true);
}
