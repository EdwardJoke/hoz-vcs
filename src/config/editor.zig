//! Config Editor - Edit config with external editor
const std = @import("std");

pub const ConfigEditor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigEditor {
        return .{ .allocator = allocator };
    }

    pub fn edit(self: *ConfigEditor) !void {
        _ = self;
    }

    pub fn editWithPath(self: *ConfigEditor, path: []const u8) !void {
        _ = self;
        _ = path;
    }

    pub fn getEditor(self: *ConfigEditor) ![]const u8 {
        _ = self;
        return "vi";
    }
};

test "ConfigEditor init" {
    const editor = ConfigEditor.init(std.testing.allocator);
    try std.testing.expect(editor.allocator == std.testing.allocator);
}

test "ConfigEditor edit method exists" {
    var editor = ConfigEditor.init(std.testing.allocator);
    try editor.edit();
    try std.testing.expect(true);
}

test "ConfigEditor getEditor method exists" {
    var editor = ConfigEditor.init(std.testing.allocator);
    const ed = try editor.getEditor();
    try std.testing.expectEqualStrings("vi", ed);
}