//! Rebase Planner - Plan rebase operations
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;

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
    autosquash: bool = false,
    exec: ?[]const u8 = null,
    root: bool = false,
    update_refs: bool = false,
};

pub const RebasePlanner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: PlannerOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: PlannerOptions) RebasePlanner {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn plan(self: *RebasePlanner, upstream: OID, branch: OID) !RebasePlan {
        const target_upstream = self.options.onto orelse upstream;

        var commits = std.ArrayList(OID).initCapacity(self.allocator, 16) catch return error.OutOfMemory;
        errdefer commits.deinit(self.allocator);

        if (self.options.root) {
            try self.collectRootCommits(&commits, branch, target_upstream);
        } else {
            try self.collectRebaseCommits(&commits, branch, upstream);
        }

        if (!self.options.keep_empty) {
            try self.filterEmptyCommits(&commits);
        }

        if (self.options.autosquash) {
            try self.groupSquashCommits(&commits);
        }

        const commits_slice = try commits.toOwnedSlice(self.allocator);
        return RebasePlan{
            .upstream = target_upstream,
            .branch = branch,
            .commits = commits_slice,
            .current = 0,
        };
    }

    fn collectRebaseCommits(self: *RebasePlanner, commits: *std.ArrayList(OID), branch: OID, upstream: OID) !void {
        var visited = std.AutoHashMap(OID, void).init(self.allocator);
        defer visited.deinit();

        var to_visit = std.ArrayList(OID).initCapacity(self.allocator, 16) catch return;
        defer to_visit.deinit(self.allocator);

        try to_visit.append(self.allocator, branch);
        try visited.put(branch, {});

        while (to_visit.pop()) |current_oid| {
            if (current_oid.eql(upstream)) continue;

            const commit_data = self.readCommitData(current_oid) catch {
                continue;
            };
            defer self.allocator.free(commit_data);

            const commit = Commit.parse(self.allocator, commit_data) catch {
                continue;
            };

            try commits.append(self.allocator, current_oid);

            for (commit.parents) |parent_oid| {
                if (!visited.contains(parent_oid)) {
                    try visited.put(parent_oid, {});
                    try to_visit.append(self.allocator, parent_oid);
                }
            }
        }
    }

    fn collectRootCommits(self: *RebasePlanner, commits: *std.ArrayList(OID), branch: OID, onto: OID) !void {
        var visited = std.AutoHashMap(OID, void).init(self.allocator);
        defer visited.deinit();

        var to_visit = std.ArrayList(OID).initCapacity(self.allocator, 16) catch return;
        defer to_visit.deinit(self.allocator);

        try to_visit.append(self.allocator, branch);
        try visited.put(branch, {});

        while (to_visit.pop()) |current_oid| {
            if (current_oid.eql(onto)) continue;

            const commit_data = self.readCommitData(current_oid) catch {
                continue;
            };
            defer self.allocator.free(commit_data);

            const commit = Commit.parse(self.allocator, commit_data) catch {
                continue;
            };

            try commits.append(self.allocator, current_oid);

            for (commit.parents) |parent_oid| {
                if (!visited.contains(parent_oid)) {
                    try visited.put(parent_oid, {});
                    try to_visit.append(self.allocator, parent_oid);
                }
            }
        }
    }

    fn filterEmptyCommits(self: *RebasePlanner, commits: *std.ArrayList(OID)) !void {
        var filtered = std.ArrayList(OID).initCapacity(self.allocator, 16) catch return;
        defer filtered.deinit(self.allocator);

        for (commits.items) |oid| {
            const commit_data = self.readCommitData(oid) catch {
                try filtered.append(self.allocator, oid);
                continue;
            };
            defer self.allocator.free(commit_data);

            const commit = Commit.parse(self.allocator, commit_data) catch {
                try filtered.append(self.allocator, oid);
                continue;
            };

            if (commit.message.len > 0) {
                try filtered.append(self.allocator, oid);
            }
        }

        commits.deinit(self.allocator);
        commits.* = filtered;
    }

    fn groupSquashCommits(self: *RebasePlanner, commits: *std.ArrayList(OID)) !void {
        _ = self;
        _ = commits;
    }

    fn readCommitData(self: *RebasePlanner, oid: OID) ![]const u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        return self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(65536)) catch {
            return error.ObjectNotFound;
        };
    }

    pub fn getNextCommit(self: *RebasePlanner, rebase_plan: *RebasePlan) ?OID {
        _ = self;
        if (rebase_plan.current >= rebase_plan.commits.len) return null;
        const oid = rebase_plan.commits[rebase_plan.current];
        rebase_plan.current += 1;
        return oid;
    }

    pub fn isComplete(self: *RebasePlanner, rebase_plan: *const RebasePlan) bool {
        _ = self;
        return rebase_plan.current >= rebase_plan.commits.len;
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
    const planner = RebasePlanner.init(std.testing.allocator, undefined, undefined, options);
    try std.testing.expect(planner.allocator == std.testing.allocator);
}

test "RebasePlanner init with options" {
    var options = PlannerOptions{};
    options.keep_empty = true;
    options.allow_empty = true;
    const planner = RebasePlanner.init(std.testing.allocator, undefined, undefined, options);
    try std.testing.expect(planner.options.keep_empty == true);
}

test "RebasePlanner plan method exists" {
    var planner = RebasePlanner.init(std.testing.allocator, undefined, undefined, .{});
    const plan = try planner.plan(undefined, undefined);
    try std.testing.expect(plan.current == 0);
}

test "RebasePlanner getNextCommit returns null on empty" {
    var planner = RebasePlanner.init(std.testing.allocator, undefined, undefined, .{});
    var plan = RebasePlan{ .upstream = undefined, .branch = undefined, .commits = &.{}, .current = 0 };
    const next = planner.getNextCommit(&plan);
    try std.testing.expect(next == null);
}

test "RebasePlanner isComplete on empty plan" {
    var planner = RebasePlanner.init(std.testing.allocator, undefined, undefined, .{});
    const plan = RebasePlan{ .upstream = undefined, .branch = undefined, .commits = &.{}, .current = 0 };
    const complete = planner.isComplete(&plan);
    try std.testing.expect(complete == true);
}
