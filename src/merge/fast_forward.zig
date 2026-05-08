//! Merge Fast-Forward - Fast-forward detection and handling
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const commit = @import("../commit/commit.zig");
const mock = @import("../testing/mock.zig");

pub const FastForwardResult = struct {
    can_ff: bool,
    ff_target: ?OID,
    commits_moved: u32,
};

pub const FastForwardChecker = struct {
    allocator: std.mem.Allocator,
    getCommit: *const fn (oid: OID) ?*const commit.Commit,

    pub fn init(allocator: std.mem.Allocator, getCommit: *const fn (oid: OID) ?*const commit.Commit) FastForwardChecker {
        return .{ .allocator = allocator, .getCommit = getCommit };
    }

    pub fn check(self: *FastForwardChecker, ours: OID, theirs: OID) !FastForwardResult {
        const is_ancestor = self.isAncestor(ours, theirs);
        if (is_ancestor) {
            const distance = self.countCommitsBetween(ours, theirs);
            return FastForwardResult{ .can_ff = true, .ff_target = theirs, .commits_moved = distance };
        }
        return FastForwardResult{ .can_ff = false, .ff_target = null, .commits_moved = 0 };
    }

    pub fn canFastForward(self: *FastForwardChecker, ours: OID, theirs: OID) bool {
        return self.isAncestor(ours, theirs);
    }

    pub fn getMergeBase(self: *FastForwardChecker, ours: OID, theirs: OID) ?OID {
        var ancestors_of_theirs = std.AutoHashMap(OID, void).init(self.allocator);
        defer ancestors_of_theirs.deinit();

        var current: OID = theirs;
        while (self.getCommit(current)) |c| {
            if (ancestors_of_theirs.contains(current)) break;
            ancestors_of_theirs.put(current, {}) catch break;
            if (c.parents.len == 0) break;
            current = c.parents[0];
        }

        current = ours;
        while (self.getCommit(current)) |c| {
            if (ancestors_of_theirs.contains(current)) {
                return current;
            }
            if (c.parents.len == 0) break;
            current = c.parents[0];
        }

        return null;
    }

    fn isAncestor(self: *FastForwardChecker, ancestor_oid: OID, descendant_oid: OID) bool {
        var visited = std.AutoHashMap(OID, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(OID).init(self.allocator);
        defer queue.deinit();
        queue.append(descendant_oid) catch return false;

        while (queue.pop()) |current| {
            if (current.eql(ancestor_oid)) {
                return true;
            }
            if (visited.contains(current)) {
                continue;
            }
            visited.put(current, {}) catch return false;

            if (self.getCommit(current)) |c| {
                for (c.parents) |parent| {
                    if (!visited.contains(parent)) {
                        queue.append(parent) catch return false;
                    }
                }
            }
        }

        return false;
    }

    fn countCommitsBetween(self: *FastForwardChecker, ours: OID, theirs: OID) u32 {
        var count: u32 = 0;
        var current = theirs;

        while (!current.eql(ours)) {
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
};

test "FastForwardResult structure" {
    const result = FastForwardResult{ .can_ff = true, .ff_target = null, .commits_moved = 5 };
    try std.testing.expect(result.can_ff == true);
    try std.testing.expect(result.commits_moved == 5);
}

test "FastForwardChecker detects linear history" {
    const base_oid = "1111111111111111111111111111111111111111";
    const mid_oid = "2222222222222222222222222222222222222222";
    const tip_oid = "3333333333333333333333333333333333333333";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    const mid_commit = mock.makeMockCommit(mid_oid, &.{base_oid});
    const tip_commit = mock.makeMockCommit(tip_oid, &.{mid_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit.Commit {
            const o1 = OID.fromHex(base_oid) catch return null;
            const o2 = OID.fromHex(mid_oid) catch return null;
            const o3 = OID.fromHex(tip_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &o1.bytes)) return @constCast(&base_commit);
            if (std.mem.eql(u8, &oid.bytes, &o2.bytes)) return @constCast(&mid_commit);
            if (std.mem.eql(u8, &oid.bytes, &o3.bytes)) return @constCast(&tip_commit);
            return null;
        }
    };

    const ours = OID.fromHex(base_oid) catch unreachable;
    const theirs = OID.fromHex(tip_oid) catch unreachable;
    var checker = FastForwardChecker.init(std.testing.allocator, MockStore.get);

    const result = try checker.check(ours, theirs);
    try std.testing.expect(result.can_ff == true);
    try std.testing.expect(result.commits_moved == 2);
    try std.testing.expect(result.ff_target.?.eql(theirs));
}

test "FastForwardChecker rejects divergent history" {
    const base_oid = "1111111111111111111111111111111111111111";
    const left_oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const right_oid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    const left_commit = mock.makeMockCommit(left_oid, &.{base_oid});
    const right_commit = mock.makeMockCommit(right_oid, &.{base_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit.Commit {
            const o1 = OID.fromHex(base_oid) catch return null;
            const o2 = OID.fromHex(left_oid) catch return null;
            const o3 = OID.fromHex(right_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &o1.bytes)) return @constCast(&base_commit);
            if (std.mem.eql(u8, &oid.bytes, &o2.bytes)) return @constCast(&left_commit);
            if (std.mem.eql(u8, &oid.bytes, &o3.bytes)) return @constCast(&right_commit);
            return null;
        }
    };

    const ours = OID.fromHex(left_oid) catch unreachable;
    const theirs = OID.fromHex(right_oid) catch unreachable;
    var checker = FastForwardChecker.init(std.testing.allocator, MockStore.get);

    const result = try checker.check(ours, theirs);
    try std.testing.expect(result.can_ff == false);
    try std.testing.expect(result.commits_moved == 0);
}

test "FastForwardChecker up-to-date returns zero moves" {
    const oid_str = "1111111111111111111111111111111111111111";
    const solo_commit = mock.makeMockCommit(oid_str, &.{});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit.Commit {
            const target = OID.fromHex(oid_str) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &target.bytes)) return @constCast(&solo_commit);
            return null;
        }
    };

    const same = OID.fromHex(oid_str) catch unreachable;
    var checker = FastForwardChecker.init(std.testing.allocator, MockStore.get);

    const result = try checker.check(same, same);
    try std.testing.expect(result.can_ff == true);
    try std.testing.expect(result.commits_moved == 0);
}

test "FastForwardChecker getMergeBase finds common ancestor" {
    const base_oid = "1111111111111111111111111111111111111111";
    const left_oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const right_oid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    const base_commit = mock.makeMockCommit(base_oid, &.{});
    _ = mock.makeMockCommit(left_oid, &.{base_oid});
    _ = mock.makeMockCommit(right_oid, &.{base_oid});

    const MockStore = struct {
        fn get(oid: OID) ?*const commit.Commit {
            const base = OID.fromHex(base_oid) catch return null;
            if (std.mem.eql(u8, &oid.bytes, &base.bytes)) return @constCast(&base_commit);
            return null;
        }
    };

    const ours = OID.fromHex(left_oid) catch unreachable;
    const theirs = OID.fromHex(right_oid) catch unreachable;
    var checker = FastForwardChecker.init(std.testing.allocator, MockStore.get);

    const base = checker.getMergeBase(ours, theirs);
    try std.testing.expect(base != null);
    try std.testing.expect(base.?.eql(OID.fromHex(base_oid) catch unreachable));
}
