//! Clone Bare - Bare repository clone
const std = @import("std");
const Io = std.Io;
const CloneOptions = @import("options.zig").CloneOptions;
const CloneResult = @import("options.zig").CloneResult;
const network = @import("../network/network.zig");
const protocol = @import("../network/protocol.zig");
const packet = @import("../network/packet.zig");
const transport = @import("../network/transport.zig");
const refs = @import("../network/refs.zig");
const pack_recv = @import("../network/pack_recv.zig");

pub const CloneError = error{
    TransportError,
    RefNotFound,
    CloneFailed,
    ShallowNotSupported,
    CreateDirectoryFailed,
    WriteRefFailed,
};

pub const BareCloner = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) BareCloner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn clone(self: *BareCloner, url: []const u8, path: []const u8) !void {
        return self.cloneWithOptions(url, path, .{});
    }

    pub fn cloneWithOptions(self: *BareCloner, url: []const u8, path: []const u8, options: CloneOptions) !void {
        try self.createBareRepository(path, options.depth);
        try self.fetchAndSetupRefs(url, path, options.depth);
    }

    pub fn cloneWithDepth(self: *BareCloner, url: []const u8, path: []const u8, depth: u32) !void {
        const options = CloneOptions{ .depth = depth };
        return self.cloneWithOptions(url, path, options);
    }

    pub fn createBareRepository(self: *BareCloner, path: []const u8, depth: u32) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, path);
        try self.createGitDirContents(path, depth);
    }

    fn createGitDirContents(self: *BareCloner, git_dir_path: []const u8, depth: u32) !void {
        const cwd = std.Io.Dir.cwd();
        const dirs = [_][]const u8{ "objects", "objects/info", "objects/pack", "refs/heads", "refs/tags" };
        for (dirs) |dir| {
            const full_path = try std.fs.path.join(self.allocator, &.{ git_dir_path, dir });
            defer self.allocator.free(full_path);
            try cwd.createDirPath(self.io, full_path);
        }

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{git_dir_path});
        defer self.allocator.free(head_path);
        try cwd.writeFile(self.io, .{ .sub_path = head_path, .data = "ref: refs/heads/main\n" });

        if (depth > 0) {
            const shallow_path = try std.fmt.allocPrint(self.allocator, "{s}/objects/info/shallow", .{git_dir_path});
            defer self.allocator.free(shallow_path);
            try cwd.writeFile(self.io, .{ .sub_path = shallow_path, .data = "" });
        }
    }

    pub fn setupRemoteTrackingRefs(self: *BareCloner, git_dir: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const refs_remotes = try std.fs.path.join(self.allocator, &.{ git_dir, "refs", "remotes", "origin" });
        defer self.allocator.free(refs_remotes);

        cwd.createDirPath(self.io, refs_remotes) catch {};

        const head_path = try std.fs.path.join(self.allocator, &.{ git_dir, "HEAD" });
        defer self.allocator.free(head_path);

        const head_content = cwd.readFileAlloc(self.io, head_path, self.allocator, .limited(256)) catch return;
        defer self.allocator.free(head_content);

        if (std.mem.startsWith(u8, head_content, "ref: refs/heads/")) {
            const branch_name = std.mem.trim(u8, head_content["ref: refs/heads/".len..], " \n");
            const branch_ref = try std.fs.path.join(self.allocator, &.{ git_dir, "refs", "heads", branch_name });
            defer self.allocator.free(branch_ref);

            const oid_content = cwd.readFileAlloc(self.io, branch_ref, self.allocator, .limited(64)) catch return;
            defer self.allocator.free(oid_content);

            const tracking_ref = try std.fs.path.join(self.allocator, &.{ refs_remotes, branch_name });
            defer self.allocator.free(tracking_ref);

            try cwd.writeFile(self.io, .{ .sub_path = tracking_ref, .data = std.mem.trim(u8, oid_content, " \n") });
        }
    }

    fn fetchAndSetupRefs(self: *BareCloner, url: []const u8, git_dir: []const u8, depth: u32) !void {
        var t = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try t.connect();
        defer t.disconnect();

        const remote_refs = try t.fetchRefs();
        defer self.allocator.free(remote_refs);

        if (remote_refs.len == 0) return;

        var want_oids = std.ArrayList([]const u8).initCapacity(self.allocator, remote_refs.len) catch |err| return err;
        defer {
            for (want_oids.items) |oid| self.allocator.free(oid);
            want_oids.deinit(self.allocator);
        }

        for (remote_refs) |ref| {
            const oid_copy = try self.allocator.dupe(u8, ref.oid);
            try want_oids.append(self.allocator, oid_copy);
        }

        const pack_data = try t.fetchPack(want_oids.items, &.{});
        defer self.allocator.free(pack_data);

        var receiver = pack_recv.PackReceiver.init(self.allocator, .{});
        const received_count = try receiver.receiveAndStore(self.io, self.allocator, git_dir, pack_data);
        receiver.deinit();

        if (received_count == 0) {
            const empty_pack_path = try std.fmt.allocPrint(self.allocator, "{s}/info/empty-pack", .{git_dir});
            defer self.allocator.free(empty_pack_path);
            // Empty-pack sentinel: marks that a fetch was performed but resulted in no objects.
            // This distinguishes "fetch returned nothing" from "no fetch attempted yet",
            // preventing redundant refetches in subsequent operations.
            _ = std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = empty_pack_path, .data = "" }) catch {};
        }

        for (remote_refs) |ref| {
            try self.createLocalRef(git_dir, ref.name, ref.oid);
        }

        if (depth > 0) {
            try self.updateShallowInfo(git_dir, remote_refs);
        }
    }

    fn updateShallowInfo(self: *BareCloner, git_dir: []const u8, remote_refs: []const refs.RemoteRef) !void {
        var content = std.ArrayList(u8).initCapacity(self.allocator, remote_refs.len * 42) catch |err| return err;
        defer content.deinit(self.allocator);

        for (remote_refs) |ref| {
            try content.appendSlice(self.allocator, ref.oid);
            try content.append(self.allocator, '\n');
        }

        const cwd = std.Io.Dir.cwd();
        const shallow_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/objects/info/shallow" });
        defer self.allocator.free(shallow_path);

        try cwd.writeFile(self.io, .{ .sub_path = shallow_path, .data = content.items });
    }

    fn createLocalRef(self: *BareCloner, git_dir: []const u8, ref_name: []const u8, oid: []const u8) !void {
        const ref_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/", ref_name });
        defer self.allocator.free(ref_path);

        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(ref_path)) |parent_dir| {
            if (parent_dir.len > 0) {
                try cwd.createDirPath(self.io, parent_dir);
            }
        }

        const ref_content = try std.mem.concat(self.allocator, u8, &.{ oid, "\n" });
        defer self.allocator.free(ref_content);

        try cwd.writeFile(self.io, .{ .sub_path = ref_path, .data = ref_content });
    }

    fn writeFetchHeadRecord(self: *BareCloner, git_dir: []const u8, oid: []const u8, ref_name: []const u8, is_not_for_merge: bool) !void {
        const fetch_head_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/FETCH_HEAD" });
        defer self.allocator.free(fetch_head_path);

        var fetch_head_content = std.ArrayList(u8).init(self.allocator);
        defer fetch_head_content.deinit(self.allocator);

        if (is_not_for_merge) {
            try fetch_head_content.writer().print("{s}\tnot-for-merge {s}\n", .{ oid, ref_name });
        } else {
            try fetch_head_content.writer().print("{s}\t{s}\n", .{ oid, ref_name });
        }

        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = fetch_head_path, .data = fetch_head_content.items });
    }
};

pub fn normalizeClonePath(url: []const u8) []const u8 {
    if (std.mem.endsWith(u8, url, ".git")) {
        return url[0 .. url.len - 4];
    }
    return url;
}

pub fn getRepoNameFromUrl(url: []const u8) []const u8 {
    var path = url;
    if (std.mem.indexOf(u8, path, "://")) |idx| {
        path = path[idx + 3 ..];
    }
    if (std.mem.indexOf(u8, path, "@")) |idx| {
        path = path[idx + 1 ..];
    }
    if (std.mem.endsWith(u8, path, ".git")) {
        path = path[0 .. path.len - 4];
    }
    while (std.mem.endsWith(u8, path, "/")) {
        path = path[0 .. path.len - 1];
    }
    if (std.mem.indexOf(u8, path, "/")) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

test "BareCloner init" {
    const cloner = BareCloner.init(std.testing.allocator);
    try std.testing.expect(cloner.allocator == std.testing.allocator);
}

test "BareCloner clone method exists" {
    var cloner = BareCloner.init(std.testing.allocator);
    try cloner.clone("https://github.com/user/repo.git", "/tmp/repo");
    try std.testing.expect(true);
}

test "BareCloner cloneWithDepth method exists" {
    var cloner = BareCloner.init(std.testing.allocator);
    try cloner.cloneWithDepth("https://github.com/user/repo.git", "/tmp/repo", 50);
    try std.testing.expect(true);
}

test "normalizeClonePath with .git suffix" {
    const path = normalizeClonePath("https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("https://github.com/user/repo", path);
}

test "normalizeClonePath without .git suffix" {
    const path = normalizeClonePath("https://github.com/user/repo");
    try std.testing.expectEqualStrings("https://github.com/user/repo", path);
}

test "getRepoNameFromUrl simple" {
    const name = getRepoNameFromUrl("https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("repo", name);
}

test "getRepoNameFromUrl with ssh" {
    const name = getRepoNameFromUrl("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqualStrings("repo", name);
}
