//! Git Bundle - Move objects and refs by archive
const std = @import("std");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Bundle = struct {
    allocator: std.mem.Allocator,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer, style: OutputStyle) Bundle {
        return .{
            .allocator = allocator,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Bundle, action: []const u8, file: ?[]const u8) !void {
        try self.output.section("Bundle");
        try self.output.item("action", action);
        if (file) |f| {
            try self.output.item("file", f);
        }
        try self.output.infoMessage("Bundle operation not yet implemented", .{});
    }
};

test "Bundle init" {
    const bundle = Bundle.init(std.testing.allocator, undefined, .{});
    _ = bundle;
    try std.testing.expect(true);
}
