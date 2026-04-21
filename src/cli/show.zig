//! Git Show - Show various types of objects
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Show = struct {
    allocator: std.mem.Allocator,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Show {
        return .{
            .allocator = allocator,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Show, object: ?[]const u8) !void {
        if (object == null) {
            try self.output.errorMessage("No object specified. Use 'hoz show <object>'", .{});
            return;
        }

        try self.output.section("Show");
        try self.output.item("object", object.?);
        try self.output.infoMessage("Object details would be displayed here", .{});
    }
};

test "Show init" {
    const show = Show.init(std.testing.allocator, undefined, .{});
    _ = show;
    try std.testing.expect(true);
}
