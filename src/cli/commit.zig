//! Git Commit - Record changes to the repository
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const CommitObj = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const Index = @import("../index/index.zig").Index;
const tree_builder = @import("../tree/builder.zig");
const compress_mod = @import("../compress/zlib.zig");
const object_io = @import("../object/io.zig");
const head_mod = @import("../commit/head.zig");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const c_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: [*c]const u8,
};
extern fn localtime_r([*c]const c_long, [*c]c_tm) [*c]c_tm;
extern fn time([*c]c_long) c_long;
const have_localtime = builtin.os.tag != .windows;

pub const Commit = struct {
    allocator: std.mem.Allocator,
    io: Io,
    message: ?[]const u8,
    all: bool,
    amend: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Commit {
        return .{
            .allocator = allocator,
            .io = io,
            .message = null,
            .all = false,
            .amend = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Commit) !void {
        if (self.message == null) {
            try self.output.errorMessage("-x- Missing commit message. Use -m \"<message>\"", .{});
            return;
        }

        const git_dir = Io.Dir.openDirAbsolute(self.io, ".git", .{}) catch {
            try self.output.errorMessage("-x- Not a Hoz repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const commit_oid = try self.createCommit(&git_dir);
        const hex = commit_oid.toHex();
        const is_root = (self.resolveHead(&git_dir) catch null) == null;
        try self.output.successMessage("--→ [{s} {s}] {s}", .{
            if (self.amend) "amended" else if (is_root) "root" else "commit",
            hex[0..7],
            self.message.?,
        });
    }

    fn createCommit(self: *Commit, git_dir: *const Io.Dir) !OID {
        const now = Io.Timestamp.now(self.io, .real);
        const timestamp: i64 = @intCast(@divTrunc(now.nanoseconds, 1000000000));

        var author_name: []const u8 = "Hoz User";
        var author_email: []const u8 = "hoz@local";

        if (std.c.getenv("GIT_AUTHOR_NAME")) |name| {
            const s: [*:0]const u8 = @ptrCast(name);
            if (std.mem.len(s) > 0) author_name = std.mem.sliceTo(s, 0);
        }

        if (std.c.getenv("GIT_AUTHOR_EMAIL")) |email| {
            const s: [*:0]const u8 = @ptrCast(email);
            if (std.mem.len(s) > 0) author_email = std.mem.sliceTo(s, 0);
        }

        const author = Identity{
            .name = author_name,
            .email = author_email,
            .timestamp = timestamp,
            .timezone = self.timezoneOffset(),
        };

        const committer = Identity{
            .name = author_name,
            .email = author_email,
            .timestamp = timestamp,
            .timezone = self.timezoneOffset(),
        };

        const tree_oid = try self.writeTree(git_dir);

        var parents = std.ArrayList(OID).empty;
        defer parents.deinit(self.allocator);

        if (!self.amend) {
            const head_oid = self.resolveHead(git_dir) catch null;
            if (head_oid) |oid| {
                if (!oid.isZero()) {
                    try parents.append(self.allocator, oid);
                }
            }
        } else {
            const head_oid = (self.resolveHead(git_dir) catch null) orelse OID{ .bytes = .{0} ** 20 };
            if (!head_oid.isZero()) {
                try parents.append(self.allocator, head_oid);
                const it = self.readCommitParents(git_dir, head_oid) catch &.{};
                for (it) |p| {
                    try parents.append(self.allocator, p);
                }
            }
        }

        const parent_slice = try parents.toOwnedSlice(self.allocator);
        defer self.allocator.free(parent_slice);

        const commit_obj = CommitObj.create(tree_oid, parent_slice, author, committer, self.message.?);

        const serialized = try commit_obj.serialize(self.allocator);
        defer self.allocator.free(serialized);

        const commit_oid = oid_mod.oidFromContent(serialized);

        try self.writeLooseObject(git_dir, serialized);

        try self.updateHead(git_dir, commit_oid);

        return commit_oid;
    }

    fn writeTree(self: *Commit, git_dir: *const Io.Dir) !OID {
        const index_data = git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(16 * 1024 * 1024)) catch {
            return self.writeEmptyTree(git_dir);
        };
        defer self.allocator.free(index_data);

        var index = Index.parse(index_data, self.allocator) catch {
            return self.writeEmptyTree(git_dir);
        };
        defer index.deinit();

        if (index.entries.items.len == 0) {
            return self.writeEmptyTree(git_dir);
        }

        const tree = tree_builder.buildTreeFromIndex(self.allocator, index) catch {
            return self.writeEmptyTree(git_dir);
        };

        const serialized = try tree.serialize(self.allocator);
        defer self.allocator.free(serialized);

        const tree_oid = oid_mod.oidFromContent(serialized);
        try self.writeLooseObject(git_dir, serialized);
        return tree_oid;
    }

    fn writeEmptyTree(self: *Commit, git_dir: *const Io.Dir) !OID {
        const empty_tree = "tree 0\x00";
        const empty_oid = oid_mod.oidFromContent(empty_tree);
        try self.writeLooseObject(git_dir, empty_tree);
        return empty_oid;
    }

    fn resolveHead(self: *Commit, git_dir: *const Io.Dir) !?OID {
        return head_mod.resolveHeadOid(git_dir, self.io, self.allocator);
    }

    fn readCommitParents(self: *Commit, git_dir: *const Io.Dir, commit_oid: OID) ![]const OID {
        const obj_data = self.readObject(git_dir, commit_oid) catch return &.{};
        defer self.allocator.free(obj_data);

        var parents = std.ArrayList(OID).empty;
        defer parents.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, obj_data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "parent ")) {
                const hex = line[7..];
                if (hex.len >= 40) {
                    const p_oid = OID.fromHex(hex[0..40]) catch continue;
                    try parents.append(self.allocator, p_oid);
                }
            }
        }

        return parents.toOwnedSlice(self.allocator);
    }

    fn updateHead(self: *Commit, git_dir: *const Io.Dir, oid: OID) !void {
        const hex = oid.toHex();
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
        defer self.allocator.free(content);

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            try git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = content });
            return;
        };
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = std.mem.trim(u8, trimmed["ref: ".len..], " \n\r");
            try git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = content });
        } else {
            try git_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = content });
        }
    }

    fn writeLooseObject(self: *Commit, git_dir: *const Io.Dir, data: []const u8) !void {
        _ = try object_io.writeLooseObject(git_dir, self.io, self.allocator, data);
    }

    fn readObject(self: *Commit, git_dir: *const Io.Dir, oid: OID) ![]u8 {
        return object_io.readObject(git_dir, self.io, self.allocator, oid);
    }

    fn timezoneOffset(_: *Commit) i32 {
        if (!have_localtime) return 0;
        var tm: c_tm = undefined;
        var now: c_long = 0;
        _ = time(&now);
        _ = localtime_r(&now, &tm);
        return @intCast(@divTrunc(tm.tm_gmtoff, 60));
    }
};

test "Commit init" {
    const io = std.Io.Threaded.new(.{}).?;
    const commit = Commit.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(commit.message == null);
}
