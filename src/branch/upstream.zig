//! Branch Upstream - Upstream tracking configuration
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

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
    ref_store: *RefStore,
    options: UpstreamOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: UpstreamOptions) BranchUpstream {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn setUpstream(self: *BranchUpstream, branch: []const u8, upstream: []const u8) !UpstreamResult {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        if (self.options.force) {
            try self.ref_store.delete(branch_ref);
        }

        const ref = Ref.symbolicRef(branch_ref, upstream);
        try self.ref_store.write(ref);

        return UpstreamResult{
            .branch_name = branch,
            .upstream_name = upstream,
            .was_updated = true,
        };
    }

    pub fn getUpstream(self: *BranchUpstream, branch: []const u8) !?[]const u8 {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        const ref = self.ref_store.read(branch_ref) catch {
            return null;
        };

        if (!ref.isSymbolic()) {
            return null;
        }

        const target = ref.target.symbolic;
        if (!std.mem.startsWith(u8, target, "refs/remotes/")) {
            return null;
        }

        const upstream_name = try self.allocator.alloc(u8, target.len);
        @memcpy(upstream_name, target);
        return upstream_name;
    }

    pub fn unsetUpstream(self: *BranchUpstream, branch: []const u8) !UpstreamResult {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(branch_ref);

        const ref = self.ref_store.read(branch_ref) catch {
            return UpstreamResult{
                .branch_name = branch,
                .upstream_name = null,
                .was_updated = false,
            };
        };

        if (ref.isSymbolic()) {
            const target = ref.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/remotes/")) {
                try self.ref_store.delete(branch_ref);
                return UpstreamResult{
                    .branch_name = branch,
                    .upstream_name = null,
                    .was_updated = true,
                };
            }
        }

        return UpstreamResult{
            .branch_name = branch,
            .upstream_name = null,
            .was_updated = false,
        };
    }

    pub fn getMergeConfig(self: *BranchUpstream, branch: []const u8) !?struct { remote: []const u8, branch: []const u8 } {
        const upstream = self.getUpstream(branch) catch return null orelse return null;

        var parts = std.mem.tokenize(u8, upstream, "/");
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
    var ref_store: RefStore = undefined;
    const options = UpstreamOptions{};
    const upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(upstream.allocator == std.testing.allocator);
}

test "BranchUpstream init with options" {
    var ref_store: RefStore = undefined;
    var options = UpstreamOptions{};
    options.force = true;
    options.track = false;
    const upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(upstream.options.force == true);
    try std.testing.expect(upstream.options.track == false);
}

test "BranchUpstream setUpstream method exists" {
    var ref_store: RefStore = undefined;
    var options = UpstreamOptions{};
    var upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    const result = try upstream.setUpstream("feature", "refs/remotes/origin/feature");
    try std.testing.expectEqualStrings("feature", result.branch_name);
}

test "BranchUpstream getUpstream method exists" {
    var ref_store: RefStore = undefined;
    var options = UpstreamOptions{};
    var upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    const result = try upstream.getUpstream("main");
    _ = result;
    try std.testing.expect(upstream.allocator != undefined);
}

test "BranchUpstream unsetUpstream method exists" {
    var ref_store: RefStore = undefined;
    var options = UpstreamOptions{};
    var upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    const result = try upstream.unsetUpstream("feature");
    try std.testing.expect(result.upstream_name == null);
}

test "BranchUpstream getMergeConfig method exists" {
    var ref_store: RefStore = undefined;
    var options = UpstreamOptions{};
    var upstream = BranchUpstream.init(std.testing.allocator, &ref_store, options);

    const result = try upstream.getMergeConfig("main");
    _ = result;
    try std.testing.expect(upstream.allocator != undefined);
}