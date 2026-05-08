//! Merge Analyze - Analyze branches for merge readiness
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const commit_mod = @import("../commit/commit.zig");
const mock = @import("../testing/mock.zig");

pub const MergeAnalysis = struct {
    is_fast_forward: bool,
    is_up_to_date: bool,
    is_normal: bool,
    can_ff: bool,
};

pub const AnalysisResult = struct {
    analysis: MergeAnalysis,
    common_ancestor: ?OID,
    commits_ahead: u32,
    commits_behind: u32,
};

pub const MergeBaseFinder = struct {
    allocator: std.mem.Allocator,
    getCommit: *const fn (oid: OID) ?*const commit_mod.Commit,

    pub fn init(allocator: std.mem.Allocator, getCommit: *const fn (oid: OID) ?*const commit_mod.Commit) MergeBaseFinder {
        return .{ .allocator = allocator, .getCommit = getCommit };
    }

    pub fn findMergeBase(self: *MergeBaseFinder, commit_a: OID, commit_b: OID) !?OID {
        const ancestors_a = try self.getAncestors(commit_a);
        defer self.allocator.free(ancestors_a);
        const ancestors_b = try self.getAncestors(commit_b);
        defer self.allocator.free(ancestors_b);

        var visited = std.AutoHashMap(OID, void).init(self.allocator);
        defer visited.deinit();

        for (ancestors_a) |ancestor| {
            try visited.put(ancestor, {});
        }

        for (ancestors_b) |ancestor| {
            if (visited.contains(ancestor)) {
                return ancestor;
            }
        }

        return null;
    }

    pub fn findRecursiveMergeBase(self: *MergeBaseFinder, commit_x: OID, commit_y: OID, commit_z: OID) !?OID {
        const base1 = try self.findMergeBase(commit_x, commit_y);
        if (base1 == null) return null;

        const base2 = try self.findMergeBase(base1.?, commit_z);
        if (base2 == null) return null;

        var current = base2.?;
        var iteration: u32 = 0;
        const max_iterations: u32 = 1000;

        while (iteration < max_iterations) : (iteration += 1) {
            const candidate1 = try self.findMergeBase(current, commit_x);
            const candidate2 = try self.findMergeBase(current, commit_y);

            if (candidate1 != null and self.oidsEqual(candidate1.?, candidate2.?)) {
                return candidate1;
            }

            if (candidate1) |c1| {
                current = c1;
            } else if (candidate2) |c2| {
                current = c2;
            } else {
                break;
            }
        }

        return base2;
    }

    fn getAncestors(self: *MergeBaseFinder, commit: OID) ![]OID {
        var ancestors = std.ArrayList(OID).init(self.allocator);
        errdefer ancestors.deinit();

        var current = commit;
        var visited = std.AutoHashMap(OID, void).init(self.allocator);
        defer visited.deinit();

        var iteration: u32 = 0;
        const max_iterations: u32 = 10000;

        while (iteration < max_iterations) : (iteration += 1) {
            if (visited.contains(current)) break;
            try visited.put(current, {});
            try ancestors.append(current);

            const parent = self.getCommitParent(current);
            if (parent == null) break;
            current = parent.?;
        }

        return ancestors.toOwnedSlice();
    }

    fn getCommitParent(self: *MergeBaseFinder, commit: OID) ?OID {
        if (self.getCommit(commit)) |c| {
            if (c.parents.len > 0) {
                return c.parents[0];
            }
        }
        return null;
    }

    fn oidsEqual(a: OID, b: OID) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const MergeAnalyzer = struct {
    allocator: std.mem.Allocator,
    getCommit: *const fn (oid: OID) ?*const commit_mod.Commit,

    pub fn init(allocator: std.mem.Allocator, getCommit: *const fn (oid: OID) ?*const commit_mod.Commit) MergeAnalyzer {
        return .{ .allocator = allocator, .getCommit = getCommit };
    }

    pub fn analyze(self: *MergeAnalyzer, ours: OID, theirs: OID) !AnalysisResult {
        var finder = MergeBaseFinder.init(self.allocator, self.getCommit);
        const merge_base = try finder.findMergeBase(ours, theirs);

        if (merge_base == null) {
            return AnalysisResult{
                .analysis = .{
                    .is_fast_forward = false,
                    .is_up_to_date = false,
                    .is_normal = true,
                    .can_ff = false,
                },
                .common_ancestor = null,
                .commits_ahead = 0,
                .commits_behind = 0,
            };
        }

        const ancestor = merge_base.?;
        const is_ff = self.oidsEqual(ancestor, ours);

        const ahead = self.countAncestorsBetween(ours, ancestor);
        const behind = self.countAncestorsBetween(theirs, ancestor);

        return AnalysisResult{
            .analysis = .{
                .is_fast_forward = is_ff,
                .is_up_to_date = self.oidsEqual(ours, theirs),
                .is_normal = !is_ff,
                .can_ff = merge_base != null,
            },
            .common_ancestor = merge_base,
            .commits_ahead = ahead,
            .commits_behind = behind,
        };
    }

    pub fn canMerge(self: *MergeAnalyzer, ours: OID, theirs: OID) bool {
        var finder = MergeBaseFinder.init(self.allocator, self.getCommit);
        const merge_base = finder.findMergeBase(ours, theirs) catch return false;
        return merge_base != null;
    }

    fn countAncestorsBetween(self: *MergeAnalyzer, descendant: OID, ancestor: OID) u32 {
        var count: u32 = 0;
        var current = descendant;

        while (!self.oidsEqual(current, ancestor)) {
            if (self.getCommit(current)) |c| {
                count += 1;
                if (c.parents.len == 0) break;
                current = c.parents[0];
            } else {
                break;
            }
        }

        return count;
    }

    fn oidsEqual(a: OID, b: OID) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

test "MergeAnalysis structure" {
    const analysis = MergeAnalysis{
        .is_fast_forward = true,
        .is_up_to_date = false,
        .is_normal = false,
        .can_ff = true,
    };

    try std.testing.expect(analysis.is_fast_forward == true);
    try std.testing.expect(analysis.can_ff == true);
}

test "AnalysisResult structure" {
    const result = AnalysisResult{
        .analysis = .{
            .is_fast_forward = false,
            .is_up_to_date = true,
            .is_normal = false,
            .can_ff = false,
        },
        .common_ancestor = null,
        .commits_ahead = 0,
        .commits_behind = 0,
    };

    try std.testing.expect(result.analysis.is_up_to_date == true);
}

test "MergeAnalyzer init" {
    const MockStore = struct {
        fn get(_: OID) ?*const commit_mod.Commit {
            return null;
        }
    };
    const analyzer = MergeAnalyzer.init(std.testing.allocator, MockStore.get);
    try std.testing.expect(analyzer.allocator == std.testing.allocator);
}

test "MergeAnalyzer detects fast-forward" {
    const base_oid = "1111111111111111111111111111111111111111";
    const tip_oid = "2222222222222222222222222222222222222222";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    const tip_commit = mock.makeMockCommit(tip_oid, &.{base_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit_mod.Commit {
            const o1 = OID.fromHex(base_oid) catch return null;
            const o2 = OID.fromHex(tip_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &o1.bytes)) return @constCast(&base_commit);
            if (std.mem.eql(u8, &oid.bytes, &o2.bytes)) return @constCast(&tip_commit);
            return null;
        }
    };

    const ours = OID.fromHex(base_oid) catch unreachable;
    const theirs = OID.fromHex(tip_oid) catch unreachable;
    var analyzer = MergeAnalyzer.init(std.testing.allocator, MockStore.get);

    const result = try analyzer.analyze(ours, theirs);
    try std.testing.expect(result.analysis.is_fast_forward == true);
    try std.testing.expect(result.analysis.can_ff == true);
    try std.testing.expect(result.commits_behind == 1);
}

test "MergeAnalyzer detects divergent branches" {
    const base_oid = "1111111111111111111111111111111111111111";
    const left_oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const right_oid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    _ = mock.makeMockCommit(left_oid, &.{base_oid});
    _ = mock.makeMockCommit(right_oid, &.{base_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit_mod.Commit {
            const o1 = OID.fromHex(base_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &o1.bytes)) return @constCast(&base_commit);
            return null;
        }
    };

    const ours = OID.fromHex(left_oid) catch unreachable;
    const theirs = OID.fromHex(right_oid) catch unreachable;
    var analyzer = MergeAnalyzer.init(std.testing.allocator, MockStore.get);

    const result = try analyzer.analyze(ours, theirs);
    try std.testing.expect(result.analysis.is_normal == true);
    try std.testing.expect(result.analysis.is_fast_forward == false);
    try std.testing.expect(result.common_ancestor != null);
}

test "MergeAnalyzer canMerge returns true for related branches" {
    const base_oid = "1111111111111111111111111111111111111111";
    const tip_oid = "2222222222222222222222222222222222222222";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    _ = mock.makeMockCommit(tip_oid, &.{base_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit_mod.Commit {
            const o1 = OID.fromHex(base_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &o1.bytes)) return @constCast(&base_commit);
            return null;
        }
    };

    const ours = OID.fromHex(base_oid) catch unreachable;
    const theirs = OID.fromHex(tip_oid) catch unreachable;
    var analyzer = MergeAnalyzer.init(std.testing.allocator, MockStore.get);

    const can = analyzer.canMerge(ours, theirs);
    try std.testing.expect(can == true);
}
