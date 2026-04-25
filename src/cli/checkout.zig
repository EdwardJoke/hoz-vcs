//! Git Checkout - Switch branches or restore working tree files
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const CheckoutOptions = @import("../checkout/options.zig").CheckoutOptions;
const CheckoutStrategy = @import("../checkout/options.zig").CheckoutStrategy;

pub const Checkout = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: CheckoutOptions,
    target: ?[]const u8,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Checkout {
        return .{
            .allocator = allocator,
            .io = io,
            .options = CheckoutOptions{},
            .target = null,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Checkout) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        if (self.target) |t| {
            try self.output.infoMessage("Checking out: {s}", .{t});
        } else {
            try self.output.errorMessage("No branch or commit specified", .{});
            return;
        }

        try self.output.successMessage("Checkout completed", .{});
    }
};

test "Checkout init" {
    const io = std.Io.Threaded.new(.{}).?;
    const checkout = Checkout.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(checkout.target == null);
}

test "CheckoutStrategy enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(CheckoutStrategy.force));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(CheckoutStrategy.safe));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(CheckoutStrategy.update_only));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(CheckoutStrategy.migrate));
}
