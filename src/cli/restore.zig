//! Git Restore - Restore working tree files
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const RestoreStaged = @import("../reset/restore_staged.zig").RestoreStaged;
const RestoreWorking = @import("../reset/restore_working.zig").RestoreWorking;
const OID = @import("../object/oid.zig").OID;

pub const RestoreAction = enum {
    working,
    staged,
    source,
};

pub const Restore = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: RestoreAction,
    source: ?[]const u8,
    paths: []const []const u8,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Restore {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .working,
            .source = null,
            .paths = &.{},
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Restore) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .working => try self.runRestoreWorking(git_dir),
            .staged => try self.runRestoreStaged(git_dir),
            .source => try self.runRestoreFromSource(git_dir),
        }
    }

    fn runRestoreWorking(self: *Restore, git_dir: Io.Dir) !void {
        var restore = RestoreWorking.init(self.allocator, self.io, git_dir);

        if (self.paths.len > 0) {
            try restore.restore(self.paths);
            try self.output.successMessage("Restored working tree files", .{});
        } else {
            try self.output.errorMessage("No paths specified for restore", .{});
        }
    }

    fn runRestoreStaged(self: *Restore, git_dir: Io.Dir) !void {
        var restore = RestoreStaged.init(self.allocator, self.io, git_dir);

        const source = self.source orelse "HEAD";

        if (self.paths.len > 0) {
            try restore.restore(self.paths, source);
            try self.output.successMessage("Restored staged files from {s}", .{source});
        } else {
            try restore.restoreAll(source);
            try self.output.successMessage("Restored all staged files from {s}", .{source});
        }
    }

    fn runRestoreFromSource(self: *Restore, git_dir: Io.Dir) !void {
        var restore = RestoreWorking.init(self.allocator, self.io, git_dir);

        const source = self.source orelse {
            try self.output.errorMessage("Source required for --source restore", .{});
            return;
        };

        if (self.paths.len > 0) {
            try restore.restoreFromSource(self.paths, source);
            try self.output.successMessage("Restored files from {s}", .{source});
        } else {
            try self.output.errorMessage("No paths specified for restore", .{});
        }
    }
};

test "Restore init" {
    const io = std.Io.Threaded.new(.{}).?;
    const restore = Restore.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(restore.action == .working);
    try std.testing.expect(restore.source == null);
}
