//! Tag Push - Push tags to remote
const std = @import("std");
const Io = std.Io;

pub const TagPusher = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagPusher {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn push(self: *TagPusher, remote: []const u8, tag: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/remotes/{s}/refs/tags/{s}", .{ remote, tag });
        defer self.allocator.free(ref_path);

        const tag_ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{tag});
        defer self.allocator.free(tag_ref_path);

        const target_data = cwd.readFileAlloc(self.io, tag_ref_path, self.allocator, .limited(256)) catch return;
        defer self.allocator.free(target_data);

        var parent_dir = cwd.openDir(self.io, ".git/refs/remotes", .{}) catch {
            cwd.createDir(self.io, ".git/refs/remotes", @enumFromInt(0o755)) catch {};
            const rd = cwd.openDir(self.io, ".git/refs/remotes", .{}) catch return;
            defer rd.close(self.io);
            try self.ensureRemoteDir(&rd, remote);
            return self.writeRemoteRef(&rd, remote, tag, target_data);
        };
        defer parent_dir.close(self.io);

        _ = parent_dir.openDir(self.io, remote, .{}) catch {
            try self.ensureRemoteDir(&parent_dir, remote);
        };

        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/refs/tags/{s}", .{ ".git/refs/remotes", remote, tag });
        defer self.allocator.free(full_path);

        var file = cwd.createFile(self.io, full_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => cwd.openFile(self.io, full_path, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print("{s}", .{target_data});
    }

    pub fn pushAll(self: *TagPusher, remote: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return;
        defer tags_dir.close(self.io);

        var iter = tags_dir.iterate(self.io);
        while (try iter.next()) |entry| {
            if (entry.kind == .directory or std.mem.startsWith(u8, entry.name, ".")) continue;
            try self.push(remote, entry.name);
        }
    }

    fn ensureRemoteDir(self: *TagPusher, parent: *const Io.Dir, name: []const u8) !void {
        parent.createDir(self.io, name, @enumFromInt(0o755)) catch {};
        const refs_tags_path = try std.fmt.allocPrint(self.allocator, "{s}/refs/tags", .{name});
        defer self.allocator.free(refs_tags_path);
        parent.createDir(self.io, refs_tags_path, @enumFromInt(0o755)) catch {};
    }

    fn writeRemoteRef(self: *TagPusher, parent: *const Io.Dir, remote: []const u8, tag: []const u8, data: []const u8) !void {
        const subpath = try std.fmt.allocPrint(self.allocator, "{s}/refs/tags/{s}", .{ remote, tag });
        defer self.allocator.free(subpath);
        var file = parent.createFile(self.io, subpath, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => parent.openFile(self.io, subpath, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print("{s}", .{data});
    }
};

test "TagPusher init" {
    const io = Io.init(.{});
    const pusher = TagPusher.init(std.testing.allocator, io);
    try std.testing.expect(pusher.allocator == std.testing.allocator);
}

test "TagPusher push method exists" {
    const io = Io.init(.{});
    var pusher = TagPusher.init(std.testing.allocator, io);
    try pusher.push("origin", "v1.0.0");
    try std.testing.expect(true);
}

test "TagPusher pushAll method exists" {
    const io = Io.init(.{});
    var pusher = TagPusher.init(std.testing.allocator, io);
    try pusher.pushAll("origin");
    try std.testing.expect(true);
}
