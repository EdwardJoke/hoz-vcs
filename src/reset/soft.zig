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
            const ref_path = std.mem.trim(u8, trimmed[5..], " \n\r");
            const commit_oid = try self.git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256));
            defer self.allocator.free(commit_oid);
            const resolved = std.mem.trim(u8, commit_oid, " \n\r");
            return self.allocator.dupe(u8, resolved);
        }
        return self.allocator.dupe(u8, trimmed);
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
            const head_commit = try self.getHeadCommit();
            defer self.allocator.free(head_commit);
            return try self.resolveTarget(head_commit);
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
        const hex = oid.toHex();
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{hex});
        defer self.allocator.free(content);

        const head_data = self.git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch null;
        defer if (head_data) |buf| self.allocator.free(buf);

        if (head_data) |buf| {
            const trimmed = std.mem.trim(u8, buf, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = std.mem.trim(u8, trimmed[5..], " \n\r");
                try self.git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = content });
                return;
            }
        }

        try self.git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = content });
    }
};

test "SoftReset init" {
    const reset = SoftReset.init(std.testing.allocator, undefined, undefined);
    try std.testing.expect(reset.allocator == std.testing.allocator);
}
