//! Branch Upstream - Upstream tracking configuration
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const Io = std.Io;

pub const UpstreamOptions = struct {
    force: bool = false,
    track: bool = true,
    set_upstream: ?[]const u8 = null,
};

pub const UpstreamResult = struct {
    branch_name: []const u8,
    upstream_name: ?[]const u8,
    was_updated: bool,
};

pub const BranchUpstream = struct {
    allocator: std.mem.Allocator,
    io: Io,
    ref_store: *RefStore,
    options: UpstreamOptions,
    tracking: std.array_hash_map.String([]const u8),
    git_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: UpstreamOptions) BranchUpstream {
        return .{
            .allocator = allocator,
            .io = io,
            .ref_store = ref_store,
            .options = options,
            .tracking = std.array_hash_map.String([]const u8).empty,
            .git_path = ".git",
        };
    }

    pub fn deinit(self: *BranchUpstream) void {
        var it = self.tracking.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.tracking.deinit(self.allocator);
    }

    pub fn setUpstream(self: *BranchUpstream, branch: []const u8, upstream: []const u8) !UpstreamResult {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        const existing = self.ref_store.read(branch_ref) catch {
            return UpstreamResult{
                .branch_name = branch,
                .upstream_name = upstream,
                .was_updated = false,
            };
        };

        if (!existing.isDirect()) {
            return UpstreamResult{
                .branch_name = branch,
                .upstream_name = upstream,
                .was_updated = false,
            };
        }

        const upstream_ref = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{upstream});

        _ = self.tracking.put(self.allocator, branch_ref, upstream_ref) catch {
            return UpstreamResult{
                .branch_name = branch,
                .upstream_name = upstream,
                .was_updated = false,
            };
        };

        self.persistTracking() catch {};

        return UpstreamResult{
            .branch_name = branch,
            .upstream_name = upstream,
            .was_updated = true,
        };
    }

    pub fn getUpstream(self: *BranchUpstream, branch: []const u8) !?[]const u8 {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        if (self.tracking.getEntry(branch_ref)) |entry| {
            return try self.allocator.dupe(u8, entry.value_ptr.*);
        }

        self.loadTracking() catch {};
        if (self.tracking.getEntry(branch_ref)) |entry| {
            return try self.allocator.dupe(u8, entry.value_ptr.*);
        }
        return null;
    }

    pub fn unsetUpstream(self: *BranchUpstream, branch: []const u8) !UpstreamResult {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        if (!self.tracking.contains(branch_ref)) {
            return UpstreamResult{
                .branch_name = branch,
                .upstream_name = null,
                .was_updated = false,
            };
        }

        const removed_val = self.tracking.get(branch_ref);
        if (removed_val) |v| {
            self.allocator.free(v);
        }
        _ = self.tracking.swapRemove(branch_ref);

        self.persistTracking() catch {};

        return UpstreamResult{
            .branch_name = branch,
            .upstream_name = null,
            .was_updated = true,
        };
    }

    fn persistTracking(self: *BranchUpstream) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return;
        defer git_dir.close(self.io);

        _ = git_dir.createDir(self.io, "info", @enumFromInt(0o755)) catch {};

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        var it = self.tracking.iterator();
        while (it.next()) |entry| {
            try buf.appendSlice(self.allocator, entry.key_ptr.*);
            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, entry.value_ptr.*);
            try buf.append(self.allocator, '\n');
        }

        const data = try buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(data);
        git_dir.writeFile(self.io, .{ .sub_path = "info/upstream-tracking", .data = data }) catch {};
    }

    fn loadTracking(self: *BranchUpstream) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, self.git_path, .{}) catch return;
        defer git_dir.close(self.io);

        const content = git_dir.readFileAlloc(self.io, "info/upstream-tracking", self.allocator, .limited(64 * 1024)) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            const space_idx = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue;
            const branch_ref = trimmed[0..space_idx];
            const upstream_ref = trimmed[space_idx + 1 ..];
            if (branch_ref.len == 0 or upstream_ref.len == 0) continue;

            const owned_branch = self.allocator.dupe(u8, branch_ref) catch continue;
            const owned_upstream = self.allocator.dupe(u8, upstream_ref) catch {
                self.allocator.free(owned_branch);
                continue;
            };
            _ = self.tracking.put(self.allocator, owned_branch, owned_upstream) catch {
                self.allocator.free(owned_branch);
                self.allocator.free(owned_upstream);
            };
        }
    }

    pub fn getMergeConfig(self: *BranchUpstream, branch: []const u8) !?struct { remote: []const u8, branch: []const u8 } {
        const upstream = try self.getUpstream(branch);
        const upstream_val = upstream orelse return null;

        var parts = std.mem.tokenizeAny(u8, upstream_val, "/");
        const remote_name = parts.next() orelse return null;
        const remote_branch = parts.rest();

        if (remote_branch.len == 0) {
            return null;
        }

        return .{
            .remote = remote_name,
            .branch = remote_branch,
        };
    }
};

test "UpstreamOptions default values" {
    const options = UpstreamOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.track == true);
    try std.testing.expect(options.set_upstream == null);
}

test "UpstreamResult structure" {
    const result = UpstreamResult{
        .branch_name = "feature",
        .upstream_name = "origin/feature",
        .was_updated = true,
    };

    try std.testing.expectEqualStrings("feature", result.branch_name);
    try std.testing.expectEqualStrings("origin/feature", result.upstream_name);
    try std.testing.expect(result.was_updated == true);
}

test "UpstreamResult null upstream" {
    const result = UpstreamResult{
        .branch_name = "feature",
        .upstream_name = null,
        .was_updated = false,
    };

    try std.testing.expect(result.upstream_name == null);
}

test "BranchUpstream init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = undefined,
        .odb = null,
    };
    const options = UpstreamOptions{};
    const upstream = BranchUpstream.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(upstream.options.force == false);
}

test "BranchUpstream init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = undefined,
        .odb = null,
    };
    var options = UpstreamOptions{};
    options.force = true;
    options.track = false;
    const upstream = BranchUpstream.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(upstream.options.force == true);
    try std.testing.expect(upstream.options.track == false);
}

test "BranchUpstream has setUpstream method" {
    const U = BranchUpstream;
    try std.testing.expect(@hasDecl(U, "setUpstream"));
}

test "BranchUpstream has getUpstream method" {
    const U = BranchUpstream;
    try std.testing.expect(@hasDecl(U, "getUpstream"));
}

test "BranchUpstream has unsetUpstream method" {
    const U = BranchUpstream;
    try std.testing.expect(@hasDecl(U, "unsetUpstream"));
}

test "BranchUpstream has getMergeConfig method" {
    const U = BranchUpstream;
    try std.testing.expect(@hasDecl(U, "getMergeConfig"));
}
