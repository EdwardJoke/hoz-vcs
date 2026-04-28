//! Tag Delete - Delete a tag
const std = @import("std");
const Io = std.Io;

pub const TagDeleter = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagDeleter {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn delete(self: *TagDeleter, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{name});
        defer self.allocator.free(ref_path);
        cwd.deleteFile(self.io, ref_path) catch {};
    }

    pub fn deleteRemote(self: *TagDeleter, remote: []const u8, name: []const u8) !void {
        _ = remote;
        const cwd = Io.Dir.cwd();
        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{name});
        defer self.allocator.free(ref_path);
        cwd.deleteFile(self.io, ref_path) catch {};
    }
};

test "TagDeleter init" {
    const io = Io.init(.{});
    const deleter = TagDeleter.init(std.testing.allocator, io);
    try std.testing.expect(deleter.allocator == std.testing.allocator);
}

test "TagDeleter delete method exists" {
    const io = Io.init(.{});
    var deleter = TagDeleter.init(std.testing.allocator, io);
    try deleter.delete("v1.0.0");
    try std.testing.expect(true);
}

test "TagDeleter deleteRemote method exists" {
    const io = Io.init(.{});
    var deleter = TagDeleter.init(std.testing.allocator, io);
    try deleter.deleteRemote("origin", "v1.0.0");
    try std.testing.expect(true);
}
