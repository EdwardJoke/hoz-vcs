//! Git Notes - Add or inspect object notes
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Notes = struct {
    allocator: std.mem.Allocator,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Notes {
        return .{
            .allocator = allocator,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Notes, action: []const u8, object: ?[]const u8) !void {
        try self.output.section("Notes");
        try self.output.item("action", action);
        if (object) |o| {
            try self.output.item("object", o);
        }
        try self.output.infoMessage("Notes operation not yet implemented", .{});
    }
};

test "Notes init" {
    const notes = Notes.init(std.testing.allocator, undefined, .{});
    _ = notes;
    try std.testing.expect(true);
}
