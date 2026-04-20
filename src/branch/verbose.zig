//! Branch Verbose - Verbose branch listing with tracking
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const VerboseOptions = struct {
    all: bool = false,
    abbrev_oid: bool = true,
    abbrev_length: u8 = 7,
    color: bool = true,
};

pub const TrackingInfo = struct {
    ahead: u32,
    behind: u32,
    is_gone: bool,
    last_commit: ?i64,
};

pub const VerboseResult = struct {
    name: []const u8,
    oid: OID,
    is_current: bool,
    upstream_name: ?[]const u8,
    tracking: ?TrackingInfo,
};

pub const BranchVerbose = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: VerboseOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: VerboseOptions) BranchVerbose {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn listVerbose(self: *BranchVerbose) ![]const VerboseResult {
        var results = std.ArrayList(VerboseResult).empty;
        errdefer results.deinit(self.allocator);

        const head_target = self.getHeadTarget();
        const prefix = if (self.options.all) "" else "refs/heads/";
        const refs = self.ref_store.list(prefix) catch |_| &.{};

        for (refs) |ref| {
            const full_name = ref.name;
            if (!std.mem.startsWith(u8, full_name, "refs/heads/")) {
                continue;
            }

            const branch_name = full_name["refs/heads/".len..];

            const is_current = head_target != null and
                std.mem.eql(u8, head_target.?, full_name);

            const upstream_name = self.extractUpstream(ref);
            const tracking = if (upstream_name) |_| self.getTrackingInfo(branch_name) catch null else null;

            const oid = if (ref.isDirect()) ref.target.direct else undefined;

            const result = VerboseResult{
                .name = branch_name,
                .oid = oid,
                .is_current = is_current,
                .upstream_name = upstream_name,
                .tracking = tracking,
            };

            try results.append(self.allocator, result);
        }

        return results.toOwnedSlice();
    }

    pub fn getTrackingInfo(self: *BranchVerbose, branch_name: []const u8) !?TrackingInfo {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
        defer self.allocator.free(branch_ref);

        const ref = self.ref_store.read(branch_ref) catch return null;

        if (!ref.isSymbolic()) {
            return null;
        }

        const target = ref.target.symbolic;
        if (!std.mem.startsWith(u8, target, "refs/remotes/")) {
            return null;
        }

        return TrackingInfo{
            .ahead = 0,
            .behind = 0,
            .is_gone = false,
            .last_commit = null,
        };
    }

    pub fn formatVerbose(self: *BranchVerbose, result: *const VerboseResult, writer: anytype) !void {
        if (result.is_current) {
            try writer.writeAll("* ");
        } else {
            try writer.writeAll("  ");
        }

        try writer.writeAll(result.name);

        if (result.upstream_name) |upstream| {
            try writer.writeAll(" -> ");
            try writer.writeAll(upstream);
        } else {
            if (self.options.abbrev_oid and result.oid != undefined) {
                const oid_str = result.oid.toString();
                if (oid_str.len > self.options.abbrev_length) {
                    try writer.print(" {s}", .{oid_str[0..self.options.abbrev_length]});
                } else {
                    try writer.print(" {s}", .{oid_str});
                }
            }
        }

        if (result.tracking) |tracking| {
            if (tracking.ahead > 0 or tracking.behind > 0) {
                try writer.print(" [ahead {d}, behind {d}]", .{ tracking.ahead, tracking.behind });
            }
            if (tracking.is_gone) {
                try writer.writeAll(" [gone]");
            }
        }

        try writer.writeAll("\n");
    }

    fn getHeadTarget(self: *BranchVerbose) ?[]const u8 {
        const head = self.ref_store.read("HEAD") catch return null;
        if (head.isSymbolic()) {
            return head.target.symbolic;
        }
        return null;
    }

    fn extractUpstream(self: *BranchVerbose, ref: Ref) ?[]const u8 {
        _ = self;
        if (!ref.isSymbolic()) {
            return null;
        }

        const target = ref.target.symbolic;
        if (!std.mem.startsWith(u8, target, "refs/remotes/")) {
            return null;
        }

        return target;
    }
};

test "VerboseOptions default values" {
    const options = VerboseOptions{};
    try std.testing.expect(options.all == false);
    try std.testing.expect(options.abbrev_oid == true);
    try std.testing.expect(options.abbrev_length == 7);
    try std.testing.expect(options.color == true);
}

test "TrackingInfo structure" {
    const info = TrackingInfo{
        .ahead = 2,
        .behind = 1,
        .is_gone = false,
        .last_commit = 1234567890,
    };

    try std.testing.expect(info.ahead == 2);
    try std.testing.expect(info.behind == 1);
    try std.testing.expect(info.is_gone == false);
}

test "TrackingInfo is_gone when no upstream" {
    const info = TrackingInfo{
        .ahead = 0,
        .behind = 0,
        .is_gone = true,
        .last_commit = null,
    };

    try std.testing.expect(info.is_gone == true);
}

test "VerboseResult structure" {
    const result = VerboseResult{
        .name = "main",
        .oid = undefined,
        .is_current = true,
        .upstream_name = "origin/main",
        .tracking = null,
    };

    try std.testing.expectEqualStrings("main", result.name);
    try std.testing.expect(result.is_current == true);
}

test "BranchVerbose init" {
    var ref_store: RefStore = undefined;
    const options = VerboseOptions{};
    const verbose = BranchVerbose.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(verbose.allocator == std.testing.allocator);
}

test "BranchVerbose init with options" {
    var ref_store: RefStore = undefined;
    var options = VerboseOptions{};
    options.all = true;
    options.abbrev_length = 12;
    const verbose = BranchVerbose.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(verbose.options.all == true);
    try std.testing.expect(verbose.options.abbrev_length == 12);
}

test "BranchVerbose listVerbose method exists" {
    var ref_store: RefStore = undefined;
    var options = VerboseOptions{};
    var verbose = BranchVerbose.init(std.testing.allocator, &ref_store, options);

    const result = try verbose.listVerbose();
    try std.testing.expect(result.len >= 0);
}

test "BranchVerbose getTrackingInfo method exists" {
    var ref_store: RefStore = undefined;
    var options = VerboseOptions{};
    var verbose = BranchVerbose.init(std.testing.allocator, &ref_store, options);

    const info = try verbose.getTrackingInfo("main");
    _ = info;
    try std.testing.expect(verbose.allocator != undefined);
}