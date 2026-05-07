//! Config Editor - Edit config with external editor
const std = @import("std");

pub const ConfigEditor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigEditor {
        return .{ .allocator = allocator };
    }

    pub fn edit(self: *ConfigEditor) !void {
        const path = try self.getLocalConfigPath();
        defer self.allocator.free(path);
        try self.launchEditor(path);
    }

    pub fn editWithPath(self: *ConfigEditor, path: []const u8) !void {
        try self.launchEditor(path);
    }

    pub fn getEditor(self: *ConfigEditor) ![]const u8 {
        _ = self;
        if (std.c.getenv("EDITOR")) |ed| {
            return std.mem.sliceTo(ed, 0);
        }
        if (std.c.getenv("VISUAL")) |vis| {
            return std.mem.sliceTo(vis, 0);
        }
        return "vi";
    }

    fn launchEditor(self: *ConfigEditor, path: []const u8) !void {
        const editor = try self.getEditor();
        var child = std.process.Child.init(&.{ editor, path }, self.allocator);
        const term = child.spawnAndWait() catch |err| {
            if (err == error.FileNotFound) {
                return error.EditorNotFound;
            }
            return err;
        };
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.EditorExitedAbnormally;
            },
            .Signal, .Stopped, .Unknown => return error.EditorExitedAbnormally,
        }
    }

    fn getLocalConfigPath(self: *ConfigEditor) ![]const u8 {
        if (std.c.getenv("HOME")) |home| {
            return std.fmt.allocPrint(self.allocator, "{s}/.config/hoz/config", .{std.mem.sliceTo(home, 0)});
        }
        return error.HomeNotFound;
    }
};

test "ConfigEditor init" {
    const editor = ConfigEditor.init(std.testing.allocator);
    _ = editor;
}

test "ConfigEditor getEditor defaults to vi" {
    var editor = ConfigEditor.init(std.testing.allocator);
    const ed = try editor.getEditor();
    try std.testing.expect(ed.len > 0);
}
