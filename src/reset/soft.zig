//! Reset Soft - Reset HEAD only (--soft)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;

pub const SoftReset = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) SoftReset {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn reset(self: *SoftReset, target: []const u8) !void {
        const target_oid = try self.resolveTarget(target);
        try self.updateHEAD(target_oid);
    }

    pub fn getHeadCommit(self: *SoftReset) ![]const u8 {
        const head_ref = try self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256));
        defer self.allocator.free(head_ref);

        const trimmed = std.mem.trim(u8, head_ref, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            const commit_oid = try self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256));
            defer self.allocator.free(commit_oid);
            return std.mem.trim(u8, commit_oid, " \n\r");
        }
        return trimmed;
    }

    fn resolveTarget(self: *SoftReset, spec: []const u8) !OID {
        if (std.mem.startsWith(u8, spec, "refs/")) {
            const ref_content = self.git_dir.readFileAlloc(self.io, spec, self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(ref_content);
            const trimmed = std.mem.trim(u8, ref_content, " \n\r");
            return OID.fromHex(trimmed[0..40]);
        }

        if (spec.len == 40) {
            return OID.fromHex(spec);
        }

        if (std.mem.eql(u8, spec, "HEAD")) {
            return try self.resolveTarget(try self.getHeadCommit());
        }

        if (std.mem.eql(u8, spec, "FETCH_HEAD")) {
            const fetch_head = self.git_dir.readFileAlloc(self.io, "FETCH_HEAD", self.allocator, .limited(256)) catch {
                return OID{ .bytes = .{0} ** 20 };
            };
            defer self.allocator.free(fetch_head);
            const trimmed = std.mem.trim(u8, fetch_head, " \n\r");
            return OID.fromHex(trimmed[0..40]);
        }

        return OID{ .bytes = .{0} ** 20 };
    }

    fn updateHEAD(self: *SoftReset, oid: OID) !void {
        const head_path = "HEAD";
        const hex = oid.toHex();
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{hex});
        defer self.allocator.free(content);

        self.git_dir.writeFile(self.io, .{ .sub_path = head_path, .data = content }) catch {};
    }
};

test "SoftReset init" {
    const reset = SoftReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
