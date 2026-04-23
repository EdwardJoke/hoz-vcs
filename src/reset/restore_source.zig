//! Restore Source - Specify source for restore (--source)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const SoftReset = @import("soft.zig").SoftReset;

pub const RestoreSource = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) RestoreSource {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn resolveSource(self: *RestoreSource, spec: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, spec, ":") != null) {
            return try self.parseTreeSpec(spec);
        }
        return try self.resolveCommit(spec);
    }

    pub fn getTreeFromSource(self: *RestoreSource, spec: []const u8) ![]const u8 {
        _ = self;
        _ = spec;
        return "";
    }

    fn resolveCommit(_: *RestoreSource, spec: []const u8) ![]const u8 {
        if (spec.len == 40) {
            return spec;
        }
        return spec;
    }

    fn parseTreeSpec(_: *RestoreSource, spec: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, spec, ":")) |colon| {
            return spec[colon + 1 ..];
        }
        return spec;
    }
};

test "RestoreSource init" {
    const source = RestoreSource.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(source.allocator == std.testing.allocator);
}
