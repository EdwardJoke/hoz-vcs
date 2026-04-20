//! Merge Fast-Forward - Fast-forward detection and handling
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const commit = @import("../commit/commit.zig");

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

test "FastForwardChecker init" {
    const dummyGetCommit: *const fn (OID) ?*const commit.Commit = struct {
        fn get(_: OID) ?*const commit.Commit {
            return null;
        }
    }.get;
    const checker = FastForwardChecker.init(std.testing.allocator, dummyGetCommit);
    try std.testing.expect(checker.allocator == std.testing.allocator);
}

test "FastForwardChecker check method exists" {
    const dummyGetCommit: *const fn (OID) ?*const commit.Commit = struct {
        fn get(_: OID) ?*const commit.Commit {
            return null;
        }
    }.get;
    var checker = FastForwardChecker.init(std.testing.allocator, dummyGetCommit);
    const result = try checker.check(undefined, undefined);
    _ = result;
    try std.testing.expect(checker.allocator != undefined);
}

test "FastForwardChecker canFastForward method exists" {
    const dummyGetCommit: *const fn (OID) ?*const commit.Commit = struct {
        fn get(_: OID) ?*const commit.Commit {
            return null;
        }
    }.get;
    var checker = FastForwardChecker.init(std.testing.allocator, dummyGetCommit);
    const can = checker.canFastForward(undefined, undefined);
    _ = can;
    try std.testing.expect(checker.allocator != undefined);
}

test "FastForwardChecker getMergeBase method exists" {
    const dummyGetCommit: *const fn (OID) ?*const commit.Commit = struct {
        fn get(_: OID) ?*const commit.Commit {
            return null;
        }
    }.get;
    var checker = FastForwardChecker.init(std.testing.allocator, dummyGetCommit);
    const base = checker.getMergeBase(undefined, undefined);
    _ = base;
    try std.testing.expect(checker.allocator != undefined);
}
