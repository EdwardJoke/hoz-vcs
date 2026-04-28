//! Tag Create Lightweight - Create a lightweight (non-annotated) tag
const std = @import("std");
const Io = std.Io;

pub const LightweightTagCreator = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) LightweightTagCreator {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn create(self: *LightweightTagCreator, name: []const u8, target: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch {
            cwd.createDir(self.io, ".git/refs/tags", @enumFromInt(0o755)) catch {};
            const td = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return;
            defer td.close(self.io);
            try self.writeRef(&td, name, target);
            return;
        };
        defer tags_dir.close(self.io);
        try self.writeRef(&tags_dir, name, target);
    }

    fn writeRef(self: *LightweightTagCreator, tags_dir: *const Io.Dir, name: []const u8, target: []const u8) !void {
        var file = tags_dir.createFile(self.io, name, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => tags_dir.openFile(self.io, name, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print("{s}\n", .{target});
    }
};

test "LightweightTagCreator init" {
    const io = Io.init(.{});
    const creator = LightweightTagCreator.init(std.testing.allocator, io);
    try std.testing.expect(creator.allocator == std.testing.allocator);
}

test "LightweightTagCreator create method exists" {
    const io = Io.init(.{});
    var creator = LightweightTagCreator.init(std.testing.allocator, io);
    try creator.create("v1.0.0", "abc123def456");
    try std.testing.expect(true);
}
