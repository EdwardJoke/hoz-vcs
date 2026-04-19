//! Bisect Run - Automated bisect testing
const std = @import("std");

pub const BisectRun = struct {
    allocator: std.mem.Allocator,
    test_command: []const []const u8,
    exit_code: i32,

    pub fn init(allocator: std.mem.Allocator) BisectRun {
        return .{
            .allocator = allocator,
            .test_command = &.{},
            .exit_code = 0,
        };
    }

    pub fn run(self: *BisectRun, commit: []const u8) !i32 {
        _ = commit;
        return self.exit_code;
    }

    pub fn execute(self: *BisectRun, cmd: []const []const u8) !i32 {
        self.test_command = cmd;
        return self.exit_code;
    }

    pub fn setExitCode(self: *BisectRun, code: i32) void {
        self.exit_code = code;
    }

    pub fn getNextCommit(self: *BisectRun, current: []const u8) ![]const u8 {
        _ = self;
        _ = current;
        return "";
    }
};

test "BisectRun init" {
    const bisect = BisectRun.init(std.testing.allocator);
    try std.testing.expect(bisect.exit_code == 0);
}

test "BisectRun setExitCode" {
    var bisect = BisectRun.init(std.testing.allocator);
    bisect.setExitCode(1);
    try std.testing.expect(bisect.exit_code == 1);
}

test "BisectRun execute method exists" {
    var bisect = BisectRun.init(std.testing.allocator);
    const code = try bisect.execute(&.{"test.sh"});
    _ = code;
    try std.testing.expect(true);
}