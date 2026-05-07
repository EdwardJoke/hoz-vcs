//! Rebase Abort - Abort rebase operations
const std = @import("std");
const Io = std.Io;

pub const AbortResult = struct {
    success: bool,
    branch_restored: bool,
};

pub const RebaseAborter = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) RebaseAborter {
        return .{ .allocator = allocator, .io = io, .git_dir = ".git" };
    }

    pub fn abort(self: *RebaseAborter) !AbortResult {
        var branch_restored = false;

        const orig_head = self.readOrigHead() catch null;
        const head_name = self.readHeadName() catch null;

        if (orig_head) |oid_hex| {
            if (head_name) |ref_path| {
                self.restoreRef(ref_path, oid_hex) catch {};
                branch_restored = true;
            }
            self.allocator.free(oid_hex);
        }
        if (head_name) |name| self.allocator.free(name);

        const cwd = Io.Dir.cwd();
        cwd.deleteFile(self.io, "rebase-merge/head-name") catch {};
        cwd.deleteFile(self.io, "rebase-merge/orig-head") catch {};
        cwd.deleteFile(self.io, "rebase-merge/current") catch {};
        cwd.deleteFile(self.io, "rebase-merge/todo") catch {};
        cwd.deleteFile(self.io, "rebase-merge/done") catch {};
        cwd.deleteFile(self.io, "rebase-merge/onto") catch {};
        cwd.deleteFile(self.io, "rebase-merge/msg") catch {};
        cwd.deleteFile(self.io, "rebase-merge/quiet") catch {};

        return AbortResult{ .success = true, .branch_restored = branch_restored };
    }

    pub fn canAbort(self: *RebaseAborter) bool {
        const cwd = Io.Dir.cwd();
        _ = cwd.statFile(self.io, "rebase-merge/head-name", .{}) catch return false;
        return true;
    }

    fn readOrigHead(self: *RebaseAborter) !?[]const u8 {
        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, "rebase-merge/orig-head", self.allocator, .limited(256)) catch return null;
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        if (trimmed.len == 0) {
            self.allocator.free(content);
            return null;
        }
        const result = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(content);
        return result;
    }

    fn readHeadName(self: *RebaseAborter) !?[]const u8 {
        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, "rebase-merge/head-name", self.allocator, .limited(256)) catch return null;
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        if (trimmed.len == 0) {
            self.allocator.free(content);
            return null;
        }
        const result = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(content);
        return result;
    }

    fn restoreRef(self: *RebaseAborter, ref_path: []const u8, oid_hex: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const full_path = try std.mem.concat(self.allocator, u8, &.{ self.git_dir, "/", ref_path });
        defer self.allocator.free(full_path);

        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_hex});
        defer self.allocator.free(content);

        cwd.writeFile(self.io, .{ .sub_path = full_path, .data = content }) catch return;
    }
};

test "AbortResult structure" {
    const result = AbortResult{ .success = true, .branch_restored = true };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.branch_restored == true);
}

test "RebaseAborter init" {
    const aborter = RebaseAborter.init(std.testing.allocator, undefined);
    try std.testing.expect(aborter.allocator == std.testing.allocator);
}
