//! Restore Source - Specify source for restore (--source)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const object_mod = @import("../object/object.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");
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
        const resolved = try self.resolveSource(spec);
        const commit_oid = try self.resolveToOid(resolved);
        return try self.extractTreeHex(commit_oid);
    }

    fn resolveToOid(self: *RestoreSource, spec: []const u8) !OID {
        if (spec.len >= 40) {
            return OID.fromHex(spec[0..40]) catch return OID{ .bytes = .{0} ** 20 };
        }

        if (std.mem.startsWith(u8, spec, "refs/")) {
            const ref_content = self.git_dir.readFileAlloc(self.io, spec, self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(ref_content);
            const trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
            }
        }

        if (std.mem.eql(u8, spec, "HEAD")) {
            const head_data = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(head_data);
            const trimmed = std.mem.trim(u8, head_data, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                const ref_content = self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
                    return OID{ .bytes = .{0} ** 20 };
                };
                defer self.allocator.free(ref_content);
                const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
                if (ref_trimmed.len >= 40) {
                    return OID.fromHex(ref_trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
                }
            }
            if (trimmed.len >= 40) {
                return OID.fromHex(trimmed[0..40]) catch OID{ .bytes = .{0} ** 20 };
            }
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn extractTreeHex(self: *RestoreSource, commit_oid: OID) ![]const u8 {
        if (commit_oid.isZero()) return "";

        const commit_data = self.readObject(commit_oid) catch return "";
        defer self.allocator.free(commit_data);

        const obj = object_mod.parse(commit_data) catch return "";
        if (obj.obj_type != .commit) return "";

        var lines = std.mem.splitScalar(u8, obj.data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tree ")) {
                const tree_hex = line[5..];
                if (tree_hex.len >= 40) {
                    return try self.allocator.dupe(u8, tree_hex[0..40]);
                }
            }
            if (line.len == 0) break;
        }

        return "";
    }

    fn readObject(self: *RestoreSource, oid: OID) ![]u8 {
        return object_io.readObject(&self.git_dir, self.io, self.allocator, oid);
    }

    fn resolveCommit(_: *RestoreSource, spec: []const u8) ![]const u8 {
        if (spec.len == 40) {
            return spec;
        }
        return spec;
    }

    fn parseTreeSpec(_: *RestoreSource, spec: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, spec, ":")) |colon| {
            return spec[0..colon];
        }
        return spec;
    }
};

test "RestoreSource init" {
    const source = RestoreSource.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(source.allocator == std.testing.allocator);
}
