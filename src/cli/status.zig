//! Git Status - Show working tree status
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const StatusIcon = @import("output.zig").StatusIcon;
const StatusScanner = @import("../workdir/scanner.zig").StatusScanner;
const status_mod = @import("../workdir/status.zig");
const head_mod = @import("../commit/head.zig");

pub const Status = struct {
    allocator: std.mem.Allocator,
    io: Io,
    porcelain: bool,
    short_format: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Status {
        return .{
            .allocator = allocator,
            .io = io,
            .porcelain = false,
            .short_format = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Status) !void {
        var scanner = StatusScanner.init(
            self.allocator,
            &self.io,
            ".",
            ".",
            .{ .show_untracked = true, .porcelain = self.porcelain },
        );
        defer scanner.deinit();

        scanner.loadIndex();
        const result = try scanner.scan();

        if (self.output.style.format == .toon) {
            try self.runToon(result);
        } else if (self.porcelain) {
            try self.runPorcelain(result);
        } else if (self.short_format) {
            try self.runShort(result);
        } else {
            try self.runLong(result);
        }

        for (result.entries) |entry| {
            self.allocator.free(entry.path);
        }
        self.allocator.free(result.entries);
    }

    fn runToon(self: *Status, result: status_mod.StatusResult) !void {
        try self.output.beginDocument();

        // Get current branch name
        const cwd_path = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd_path);
        const git_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{cwd_path});
        defer self.allocator.free(git_dir_path);

        const git_dir = Io.Dir.openDirAbsolute(self.io, git_dir_path, .{}) catch null;
        if (git_dir) |gd| {
            defer gd.close(self.io);
            const head_ref = head_mod.readHeadRef(&gd, self.io, self.allocator);
            defer if (head_ref) |hr| self.allocator.free(hr);
            if (head_ref) |hr| {
                const branch = if (std.mem.startsWith(u8, hr, "refs/heads/")) hr["refs/heads/".len..] else hr;
                try self.output.addKeyValue("branch", branch);
            }
        }

        // Categorize entries
        var staged_count: usize = 0;
        var unstaged_count: usize = 0;
        var untracked_count: usize = 0;

        for (result.entries) |entry| {
            switch (entry.status) {
                .unmodified, .ignored, .conflicted => staged_count += 1,
                .added, .modified, .deleted, .renamed, .copied => unstaged_count += 1,
                .untracked => untracked_count += 1,
            }
        }

        // Write staged array (unmodified/ignored/conflicted → includes staged changes)
        if (staged_count > 0) {
            try self.output.beginArray("staged");
            const keys = [_][]const u8{ "status", "path" };
            for (result.entries) |entry| {
                switch (entry.status) {
                    .unmodified, .ignored, .conflicted => {
                        const icon = statusToIcon(entry.status);
                        const vals = [_][]const u8{ icon.symbol(self.output.style.use_unicode), entry.path };
                        try self.output.addArrayObject(&keys, &vals);
                    },
                    else => {},
                }
            }
            try self.output.endArray();
        }

        // Write unstaged array
        if (unstaged_count > 0) {
            try self.output.beginArray("unstaged");
            const keys = [_][]const u8{ "status", "path" };
            for (result.entries) |entry| {
                switch (entry.status) {
                    .added, .modified, .deleted, .renamed, .copied => {
                        const icon = statusToIcon(entry.status);
                        const vals = [_][]const u8{ icon.symbol(self.output.style.use_unicode), entry.path };
                        try self.output.addArrayObject(&keys, &vals);
                    },
                    else => {},
                }
            }
            try self.output.endArray();
        }

        // Write untracked array
        if (untracked_count > 0) {
            try self.output.beginArray("untracked");
            const keys = [_][]const u8{ "path" };
            for (result.entries) |entry| {
                if (entry.status == .untracked) {
                    const vals = [_][]const u8{entry.path};
                    try self.output.addArrayObject(&keys, &vals);
                }
            }
            try self.output.endArray();
        }

        if (staged_count == 0 and unstaged_count == 0 and untracked_count == 0) {
            try self.output.addKeyValue("status", "clean");
        }

        try self.output.flush();
        self.output.deinit();
    }

    fn statusToIcon(status: status_mod.FileStatus) StatusIcon {
        return switch (status) {
            .unmodified => .unmodified,
            .modified => .modified,
            .added => .added,
            .deleted => .deleted,
            .renamed => .renamed,
            .copied => .copied,
            .untracked => .untracked,
            .ignored => .ignored,
            .conflicted => .conflicted,
        };
    }

    fn runPorcelain(self: *Status, result: status_mod.StatusResult) !void {
        for (result.entries) |entry| {
            const icon: StatusIcon = switch (entry.status) {
                .unmodified => .unmodified,
                .modified => .modified,
                .added => .added,
                .deleted => .deleted,
                .renamed => .renamed,
                .copied => .copied,
                .untracked => .untracked,
                .ignored => .ignored,
                .conflicted => .conflicted,
            };
            try self.output.statusItem(icon, false, entry.path);
        }
        if (!result.has_changes) {
            try self.output.result(.{ .success = true, .code = 0, .message = "Working tree clean" });
        }
    }

    fn runShort(self: *Status, result: status_mod.StatusResult) !void {
        try self.runPorcelain(result);
    }

    fn runLong(self: *Status, result: status_mod.StatusResult) !void {
        var staged: usize = 0;
        var unstaged: usize = 0;
        var untracked: usize = 0;

        for (result.entries) |entry| {
            switch (entry.status) {
                .added, .modified, .deleted, .renamed, .copied => unstaged += 1,
                .untracked => untracked += 1,
                else => staged += 1,
            }
        }

        try self.output.section("Status");

        if (unstaged > 0) {
            try self.output.groupHeader("Changes not staged for commit", unstaged);
            for (result.entries) |entry| {
                const icon: StatusIcon = switch (entry.status) {
                    .modified => .modified,
                    .added => .added,
                    .deleted => .deleted,
                    .renamed => .renamed,
                    .copied => .copied,
                    else => continue,
                };
                try self.output.treeNode(.branch, 1, "{s} {s}", .{
                    icon.symbol(self.output.style.use_unicode),
                    entry.path,
                });
            }
            try self.output.sectionDivider();
        }

        if (untracked > 0) {
            try self.output.groupHeader("Untracked files", untracked);
            for (result.entries) |entry| {
                if (entry.status == .untracked) {
                    try self.output.treeNode(.branch, 1, "? {s}", .{entry.path});
                }
            }
            try self.output.sectionDivider();
        }

        if (unstaged == 0 and untracked == 0) {
            try self.output.successMessage("Working tree clean", .{});
        }

        try self.output.hint("Run 'hoz add <file>' to stage changes", .{});
    }
};
