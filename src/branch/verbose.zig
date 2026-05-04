//! Branch Verbose - Verbose branch listing with tracking
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const Io = std.Io;
const compress_mod = @import("../compress/zlib.zig");

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
    oid: ?OID,
    is_current: bool,
    upstream_name: ?[]const u8,
    tracking: ?TrackingInfo,
};

pub const BranchVerbose = struct {
    allocator: std.mem.Allocator,
    io: Io,
    ref_store: *RefStore,
    options: VerboseOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: VerboseOptions) BranchVerbose {
        return .{
            .allocator = allocator,
            .io = io,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn listVerbose(self: *BranchVerbose) ![]const VerboseResult {
        var results = std.ArrayList(VerboseResult).empty;
        errdefer results.deinit(self.allocator);

        const head_target = self.getHeadTarget();
        const prefix = if (self.options.all) "" else "refs/heads/";
        const refs = self.ref_store.list(prefix) catch &.{};

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

            const oid: ?OID = if (ref.isDirect()) ref.target.direct else null;

            const result = VerboseResult{
                .name = branch_name,
                .oid = oid,
                .is_current = is_current,
                .upstream_name = upstream_name,
                .tracking = tracking,
            };

            try results.append(self.allocator, result);
        }

        return results.toOwnedSlice(self.allocator);
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

        const upstream_oid = self.ref_store.readResolved(target) catch return null;
        const branch_oid_resolved = self.ref_store.readResolved(branch_ref) catch return null;

        if (upstream_oid.eql(branch_oid_resolved)) {
            return TrackingInfo{
                .ahead = 0,
                .behind = 0,
                .is_gone = false,
                .last_commit = null,
            };
        }

        var branch_reachable = std.array_hash_map.String(void).empty;
        defer branch_reachable.deinit(self.allocator);
        _ = self.collectReachable(&branch_oid_resolved.toHex(), &branch_reachable) catch 0;

        var upstream_reachable = std.array_hash_map.String(void).empty;
        defer upstream_reachable.deinit(self.allocator);
        _ = self.collectReachable(&upstream_oid.toHex(), &upstream_reachable) catch 0;

        var ahead: u32 = 0;
        var behind: u32 = 0;

        var branch_it = branch_reachable.iterator();
        while (branch_it.next()) |entry| {
            if (!upstream_reachable.contains(entry.key_ptr.*)) {
                ahead += 1;
            }
        }

        var upstream_it = upstream_reachable.iterator();
        while (upstream_it.next()) |entry| {
            if (!branch_reachable.contains(entry.key_ptr.*)) {
                behind += 1;
            }
        }

        return TrackingInfo{
            .ahead = ahead,
            .behind = behind,
            .is_gone = false,
            .last_commit = null,
        };
    }

    fn collectReachable(self: *BranchVerbose, start_oid: []const u8, visited: *std.array_hash_map.String(void)) !u32 {
        if (start_oid.len < 40) return 0;
        if (visited.contains(start_oid)) return 0;

        visited.put(self.allocator, start_oid, {}) catch return 0;

        const parents = self.getParentOids(start_oid) catch &.{};
        defer {
            for (parents) |p| self.allocator.free(p);
            self.allocator.free(parents);
        }

        var count: u32 = 1;
        for (parents) |parent| {
            count += try self.collectReachable(parent, visited);
        }
        return count;
    }

    fn getParentOids(self: *BranchVerbose, oid_str: []const u8) ![][]const u8 {
        if (oid_str.len < 40) return &.{};

        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_str[0..2], oid_str[2..40] });
        defer self.allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(self.io, obj_path, .{}) catch return &.{};
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        const compressed = try reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(compressed);

        const data = compress_mod.Zlib.decompress(compressed, self.allocator) catch return &.{};
        defer self.allocator.free(data);

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, '\n');
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line["parent ".len..];
            if (parent_oid.len >= 40) {
                try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid[0..40]));
            }
        }

        return parents.toOwnedSlice(self.allocator);
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
            if (self.options.abbrev_oid and result.oid) |o| {
                const oid_str = &o.toHex();
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
        .oid = null,
        .is_current = true,
        .upstream_name = "origin/main",
        .tracking = null,
    };

    try std.testing.expectEqualStrings("main", result.name);
    try std.testing.expect(result.is_current == true);
}

test "BranchVerbose init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    const options = VerboseOptions{};
    const verbose = BranchVerbose.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(verbose.allocator == std.testing.allocator);
}

test "BranchVerbose init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    var options = VerboseOptions{};
    options.all = true;
    options.abbrev_length = 12;
    const verbose = BranchVerbose.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(verbose.options.all == true);
    try std.testing.expect(verbose.options.abbrev_length == 12);
}

test "BranchVerbose has listVerbose method" {
    const V = BranchVerbose;
    try std.testing.expect(@hasDecl(V, "listVerbose"));
}

test "BranchVerbose has getTrackingInfo method" {
    const V = BranchVerbose;
    try std.testing.expect(@hasDecl(V, "getTrackingInfo"));
}
