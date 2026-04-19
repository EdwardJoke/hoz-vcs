//! StatusScanner - Git-style status scanning for Hoz VCS
//!
//! This module provides comprehensive status scanning for the working directory,
//! including porcelain output and detailed status information.

const std = @import("std");
const Io = std.Io;
const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const status_mod = @import("status.zig");
const dirent_mod = @import("dirent.zig");

pub const StatusOptions = struct {
    show_ignored: bool = false,
    show_untracked: bool = true,
    porcelain: bool = false,
    verbose: bool = false,
};

pub const StatusScanner = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    root_path: []const u8,
    index: ?Index,
    options: StatusOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *Io,
        root_path: []const u8,
        options: StatusOptions,
    ) StatusScanner {
        return .{
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .index = null,
            .options = options,
        };
    }

    pub fn deinit(self: *StatusScanner) void {
        if (self.index) |*idx| {
            idx.deinit();
        }
        self.* = undefined;
    }

    pub fn loadIndex(self: *StatusScanner) !void {
        const index_path = try std.mem.concat(self.allocator, u8, &.{ self.root_path, "/.git/index" });
        defer self.allocator.free(index_path);

        self.index = Index.read(self.allocator, index_path) catch null;
    }

    pub fn scan(self: *StatusScanner) !status_mod.StatusResult {
        var all_statuses = std.ArrayList(status_mod.WorkDirStatus).init(self.allocator);
        errdefer all_statuses.deinit();

        if (self.index) |idx| {
            for (idx.entries.items, idx.entry_names.items) |entry, name| {
                const status = try status_mod.detectStatus(self.io, name, entry);
                try all_statuses.append(.{
                    .path = try self.allocator.dupe(u8, name),
                    .status = status,
                    .index_entry = entry,
                });
            }
        }

        if (self.options.show_untracked) {
            const entries = try dirent_mod.walkDirectory(self.allocator, self.io, self.root_path);
            defer {
                for (entries) |entry| {
                    self.allocator.free(entry.name);
                    self.allocator.free(entry.path);
                }
                self.allocator.free(entries);
            }

            const tracked_names = if (self.index) |idx| try self.getTrackedNames(idx) else &.{};

            for (entries) |entry| {
                if (entry.entry_type == .file) {
                    const is_tracked = for (tracked_names) |name| {
                        if (std.mem.eql(u8, entry.name, name)) break true;
                    } else false;

                    if (!is_tracked) {
                        try all_statuses.append(.{
                            .path = try self.allocator.dupe(u8, entry.name),
                            .status = .untracked,
                            .index_entry = null,
                        });
                    }
                }
            }
        }

        var has_changes = false;
        for (all_statuses.items) |s| {
            if (s.status != .unmodified) {
                has_changes = true;
                break;
            }
        }

        return .{
            .entries = try all_statuses.toOwnedSlice(),
            .has_changes = has_changes,
        };
    }

    fn getTrackedNames(self: *StatusScanner, idx: Index) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(self.allocator);
        errdefer names.deinit();

        for (idx.entry_names.items) |name| {
            try names.append(name);
        }

        return try names.toOwnedSlice();
    }

    pub fn formatPorcelain(self: *StatusScanner, result: status_mod.StatusResult) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        for (result.entries) |entry| {
            const index_status = if (entry.index_entry != null)
                status_mod.shortStatusChar(entry.status)
            else
                '?';

            const worktree_status: u8 = if (entry.status == .untracked) '?' else ' ';

            try buf.writer().print("{c}{c} {s}\n", .{
                index_status,
                worktree_status,
                entry.path,
            });
        }

        return try buf.toOwnedSlice();
    }

    pub fn formatLong(self: *StatusScanner, result: status_mod.StatusResult) ![]u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.writer().print("Changes not staged for commit:\n", .{});
        try buf.writer().print("  (use \"hoz add <file>...\" to update what will be committed)\n\n", .{});

        for (result.entries) |entry| {
            try buf.writer().print("  {s} {s}\n", .{
                status_mod.formatStatus(entry.status),
                entry.path,
            });
        }

        return try buf.toOwnedSlice();
    }
};

pub fn createScanner(
    allocator: std.mem.Allocator,
    io: *Io,
    root_path: []const u8,
    options: StatusOptions,
) StatusScanner {
    return StatusScanner.init(allocator, io, root_path, options);
}

test "StatusScanner initializes correctly" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const scanner = createScanner(gpa.allocator(), io, ".", .{});
    try std.testing.expect(scanner.root_path.len > 0);
}

test "StatusOptions default values" {
    const options: StatusOptions = .{};
    try std.testing.expect(!options.show_ignored);
    try std.testing.expect(options.show_untracked);
    try std.testing.expect(!options.porcelain);
    try std.testing.expect(!options.verbose);
}

test "createScanner creates scanner with correct parameters" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const scanner = createScanner(gpa.allocator(), io, "/tmp/test", .{});
    try std.testing.expectEqualStrings("/tmp/test", scanner.root_path);
}

test "StatusScanner has correct default options" {
    const gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var io_instance: Io.Threaded = .init_single_threaded;
    const io = io_instance.io();

    const scanner = createScanner(gpa.allocator(), io, ".", .{});
    try std.testing.expect(scanner.options.show_untracked);
    try std.testing.expect(!scanner.options.show_ignored);
    try std.testing.expect(!scanner.options.porcelain);
    try std.testing.expect(!scanner.options.verbose);
}

test "StatusOptions can be customized" {
    const options: StatusOptions = .{
        .show_ignored = true,
        .show_untracked = false,
        .porcelain = true,
        .verbose = true,
    };
    try std.testing.expect(options.show_ignored);
    try std.testing.expect(!options.show_untracked);
    try std.testing.expect(options.porcelain);
    try std.testing.expect(options.verbose);
}
