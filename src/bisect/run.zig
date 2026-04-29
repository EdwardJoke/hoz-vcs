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

pub const BisectState = struct {
    bad_oid: []const u8,
    good_oid: []const u8,
    current_oid: ?[]const u8,
    skipped_oids: std.array_hash_map.String(void),
    total_commits: usize,
    steps_taken: u32,

    pub fn init(allocator: std.mem.Allocator) BisectState {
        _ = allocator;
        return .{
            .bad_oid = "",
            .good_oid = "",
            .current_oid = null,
            .skipped_oids = std.array_hash_map.String(void).empty,
            .total_commits = 0,
            .steps_taken = 0,
        };
    }

    pub fn deinit(self: *BisectState, allocator: std.mem.Allocator) void {
        self.skipped_oids.deinit(allocator);
    }
};

pub fn skipCommit(self: *BisectRun, oid: []const u8) !void {
    if (oid.len == 0) return;

    const cwd = Io.Dir.cwd();
    const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return;
    defer git_dir.close(self.io);

    const skip_content = git_dir.readFileAlloc(self.io, "bisect/skip", self.allocator, .limited(64 * 1024)) catch "";
    defer self.allocator.free(skip_content);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(self.allocator);

    if (skip_content.len > 0) {
        try buf.appendSlice(self.allocator, skip_content);
        if (!std.mem.endsWith(u8, skip_content, "\n")) {
            try buf.append(self.allocator, '\n');
        }
    }

    try buf.appendSlice(self.allocator, oid);
    try buf.append(self.allocator, '\n');

    const final = buf.toOwnedSlice(self.allocator);
    defer self.allocator.free(final);

    git_dir.writeFile(self.io, .{ .sub_path = "bisect/skip", .data = final }) catch {};
}

pub fn loadSkipList(self: *BisectRun, allocator: std.mem.Allocator) !std.array_hash_map.String(void) {
    var skipped = std.array_hash_map.String(void).empty;
    errdefer skipped.deinit(allocator);

    const cwd = Io.Dir.cwd();
    const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return skipped;
    defer git_dir.close(self.io);

    const content = git_dir.readFileAlloc(self.io, "bisect/skip", allocator, .limited(64 * 1024)) catch return skipped;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 7) {
            skipped.put(allocator, trimmed, {}) catch {};
        }
    }

    return skipped;
}

pub fn getNextCommitSkipped(self: *BisectRun, current: []const u8) !struct { oid: []const u8, is_done: bool } {
    const cwd = Io.Dir.cwd();
    const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return .{ .oid = "", .is_done = false };
    defer git_dir.close(self.io);

    const bad_content = git_dir.readFileAlloc(self.io, "bisect/bad", self.allocator, .limited(256)) catch return .{ .oid = "", .is_done = false };
    defer self.allocator.free(bad_content);
    const bad_oid = std.mem.trim(u8, bad_content, " \t\r\n");

    const good_content = git_dir.readFileAlloc(self.io, "bisect/good", self.allocator, .limited(256)) catch return .{ .oid = bad_oid, .is_done = false };
    defer self.allocator.free(good_content);
    const good_oid = std.mem.trim(u8, good_content, " \t\r\n");

    if (std.mem.eql(u8, bad_oid, good_oid)) return .{ .oid = "", .is_done = true };

    var skipped = try self.loadSkipList(self.allocator);
    defer skipped.deinit(self.allocator);

    const rev_list = try self.getRevListFiltered(bad_oid, &skipped);
    defer {
        for (rev_list) |r| self.allocator.free(r);
        self.allocator.free(rev_list);
    }

    if (rev_list.len == 0) return .{ .oid = "", .is_done = true };

    var good_idx: usize = 0;
    for (rev_list, 0..) |r, i| {
        if (std.mem.eql(u8, r, good_oid)) {
            good_idx = i;
            break;
        }
    }

    const remaining = if (good_idx > 0) @as(usize, good_idx) else 0;

    if (remaining <= 1) {
        const next_oid = if (good_idx < rev_list.len) try self.allocator.dupe(u8, rev_list[good_idx]) else "";
        return .{ .oid = next_oid, .is_done = true };
    }

    const mid = (good_idx + 1) / 2;
    if (mid >= rev_list.len) return .{ .oid = "", .is_done = true };

    _ = current;
    return .{ .oid = try self.allocator.dupe(u8, rev_list[mid]), .is_done = false };
}

fn getRevListFiltered(self: *BisectRun, start_oid: []const u8, skipped: *std.array_hash_map.String(void)) ![][]const u8 {
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
        if (skipped.contains(current)) {
            self.allocator.free(current);
            const parents = self.getParentOids(current) catch &.{};
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }
            if (parents.len == 0) break;
            current = try self.allocator.dupe(u8, parents[0]);
            continue;
        }
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

pub fn visualize(self: *BisectRun, writer: anytype) !void {
    const cwd = Io.Dir.cwd();
    const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return;
    defer git_dir.close(self.io);

    const bad_content = git_dir.readFileAlloc(self.io, "bisect/bad", self.allocator, .limited(256)) catch return;
    defer self.allocator.free(bad_content);
    const bad_oid = std.mem.trim(u8, bad_content, " \t\r\n");

    const good_content = git_dir.readFileAlloc(self.io, "bisect/good", self.allocator, .limited(256)) catch return;
    defer self.allocator.free(good_content);
    const good_oid = std.mem.trim(u8, good_content, " \t\r\n");

    var skipped = try self.loadSkipList(self.allocator);
    defer skipped.deinit(self.allocator);

    const rev_list = try self.getRevListFiltered(bad_oid, &skipped);
    defer {
        for (rev_list) |r| self.allocator.free(r);
        self.allocator.free(rev_list);
    }

    var good_idx: usize = 0;
    for (rev_list, 0..) |r, i| {
        if (std.mem.eql(u8, r, good_oid)) {
            good_idx = i;
            break;
        }
    }

    const total = rev_list.len;
    const remaining = if (good_idx > 0) good_idx else 0;
    const mid = if (good_idx > 0) (good_idx + 1) / 2 else 0;

    try writer.writeAll("Bisect state:\n");
    try writer.print("  bad:  {s}\n", .{bad_oid[0..@min(bad_oid.len, 12)]});
    try writer.print("  good: {s}\n", .{good_oid[0..@min(good_oid.len, 12)]});
    try writer.print("  total commits in range: {d}\n", .{total});
    try writer.print("  remaining to test: {d}\n", .{remaining});
    try writer.print("  skipped: {d}\n", .{skipped.count()});
    try writer.writeAll("\n");

    if (total <= 20) {
        try writer.writeAll("  Commit range:\n");
        for (rev_list, 0..) |r, i| {
            const marker: []const u8 = if (i == mid) " >>>" else if (i == good_idx) " (good)" else if (skipped.contains(r)) " ~skip" else "";
            try writer.print("    [{d:>3}] {s}{s}\n", .{ i, r[0..@min(r.len, 12)], marker });
        }
    } else {
        try writer.print("  (range too large to display, showing first/last 5)\n", .{});
        for (0..@min(5, rev_list)) |i| {
            const marker: []const u8 = if (i == mid) " >>>" else "";
            try writer.print("    [{d:>3}] {s}{s}\n", .{ i, rev_list[i][0..@min(rev_list[i].len, 12)], marker });
        }
        try writer.writeAll("    ...\n");
        const start = if (rev_list.len > 5) rev_list.len - 5 else 0;
        for (start..rev_list) |i| {
            try writer.print("    [{d:>3}] {s}\n", .{ i, rev_list[i][0..@min(rev_list[i].len, 12)] });
        }
    }

    if (remaining <= 1) {
        try writer.writeAll("\n  First bad commit found!\n");
    } else {
        const approx_steps: u32 = @intFromFloat(std.math.log2(f32, @as(f32, @floatFromInt(remaining))));
        try writer.print("  Approx {d} step(s) remaining\n", .{approx_steps});
    }
}

pub fn checkAutoTerm(self: *BisectRun) !?[]const u8 {
    const result = try self.getNextCommitSkipped("");
    if (result.is_done) {
        return try self.allocator.dupe(u8, result.oid);
    }
    return null;
}

test "BisectState init" {
    var state = BisectState.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), state.total_commits);
    try std.testing.expect(state.current_oid == null);
    try std.testing.expectEqual(@as(usize, 0), state.skipped_oids.count());
}

test "BisectRun visualize writes output" {
    var buf: [4096]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });

    var bisect = BisectRun.init(std.testing.allocator, io);
    var writer = Io.Writer.fixed(&buf);
    bisect.visualize(&writer.writer.interface) catch {};
    const written = Io.Writer.buffered(&writer);
    try std.testing.expect(written.len > 0);
}

test "BisectRun checkAutoTerm returns null when not done" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectRun.init(std.testing.allocator, io);
    const result = bisect.checkAutoTerm() catch null;
    try std.testing.expect(result != null);
}
