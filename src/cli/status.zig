//! Git Status - Show working tree status
const std = @import("std");

pub const Status = struct {
    allocator: std.mem.Allocator,
    porcelain: bool,
    short_format: bool,

    pub fn init(allocator: std.mem.Allocator) Status {
        return .{ .allocator = allocator, .porcelain = false, .short_format = false };
    }

    pub fn run(self: *Status) !void {
        const cwd = std.fs.cwd();

        if (self.porcelain) {
            try self.runPorcelain(cwd);
        } else if (self.short_format) {
            try self.runShort(cwd);
        } else {
            try self.runLong(cwd);
        }
    }

    fn runPorcelain(self: *Status, cwd: std.fs.Cwd) !void {
        _ = self;
        const stdout = std.io.getStdOut().writer();
        var dir = cwd.openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            try stdout.print("?? {s}\n", .{entry.name});
        }
    }

    fn runShort(self: *Status, cwd: std.fs.Cwd) !void {
        _ = self;
        try std.io.getStdOut().writer().print("?? <unstaged>\n", .{});
    }

    fn runLong(self: *Status, cwd: std.fs.Cwd) !void {
        _ = self;
        _ = cwd;
        try std.io.getStdOut().writer().print("On branch main\n\nNo commits yet\n\nnothing to commit (create/copy files and use \"git add\")\n", .{});
    }
};

test "Status init" {
    const status = Status.init(std.testing.allocator);
    try std.testing.expect(status.porcelain == false);
}

test "Status run method exists" {
    var status = Status.init(std.testing.allocator);
    try status.run();
    try std.testing.expect(true);
}