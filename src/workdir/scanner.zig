//! StatusScanner - Git-style status scanning for Hoz VCS
//!
//! This module provides comprehensive status scanning for the working directory,
//! including porcelain output and detailed status information.

const std = @import("std");
const Io = std.Io;
const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const status_mod = @import("status.zig");
const ignore_mod = @import("ignore.zig");
const dirent_mod = @import("dirent.zig");

pub const StatusOptions = struct {
    show_untracked: bool = true,
    show_ignored: bool = false,
    show_untracked_all: bool = false,
    porcelain: bool = false,
    verbose: bool = false,
};

pub const StatusScanner = struct {
    allocator: std.mem.Allocator,
    io: *Io,
    root_path: []const u8,
    cwd: []const u8,
    index: ?Index,
    options: StatusOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        io: *Io,
        root_path: []const u8,
        cwd: []const u8,
        options: StatusOptions,
    ) StatusScanner {
        return .{
            .allocator = allocator,
            .io = io,
            .root_path = root_path,
            .cwd = cwd,
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

    pub fn loadIndex(self: *StatusScanner) void {
        const index_path = std.mem.concat(self.allocator, u8, &.{ self.root_path, "/.git/index" }) catch return;
        defer self.allocator.free(index_path);

        self.index = Index.read(self.allocator, self.io.*, index_path) catch null;
    }

    pub fn scan(self: *StatusScanner) !status_mod.StatusResult {
        var all_statuses = std.ArrayList(status_mod.WorkDirStatus).empty;
        errdefer all_statuses.deinit(self.allocator);

        if (self.index) |idx| {
            for (idx.entries.items, idx.entry_names.items) |entry, name| {
                const status = try status_mod.detectStatus(self.io, name, entry);
                try all_statuses.append(self.allocator, .{
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
            const gitignore_path = try std.mem.concat(self.allocator, u8, &.{ self.root_path, "/.gitignore" });
            defer self.allocator.free(gitignore_path);
            const patterns = try ignore_mod.loadGitIgnore(self.allocator, self.io, gitignore_path);
            defer self.allocator.free(patterns);

            for (entries) |entry| {
                if (entry.entry_type == .file) {
                    const is_tracked = for (tracked_names) |name| {
                        if (std.mem.eql(u8, entry.name, name)) break true;
                    } else false;

                    if (!is_tracked) {
                        const is_dir = entry.entry_type == .directory;
                        const ignored = ignore_mod.isIgnored(patterns, entry.name, is_dir);
                        if (ignored and !self.options.show_ignored) {
                            try all_statuses.append(self.allocator, .{
                                .path = try self.allocator.dupe(u8, entry.name),
                                .status = .ignored,
                                .index_entry = null,
                            });
                        } else if (!ignored or self.options.show_ignored) {
                            try all_statuses.append(self.allocator, .{
                                .path = try self.allocator.dupe(u8, entry.name),
                                .status = .untracked,
                                .index_entry = null,
                            });
                        }
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
            .entries = try all_statuses.toOwnedSlice(self.allocator),
            .has_changes = has_changes,
        };
    }

    fn getTrackedNames(self: *StatusScanner, idx: Index) ![][]const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(self.allocator);

        for (idx.entry_names.items) |name| {
            try names.append(self.allocator, name);
        }

        return try names.toOwnedSlice(self.allocator);
    }

    pub fn formatPorcelain(self: *StatusScanner, result: status_mod.StatusResult) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        for (result.entries) |entry| {
            const index_status = if (entry.index_entry != null)
                status_mod.shortStatusChar(entry.status)
            else
                '?';

            const worktree_status: u8 = if (entry.status == .untracked) '?' else ' ';

            try buf.print(self.allocator, "{c}{c} {s}\n", .{
                index_status,
                worktree_status,
                entry.path,
            });
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    pub fn formatLong(self: *StatusScanner, result: status_mod.StatusResult) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        // Function to get relative path from current directory
        const getRelativePath = struct {
            fn apply(allocator: std.mem.Allocator, root_path: []const u8, cwd: []const u8, full_path: []const u8) ![]u8 {
                if (std.mem.startsWith(u8, full_path, root_path)) {
                    const relative = full_path[root_path.len..];
                    if (std.mem.startsWith(u8, relative, "/")) {
                        return try std.mem.concat(allocator, u8, &.{ cwd, relative });
                    }
                    return try std.mem.concat(allocator, u8, &.{ cwd, "/", relative });
                }
                return try allocator.dupe(u8, full_path);
            }
        }.apply;

        _ = getRelativePath;

        const branch_name = self.getBranchName();
        if (branch_name) |name| {
            try buf.print(self.allocator, "On branch {s}\n\n", .{name});
            self.allocator.free(name);
        } else {
            try buf.print(self.allocator, "On detached HEAD\n\n", .{});
        }

        var staged = std.ArrayList(status_mod.WorkDirStatus).empty;
        defer staged.deinit(self.allocator);
        var unstaged = std.ArrayList(status_mod.WorkDirStatus).empty;
        defer unstaged.deinit(self.allocator);
        var untracked = std.ArrayList(status_mod.WorkDirStatus).empty;
        defer untracked.deinit(self.allocator);

        for (result.entries) |entry| {
            switch (entry.status) {
                .added, .modified, .deleted, .renamed, .copied => {
                    if (entry.index_entry != null) {
                        try staged.append(self.allocator, entry);
                    } else {
                        try unstaged.append(self.allocator, entry);
                    }
                },
                .untracked => try untracked.append(self.allocator, entry),
                .ignored, .conflicted, .unmodified => {},
            }
        }

        if (staged.items.len > 0) {
            try buf.print(self.allocator, "Changes to be committed:\n", .{});
            try buf.print(self.allocator, "  (use \"hoz restore --staged <file>...\" to unstage)\n\n", .{});
            for (staged.items) |entry| {
                const relative_path = try std.fs.path.relative(self.allocator, self.cwd, null, self.cwd, entry.path);
                defer self.allocator.free(relative_path);
                try buf.print(self.allocator, "  {s} {s}\n", .{
                    status_mod.formatStatus(entry.status),
                    relative_path,
                });
            }
            try buf.print(self.allocator, "\n", .{});
        }

        if (unstaged.items.len > 0) {
            try buf.print(self.allocator, "Changes not staged for commit:\n", .{});
            try buf.print(self.allocator, "  (use \"hoz add <file>...\" to update what will be committed)\n\n", .{});
            for (unstaged.items) |entry| {
                const relative_path = try std.fs.path.relative(self.allocator, self.cwd, null, self.cwd, entry.path);
                defer self.allocator.free(relative_path);
                try buf.print(self.allocator, "  {s} {s}\n", .{
                    status_mod.formatStatus(entry.status),
                    relative_path,
                });
            }
            try buf.print(self.allocator, "\n", .{});
        }

        if (untracked.items.len > 0) {
            try buf.print(self.allocator, "Untracked files:\n", .{});
            try buf.print(self.allocator, "  (use \"hoz add <file>...\" to include in what will be committed)\n\n", .{});
            for (untracked.items) |entry| {
                const relative_path = try std.fs.path.relative(self.allocator, self.cwd, null, self.cwd, entry.path);
                defer self.allocator.free(relative_path);
                try buf.print(self.allocator, "  {s} {s}\n", .{
                    status_mod.formatStatus(entry.status),
                    relative_path,
                });
            }
            try buf.print(self.allocator, "\n", .{});
        }

        if (!result.has_changes and result.entries.len == 0) {
            try buf.print(self.allocator, "nothing to commit, working tree clean\n", .{});
        } else if (staged.items.len == 0 and unstaged.items.len == 0 and untracked.items.len == 0) {
            try buf.print(self.allocator, "nothing to commit, working tree clean\n", .{});
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    fn getBranchName(self: *StatusScanner) ?[]const u8 {
        const head_path = std.mem.concat(self.allocator, u8, &.{ self.root_path, "/.git/HEAD" }) catch return null;
        defer self.allocator.free(head_path);

        const dir = Io.Dir.cwd();
        const head_file = dir.openFile(self.io.*, head_path, .{}) catch return null;
        defer head_file.close(self.io.*);

        var content: [256]u8 = undefined;
        var file_reader = head_file.reader(self.io.*, &content);
        file_reader.interface.readSliceAll(&content) catch return null;
        const head_content = std.mem.trim(u8, &content, "\x00");
        if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
            const branch = head_content["ref: refs/heads/".len..];
            const trimmed = std.mem.trim(u8, branch, " \n\r");
            return self.allocator.dupe(u8, trimmed) catch return null;
        }

        return null;
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
