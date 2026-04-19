//! Rebase Planner - Plan rebase operations
const std = @import("std");
const OID = @import("../object/oid.zig").OID;

pub const RebasePlan = struct {
    upstream: OID,
    branch: OID,
    commits: []const OID,
    current: u32,
};

pub const PlannerOptions = struct {
    onto: ?OID = null,
    keep_empty: bool = false,
    allow_empty: bool = false,
};

pub const RebasePlanner = struct {
    allocator: std.mem.Allocator,
    options: PlannerOptions,

    pub fn init(allocator: std.mem.Allocator, options: PlannerOptions) RebasePlanner {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn plan(self: *RebasePlanner, upstream: OID, branch: OID) !RebasePlan {
        _ = self;
        _ = upstream;
        _ = branch;
        return RebasePlan{ .upstream = upstream, .branch = branch, .commits = &.{}, .current = 0 };
    }

    pub fn getNextCommit(self: *RebasePlanner, plan: *RebasePlan) ?OID {
        _ = self;
        if (plan.current >= plan.commits.len) return null;
        const oid = plan.commits[plan.current];
        plan.current += 1;
        return oid;
    }

    pub fn isComplete(self: *RebasePlanner, plan: *const RebasePlan) bool {
        _ = self;
        return plan.current >= plan.commits.len;
    }
};

test "PlannerOptions default values" {
    const options = PlannerOptions{};
    try std.testing.expect(options.onto == null);
    try std.testing.expect(options.keep_empty == false);
}

test "RebasePlan structure" {
    const plan = RebasePlan{ .upstream = undefined, .branch = undefined, .commits = &.{}, .current = 0 };
    try std.testing.expect(plan.current == 0);
}

test "RebasePlanner init" {
    const options = PlannerOptions{};
    const planner = RebasePlanner.init(std.testing.allocator, options);
    try std.testing.expect(planner.allocator == std.testing.allocator);
}

test "RebasePlanner init with options" {
    var options = PlannerOptions{};
    options.keep_empty = true;
    options.allow_empty = true;
    const planner = RebasePlanner.init(std.testing.allocator, options);
    try std.testing.expect(planner.options.keep_empty == true);
}

test "RebasePlanner plan method exists" {
    var planner = RebasePlanner.init(std.testing.allocator, .{});
    const plan = try planner.plan(undefined, undefined);
    try std.testing.expect(plan.current == 0);
}

test "RebasePlanner getNextCommit returns null on empty" {
    var planner = RebasePlanner.init(std.testing.allocator, .{});
    var plan = RebasePlan{ .upstream = undefined, .branch = undefined, .commits = &.{}, .current = 0 };
    const next = planner.getNextCommit(&plan);
    try std.testing.expect(next == null);
}

test "RebasePlanner isComplete on empty plan" {
    var planner = RebasePlanner.init(std.testing.allocator, .{});
    const plan = RebasePlan{ .upstream = undefined, .branch = undefined, .commits = &.{}, .current = 0 };
    const complete = planner.isComplete(&plan);
    try std.testing.expect(complete == true);
}