const std = @import("std");
const Io = std.Io;
const compress_mod = @import("../compress/zlib.zig");

pub const BisectRun = struct {
    allocator: std.mem.Allocator,
    io: Io,
    test_command: []const []const u8,
    exit_code: i32,
    git_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) BisectRun {
        return .{
            .allocator = allocator,
            .io = io,
            .test_command = &.{},
            .exit_code = 0,
            .git_path = ".git",
        };
    }

    pub fn run(self: *BisectRun, commit: []const u8) !i32 {
        _ = commit;
        if (self.test_command.len == 0) return self.exit_code;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return self.exit_code;
        defer git_dir.close(self.io);

        _ = git_dir.readFileAlloc(self.io, "bisect/bad", self.allocator, .limited(256)) catch return self.exit_code;

        self.exit_code = 0;
        return self.exit_code;
    }

    pub fn execute(self: *BisectRun, cmd: []const []const u8) !i32 {
        self.test_command = cmd;
        if (cmd.len == 0) return 0;

        var child = std.process.Child.init(cmd, self.allocator);
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const term = child.spawnAndWait() catch return 1;
        switch (term) {
            .Exited => |code| {
                self.exit_code = code;
                return code;
            },
            .Signal, .Stopped, .Unknown => {
                self.exit_code = 1;
                return 1;
            },
        }
    }

    pub fn setExitCode(self: *BisectRun, code: i32) void {
        self.exit_code = code;
    }

    pub fn getNextCommit(self: *BisectRun, current: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return "";
        defer git_dir.close(self.io);

        const bad_content = git_dir.readFileAlloc(self.io, "bisect/bad", self.allocator, .limited(256)) catch return "";
        defer self.allocator.free(bad_content);
        const bad_oid = std.mem.trim(u8, bad_content, " \t\r\n");

        const good_content = git_dir.readFileAlloc(self.io, "bisect/good", self.allocator, .limited(256)) catch return bad_oid;
        defer self.allocator.free(good_content);
        const good_oid = std.mem.trim(u8, good_content, " \t\r\n");

        if (std.mem.eql(u8, bad_oid, good_oid)) return "";

        const rev_list = try self.getRevList(bad_oid);
        defer {
            for (rev_list) |r| self.allocator.free(r);
            self.allocator.free(rev_list);
        }

        if (rev_list.len == 0) return "";

        var good_idx: usize = 0;
        for (rev_list, 0..) |r, i| {
            if (std.mem.eql(u8, r, good_oid)) {
                good_idx = i;
                break;
            }
        }

        const mid = (good_idx + 1) / 2;
        if (mid >= rev_list.len) return "";

        _ = current;
        return self.allocator.dupe(u8, rev_list[mid]) catch "";
    }

    fn getRevList(self: *BisectRun, start_oid: []const u8) ![]const []const u8 {
        var revs = std.ArrayList([]const u8).empty;
        errdefer {
            for (revs.items) |r| self.allocator.free(r);
            revs.deinit(self.allocator);
        }

        var visited = std.array_hash_map.String(void).empty;
        defer visited.deinit(self.allocator);

        var current = try self.allocator.dupe(u8, start_oid);
        errdefer self.allocator.free(current);

        var depth: u32 = 0;
        while (depth < 10000) : (depth += 1) {
            if (visited.contains(current)) break;
            visited.put(self.allocator, current, {}) catch break;

            const owned = try self.allocator.dupe(u8, current);
            try revs.append(self.allocator, owned);

            const parents = self.getParentOids(current) catch &.{};
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }

            if (parents.len == 0) break;
            self.allocator.free(current);
            current = try self.allocator.dupe(u8, parents[0]);
        }
        self.allocator.free(current);

        return revs.toOwnedSlice(self.allocator);
    }

    fn getParentOids(self: *BisectRun, oid_str: []const u8) ![][]const u8 {
        if (oid_str.len < 40) return error.InvalidOid;

        const cwd = Io.Dir.cwd();
        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_str[0..2], oid_str[2..40] });
        defer self.allocator.free(obj_path);

        const file = cwd.openFile(self.io, obj_path, .{}) catch return error.ObjectNotFound;
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        const compressed = try reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(compressed);

        const data = compress_mod.Zlib.decompress(compressed, self.allocator) catch return error.ObjectNotFound;
        defer self.allocator.free(data);

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, '\n');
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line["parent ".len..];
            if (parent_oid.len >= 40) {
                try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid[0..40]));
            }
        }

        return parents.toOwnedSlice(self.allocator);
    }
};

test "BisectRun init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectRun.init(std.testing.allocator, io);
    try std.testing.expect(bisect.exit_code == 0);
}

test "BisectRun setExitCode" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectRun.init(std.testing.allocator, io);
    bisect.setExitCode(1);
    try std.testing.expect(bisect.exit_code == 1);
}
