//! Release Package Builder - Build release packages for distribution
const std = @import("std");

pub const ReleaseBuilder = struct {
    allocator: std.mem.Allocator,
    version: []const u8,
    output_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator) ReleaseBuilder {
        return .{
            .allocator = allocator,
            .version = "1.0.0",
            .output_dir = "releases",
        };
    }

    pub fn buildTarGz(self: *ReleaseBuilder) ![]const u8 {
        const archive_name = try std.fmt.allocPrint(self.allocator, "hoz-{s}.tar.gz", .{self.version});
        _ = self;
        return archive_name;
    }

    pub fn buildZip(self: *ReleaseBuilder) ![]const u8 {
        const archive_name = try std.fmt.allocPrint(self.allocator, "hoz-{s}.zip", .{self.version});
        _ = self;
        return archive_name;
    }

    pub fn setVersion(self: *ReleaseBuilder, version: []const u8) void {
        self.version = version;
    }

    pub fn setOutputDir(self: *ReleaseBuilder, dir: []const u8) void {
        self.output_dir = dir;
    }

    pub fn getPackageName(self: *ReleaseBuilder, platform: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "hoz-{s}-{s}", .{ self.version, platform });
    }
};

test "ReleaseBuilder init" {
    const builder = ReleaseBuilder.init(std.testing.allocator);
    try std.testing.expectEqualStrings("1.0.0", builder.version);
}

test "ReleaseBuilder buildTarGz" {
    var builder = ReleaseBuilder.init(std.testing.allocator);
    const archive = try builder.buildTarGz();
    defer std.testing.allocator.free(archive);
    try std.testing.expect(std.mem.endsWith(u8, archive, ".tar.gz"));
}

test "ReleaseBuilder getPackageName" {
    var builder = ReleaseBuilder.init(std.testing.allocator);
    const name = try builder.getPackageName("linux-x64");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("hoz-1.0.0-linux-x64", name);
}