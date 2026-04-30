//! Git Commit - Record changes to the repository
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const oid_mod = @import("../object/oid.zig");
const CommitObj = @import("../object/commit.zig").Commit;
const Identity = @import("../object/commit.zig").Identity;
const Index = @import("../index/index.zig").Index;
const tree_builder = @import("../tree/builder.zig");
const compress_mod = @import("../compress/zlib.zig");
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

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
        try self.output.successMessage("--→ [{s} {s}] {s}", .{
            if (self.amend) "amended" else "root",
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
            const empty_tree = try std.fmt.allocPrint(self.allocator, "tree 0\x00", .{});
            defer self.allocator.free(empty_tree);
            const empty_oid = oid_mod.oidFromContent(empty_tree);
            try self.writeLooseObject(git_dir, empty_tree);
            return empty_oid;
        };
        defer self.allocator.free(index_data);

        var index = Index.parse(index_data, self.allocator) catch {
            const empty_tree = try std.fmt.allocPrint(self.allocator, "tree 0\x00", .{});
            defer self.allocator.free(empty_tree);
            const empty_oid = oid_mod.oidFromContent(empty_tree);
            try self.writeLooseObject(git_dir, empty_tree);
            return empty_oid;
        };
        defer index.deinit();

        if (index.entries.items.len == 0) {
            const empty_tree = try std.fmt.allocPrint(self.allocator, "tree 0\x00", .{});
            defer self.allocator.free(empty_tree);
            const empty_oid = oid_mod.oidFromContent(empty_tree);
            try self.writeLooseObject(git_dir, empty_tree);
            return empty_oid;
        }

        const tree = tree_builder.buildTreeFromIndex(self.allocator, index) catch {
            return oid_mod.oidFromContent("tree 0\x00");
        };

        const serialized = try tree.serialize(self.allocator);
        defer self.allocator.free(serialized);

        const tree_oid = oid_mod.oidFromContent(serialized);
        try self.writeLooseObject(git_dir, serialized);
        return tree_oid;
    }

    fn resolveHead(self: *Commit, git_dir: *const Io.Dir) !?OID {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return null;
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = std.mem.trim(u8, trimmed["ref: ".len..], " \n\r");
            const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return null;
            defer self.allocator.free(ref_content);
            const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (ref_trimmed.len >= 40) {
                return OID.fromHex(ref_trimmed[0..40]) catch return null;
            }
            return null;
        }

        if (trimmed.len >= 40) {
            return OID.fromHex(trimmed[0..40]) catch return null;
        }

        return null;
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
        const hash = @import("../crypto/sha1.zig").sha1(data);
        var oid_bytes: [20]u8 = undefined;
        @memcpy(&oid_bytes, &hash);
        const oid = OID{ .bytes = oid_bytes };

        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        git_dir.createDirPath(self.io, obj_dir) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = compress_mod.Zlib.compress(data, self.allocator) catch return;
        defer self.allocator.free(compressed);

        git_dir.writeFile(self.io, .{ .sub_path = obj_path, .data = compressed }) catch {};
    }

    fn readObject(self: *Commit, git_dir: *const Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch {
            return error.ObjectNotFound;
        };
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.CorruptObject;
        };
    }

    fn timezoneOffset(_: *Commit) i32 {
        return 0;
    }
};

test "Commit init" {
    const io = std.Io.Threaded.new(.{}).?;
    const commit = Commit.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(commit.message == null);
}
