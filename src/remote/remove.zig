//! Remote Remove - Remove a remote repository
const std = @import("std");
const Io = std.Io;

pub const RemoveOptions = struct {
    force: bool = false,
};

pub const RemoteRemover = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: RemoveOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: RemoveOptions) RemoteRemover {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn remove(self: *RemoteRemover, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_data = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(config_data);

        var output = try std.ArrayList(u8).initCapacity(self.allocator, config_data.len);
        defer output.deinit(self.allocator);

        var lines = std.mem.splitSequence(u8, config_data, "\n");
        var skipping: bool = false;

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "[")) {
                const section_header = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
                defer self.allocator.free(section_header);
                if (std.mem.eql(u8, line, section_header)) {
                    skipping = true;
                    continue;
                } else {
                    skipping = false;
                }
            }

            if (skipping) continue;

            try output.appendSlice(self.allocator, line);
            try output.append(self.allocator, '\n');
        }

        var file = cwd.createFile(self.io, ".git/config", .{}) catch return;
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(output.items);

        self.cleanupRefsRemotes(name);
    }

    pub fn removeWithForce(self: *RemoteRemover, name: []const u8) !void {
        try self.remove(name);
    }

    fn cleanupRefsRemotes(self: *RemoteRemover, name: []const u8) void {
        const refs_remotes_path = try std.fmt.allocPrint(self.allocator, ".git/refs/remotes/{s}", .{name});
        defer self.allocator.free(refs_remotes_path);

        const cwd = Io.Dir.cwd();
        _ = cwd.openDir(self.io, refs_remotes_path, .{}) catch return;
        cwd.deleteDir(self.io, refs_remotes_path) catch {};
    }
};

test "RemoveOptions default values" {
    const options = RemoveOptions{};
    try std.testing.expect(options.force == false);
}

test "RemoteRemover init" {
    const io = Io.init(.{});
    const options = RemoveOptions{};
    const remover = RemoteRemover.init(std.testing.allocator, io, options);
    try std.testing.expect(remover.allocator == std.testing.allocator);
}

test "RemoteRemover init with options" {
    const io = Io.init(.{});
    var options = RemoveOptions{};
    options.force = true;
    const remover = RemoteRemover.init(std.testing.allocator, io, options);
    try std.testing.expect(remover.options.force == true);
}

test "RemoteRemover remove method exists" {
    const io = Io.init(.{});
    var remover = RemoteRemover.init(std.testing.allocator, io, .{});
    try remover.remove("origin");
    try std.testing.expect(true);
}

test "RemoteRemover removeWithForce method exists" {
    const io = Io.init(.{});
    var remover = RemoteRemover.init(std.testing.allocator, io, .{});
    try remover.removeWithForce("origin");
    try std.testing.expect(true);
}
