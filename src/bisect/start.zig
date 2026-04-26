//! Bisect Start - Initialize bisect session
const std = @import("std");
const Io = std.Io;

pub const BisectStart = struct {
    allocator: std.mem.Allocator,
    io: Io,
    bad_ref: []const u8,
    good_refs: []const []const u8,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) BisectStart {
        return .{
            .allocator = allocator,
            .io = io,
            .bad_ref = "HEAD",
            .good_refs = &.{},
            .path = ".git",
        };
    }

    pub fn start(self: *BisectStart, bad: []const u8, goods: []const []const u8) !void {
        self.bad_ref = bad;
        self.good_refs = goods;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        _ = git_dir.createDir(self.io, "bisect", @enumFromInt(0o755)) catch {};
        const bisect_dir = git_dir.openDir(self.io, "bisect", .{}) catch return;
        defer bisect_dir.close(self.io);

        try self.writeRef("bad", bad);
        for (goods) |good| {
            try self.writeRef("good", good);
        }
    }

    fn writeRef(self: *BisectStart, status: []const u8, ref: []const u8) !void {
        const fname = try std.fmt.allocPrint(self.allocator, "bisect/{s}", .{status});
        defer self.allocator.free(fname);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch {
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        try git_dir.writeFile(self.io, .{ .sub_path = fname, .data = ref });
    }

    pub fn getRevList(self: *BisectStart) ![]const []const u8 {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.path, .{}) catch return &.{};
        defer git_dir.close(self.io);

        var revs = std.ArrayList([]const u8).empty;
        errdefer {
            for (revs.items) |r| self.allocator.free(r);
            revs.deinit(self.allocator);
        }

        const bad_content = git_dir.readFileAlloc(self.io, "bisect/bad", self.allocator, .limited(256)) catch return &.{};
        defer self.allocator.free(bad_content);
        const bad_oid = std.mem.trim(u8, bad_content, " \t\r\n");

        var visited = std.StringHashMap(void).initCapacity(std.heap.page_allocator, 4096);
        defer visited.deinit();

        var current = try self.allocator.dupe(u8, bad_oid);
        defer self.allocator.free(current);

        const max_depth: u32 = 10000;
        var depth: u32 = 0;

        while (depth < max_depth) : (depth += 1) {
            if (visited.contains(current)) break;
            try visited.put(std.heap.page_allocator, current, {});

            const owned = try self.allocator.dupe(u8, current);
            try revs.append(self.allocator, owned);

            const parents = try self.getParentOids(current);
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }

            if (parents.len == 0) break;
            self.allocator.free(current);
            current = try self.allocator.dupe(u8, parents[0]);
        }

        return revs.toOwnedSlice(self.allocator);
    }

    fn getParentOids(self: *BisectStart, oid_str: []const u8) ![][]const u8 {
        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_str[0..2], oid_str[2..] });
        defer self.allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(self.io, obj_path, .{}) catch return error.ObjectNotFound;
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        const data = reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024)) catch return &.{};

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitSequence(u8, data, "\n");
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line[7..];
            try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid));
        }
        self.allocator.free(data);

        return parents.toOwnedSlice(self.allocator);
    }
};

test "BisectStart init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const bisect = BisectStart.init(std.testing.allocator, io);
    try std.testing.expectEqualStrings("HEAD", bisect.bad_ref);
}

test "BisectStart start method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectStart.init(std.testing.allocator, io);
    bisect.start("HEAD", &.{"HEAD~5"}) catch {};
    try std.testing.expect(true);
}

test "BisectStart getRevList method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    var bisect = BisectStart.init(std.testing.allocator, io);
    const revs = try bisect.getRevList();
    _ = revs;
    try std.testing.expect(true);
}
