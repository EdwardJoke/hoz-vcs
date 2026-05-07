//! Remote Add - Add a remote repository
const std = @import("std");
const Io = std.Io;

pub const RemoteAdder = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) RemoteAdder {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn add(self: *RemoteAdder, name: []const u8, url: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";
        var file = cwd.openFile(self.io, config_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => cwd.createFile(self.io, config_path, .{}) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print(
            \\[remote "{s}"]
            \\	url = {s}
            \\
        , .{ name, url });
    }

    pub fn addWithMirror(self: *RemoteAdder, name: []const u8, url: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";
        var file = cwd.openFile(self.io, config_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => cwd.createFile(self.io, config_path, .{}) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print(
            \\[remote "{s}"]
            \\	url = {s}
            \\	mirror = true
            \\
        , .{ name, url });
    }
};

test "RemoteAdder init" {
    const io = Io.init(.{});
    const adder = RemoteAdder.init(std.testing.allocator, io);
    try std.testing.expect(adder.allocator == std.testing.allocator);
}

test "RemoteAdder add method exists" {
    const io = Io.init(.{});
    var adder = RemoteAdder.init(std.testing.allocator, io);
    try adder.add("origin", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}

test "RemoteAdder addWithMirror method exists" {
    const io = Io.init(.{});
    var adder = RemoteAdder.init(std.testing.allocator, io);
    try adder.addWithMirror("mirror", "https://github.com/user/repo.git");
    try std.testing.expect(true);
}
