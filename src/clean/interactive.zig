//! Clean Interactive - Interactive cleaning mode (-i)
const std = @import("std");
const Io = std.Io;

pub const CleanAction = enum {
    select,
    quit,
    help,
};

pub const CleanInteractive = struct {
    allocator: std.mem.Allocator,
    io: Io,
    selected: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: Io) !CleanInteractive {
        return .{
            .allocator = allocator,
            .io = io,
            .selected = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn deinit(self: *CleanInteractive) void {
        self.selected.deinit(self.allocator);
    }

    pub fn prompt(_: *CleanInteractive, path: []const u8) !bool {
        const stdout = Io.File.stdout().writer(&.{});
        try stdout.interface.print("Remove {s}? [y/N] ", .{path});

        var buf: [64]u8 = undefined;
        const stdin = Io.File.stdin().reader(&.{});
        const line = (stdin.interface.readUntilDelimiterOrEof(&buf, '\n') catch return false) orelse return false;
        const trimmed = std.mem.trim(u8, line, " \r\n");
        return trimmed.len == 1 and (trimmed[0] == 'y' or trimmed[0] == 'Y');
    }

    pub fn showMenu(self: *CleanInteractive) !void {
        _ = self;
        const stdout = Io.File.stdout().writer(&.{});
        try stdout.interface.print(
            \\*** Commands ***
            \\   select - select items to clean
            \\   quit   - stop cleaning
            \\   help  - show this message
            \\
        , .{});
    }

    pub fn selectAction(self: *CleanInteractive, action: []const u8, paths: []const []const u8) !void {
        const parsed = std.meta.stringToEnum(CleanAction, action) orelse .help;

        switch (parsed) {
            .select => {
                self.selected.shrinkRetainingCapacity(0);
                for (paths) |p| {
                    if (try self.prompt(p)) {
                        try self.selected.append(self.allocator, p);
                    }
                }
            },
            .quit => return error.UserQuit,
            .help => try self.showMenu(),
        }
    }

    pub fn getSelected(self: *CleanInteractive) []const []const u8 {
        return self.selected.items;
    }

    pub fn isInteractive(_: *CleanInteractive) bool {
        return true;
    }
};

test "CleanInteractive init" {
    const io = Io.Threaded.global_single_threaded.ioBasic();
    const cleaner = try CleanInteractive.init(std.testing.allocator, io);
    defer cleaner.deinit();
    try std.testing.expect(cleaner.isInteractive() == true);
}

test "CleanInteractive isInteractive" {
    const io = Io.Threaded.global_single_threaded.ioBasic();
    const cleaner = try CleanInteractive.init(std.testing.allocator, io);
    defer cleaner.deinit();
    try std.testing.expect(cleaner.isInteractive() == true);
}

test "CleanInteractive select action parses" {
    const io = Io.Threaded.global_single_threaded.ioBasic();
    var cleaner = try CleanInteractive.init(std.testing.allocator, io);
    defer cleaner.deinit();

    const test_paths = [_][]const u8{ "file1.txt", "file2.zig" };
    try cleaner.selectAction("help", &test_paths);
    try std.testing.expectEqual(@as(usize, 0), cleaner.getSelected().len);
}
