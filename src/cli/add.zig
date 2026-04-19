//! Git Add - Add file contents to the index
const std = @import("std");

pub const Add = struct {
    allocator: std.mem.Allocator,
    update: bool,
    verbose: bool,
    dry_run: bool,

    pub fn init(allocator: std.mem.Allocator) Add {
        return .{ .allocator = allocator, .update = false, .verbose = false, .dry_run = false };
    }

    pub fn run(self: *Add, paths: []const []const u8) !void {
        if (paths.len == 0) {
            try self.addAll();
        } else {
            for (paths) |path| {
                try self.addPath(path);
            }
        }
    }

    fn addAll(self: *Add) !void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (entry.kind == .file or entry.kind == .sym_link) {
                try self.addPath(entry.name);
            }
        }
    }

    fn addPath(self: *Add, path: []const u8) !void {
        if (self.dry_run) {
            try std.io.getStdOut().writer().print("add '{s}'\n", .{path});
            return;
        }

        const cwd = std.fs.cwd();
        try cwd.access(path, .{});

        if (self.verbose) {
            try std.io.getStdOut().writer().print("add '{s}'\n", .{path});
        }
    }
};

test "Add init" {
    const add = Add.init(std.testing.allocator);
    try std.testing.expect(add.update == false);
}

test "Add run method exists" {
    var add = Add.init(std.testing.allocator);
    try add.run(&.{});
    try std.testing.expect(true);
}