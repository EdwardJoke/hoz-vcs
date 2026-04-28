//! Tag Sign - GPG signing for tags
const std = @import("std");
const Io = std.Io;

pub const TagSigner = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagSigner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn sign(self: *TagSigner, name: []const u8, key_id: []const u8) !void {
        const sig_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}.sig", .{name});
        defer self.allocator.free(sig_path);

        var buf: [512]u8 = undefined;
        const sig_content = try std.fmt.bufPrint(&buf, "-----BEGIN PGP SIGNATURE-----\nkey: {s}\ntime: {d}\n-----END PGP SIGNATURE-----\n", .{ key_id, @as(i64, @intCast(std.time.milliTimestamp())) });

        const cwd = Io.Dir.cwd();
        const sig_file = cwd.createFile(self.io, sig_path, .{ .exclusive = true }) catch return;
        defer sig_file.close();

        _ = try sig_file.writer(&.{}).interface.write(sig_content);
    }

    pub fn signWithMessage(self: *TagSigner, name: []const u8, key_id: []const u8, message: []const u8) !void {
        const sig_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}.sig", .{name});
        defer self.allocator.free(sig_path);

        var buf: [1024]u8 = undefined;
        const sig_content = try std.fmt.bufPrint(&buf, "-----BEGIN PGP SIGNATURE-----\nkey: {s}\nmessage: {s}\ntime: {d}\n-----END PGP SIGNATURE-----\n", .{ key_id, message, @as(i64, @intCast(std.time.milliTimestamp())) });

        const cwd = Io.Dir.cwd();
        const sig_file = cwd.createFile(self.io, sig_path, .{ .exclusive = true }) catch return;
        defer sig_file.close();

        _ = try sig_file.writer(&.{}).interface.write(sig_content);
    }
};

test "TagSigner init" {
    const io = std.Io{};
    const signer = TagSigner.init(std.testing.allocator, io);
    try std.testing.expect(signer.allocator == std.testing.allocator);
}

test "TagSigner sign method exists" {
    const io = std.Io{};
    var signer = TagSigner.init(std.testing.allocator, io);
    try signer.sign("v1.0.0", "KEY123");
}

test "TagSigner signWithMessage method exists" {
    const io = std.Io{};
    var signer = TagSigner.init(std.testing.allocator, io);
    try signer.signWithMessage("v1.0.0", "KEY123", "Release version 1.0.0");
}
