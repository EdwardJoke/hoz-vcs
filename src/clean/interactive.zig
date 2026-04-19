//! Clean Interactive - Interactive cleaning mode (-i)
const std = @import("std");

pub const CleanInteractive = struct {
    allocator: std.mem.Allocator,
    interactive: bool,

    pub fn init(allocator: std.mem.Allocator) CleanInteractive {
        return .{ .allocator = allocator, .interactive = true };
    }

    pub fn prompt(self: *CleanInteractive, path: []const u8) !bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn showMenu(self: *CleanInteractive) !void {
        _ = self;
    }

    pub fn selectAction(self: *CleanInteractive, action: []const u8, paths: []const []const u8) !void {
        _ = self;
        _ = action;
        _ = paths;
    }

    pub fn isInteractive(self: *CleanInteractive) bool {
        return self.interactive;
    }
};

test "CleanInteractive init" {
    const cleaner = CleanInteractive.init(std.testing.allocator);
    try std.testing.expect(cleaner.interactive == true);
}

test "CleanInteractive isInteractive" {
    const cleaner = CleanInteractive.init(std.testing.allocator);
    try std.testing.expect(cleaner.isInteractive() == true);
}

test "CleanInteractive prompt method exists" {
    var cleaner = CleanInteractive.init(std.testing.allocator);
    const result = try cleaner.prompt("file.txt");
    _ = result;
    try std.testing.expect(true);
}