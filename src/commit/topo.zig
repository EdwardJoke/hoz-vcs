//! Commit Topological Sort - Sort commits in dependency order
//!
//! Provides topological sorting of commits using generations and
//! commit time for tiebreaking.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const graph_mod = @import("graph.zig");

pub const TopoSortConfig = struct {
    reverse: bool = false,
    use_generation: bool = true,
    use_date: bool = true,
    date_order: TopoDateOrder = .author,
};

pub const TopoDateOrder = enum {
    author,
    committer,
};

pub const TopoSortStats = struct {
    commits_sorted: u64 = 0,
    sort_time_ms: u64 = 0,
};

pub const TopoSort = struct {
    allocator: std.mem.Allocator,
    config: TopoSortConfig,
    graph: *graph_mod.CommitGraph,
    sorted: []oid_mod.OID,
    stats: TopoSortStats,

    pub fn init(allocator: std.mem.Allocator, graph: *graph_mod.CommitGraph, config: TopoSortConfig) TopoSort {
        return .{
            .allocator = allocator,
            .config = config,
            .graph = graph,
            .sorted = &.{},
            .stats = .{},
        };
    }

    pub fn deinit(self: *TopoSort) void {
        self.allocator.free(self.sorted);
    }

    pub fn sort(self: *TopoSort) !void {
        if (self.sorted.len > 0) {
            self.allocator.free(self.sorted);
        }

        const count = self.graph.commitCount();
        self.sorted = try self.allocator.alloc(oid_mod.OID, count);
        errdefer self.allocator.free(self.sorted);

        var visited = std.AutoArrayHashMap(oid_mod.OID, void).init(self.allocator);
        defer visited.deinit();

        var index: usize = 0;

        for (self.graph.getRoots()) |root| {
            try self.visit(root, &visited, &index);
        }

        if (self.config.reverse) {
            std.mem.reverse(oid_mod.OID, self.sorted);
        }

        self.stats.commits_sorted = @intCast(index);
    }

    fn visit(self: *TopoSort, oid: oid_mod.OID, visited: *std.AutoArrayHashMap(oid_mod.OID, void), index: *usize) !void {
        if (visited.contains(oid)) {
            return;
        }
        try visited.put(oid, {});

        for (self.graph.getParents(oid)) |parent| {
            try self.visit(parent, visited, index);
        }

        if (index.* < self.sorted.len) {
            self.sorted[index.*] = oid;
            index.* += 1;
        }
    }

    pub fn sortWithParentsFirst(self: *TopoSort) !void {
        if (self.sorted.len > 0) {
            self.allocator.free(self.sorted);
        }

        const count = self.graph.commitCount();
        self.sorted = try self.allocator.alloc(oid_mod.OID, count);
        errdefer self.allocator.free(self.sorted);

        var visited = std.AutoArrayHashMap(oid_mod.OID, void).init(self.allocator);
        defer visited.deinit();

        var index: usize = 0;

        for (self.graph.getRoots()) |root| {
            try self.visitParentsFirst(root, &visited, &index);
        }

        if (self.config.reverse) {
            std.mem.reverse(oid_mod.OID, self.sorted);
        }

        self.stats.commits_sorted = @intCast(index);
    }

    fn visitParentsFirst(self: *TopoSort, oid: oid_mod.OID, visited: *std.AutoArrayHashMap(oid_mod.OID, void), index: *usize) !void {
        if (visited.contains(oid)) {
            return;
        }

        for (self.graph.getParents(oid)) |parent| {
            try self.visitParentsFirst(parent, visited, index);
        }

        try visited.put(oid, {});
        if (index.* < self.sorted.len) {
            self.sorted[index.*] = oid;
            index.* += 1;
        }
    }

    pub fn getSorted(self: *TopoSort) []const oid_mod.OID {
        return self.sorted;
    }

    pub fn getStats(self: *const TopoSort) TopoSortStats {
        return self.stats;
    }
};

pub fn topoSortCommits(allocator: std.mem.Allocator, commits: []const oid_mod.OID, graph: *graph_mod.CommitGraph) ![]const oid_mod.OID {
    var sorter = TopoSort.init(allocator, graph, .{});
    defer sorter.deinit();

    for (commits) |oid| {
        if (!graph.hasCommit(oid)) {
            try graph.addCommit(oid, &.{});
        }
    }

    try sorter.sort();
    return sorter.getSorted();
}

pub fn topoSortByGeneration(allocator: std.mem.Allocator, graph: *graph_mod.CommitGraph) ![]const oid_mod.OID {
    try graph.computeGenerations();

    var sorter = TopoSort.init(allocator, graph, .{ .use_generation = true });
    defer sorter.deinit();

    try sorter.sort();

    const sorted = sorter.getSorted();
    std.mem.sort(oid_mod.OID, sorted, struct {
        fn less(_: void, a: oid_mod.OID, b: oid_mod.OID, ctx: *graph_mod.CommitGraph) bool {
            const gen_a = ctx.getCommit(a).?.generation;
            const gen_b = ctx.getCommit(b).?.generation;
            if (gen_a != gen_b) {
                return gen_a > gen_b;
            }
            return std.mem.lessThan(u8, &a.bytes, &b.bytes);
        }
    }.less, graph);

    return sorted;
}

test "TopoSort init" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const sorter = TopoSort.init(std.testing.allocator, &graph, .{});
    try std.testing.expect(!sorter.config.reverse);
}

test "TopoSort sort empty" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    var sorter = TopoSort.init(std.testing.allocator, &graph, .{});
    defer sorter.deinit();

    try sorter.sort();
    try std.testing.expectEqual(@as(usize, 0), sorter.sorted.len);
}

test "TopoSort sort single" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid = oid_mod.OID.zero();
    try graph.addCommit(oid, &.{});

    var sorter = TopoSort.init(std.testing.allocator, &graph, .{});
    defer sorter.deinit();

    try sorter.sort();

    try std.testing.expectEqual(@as(usize, 1), sorter.sorted.len);
}

test "TopoSort sort with parents" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});
    try graph.addCommit(oid3, &.{oid2});

    var sorter = TopoSort.init(std.testing.allocator, &graph, .{});
    defer sorter.deinit();

    try sorter.sort();

    try std.testing.expectEqual(@as(usize, 3), sorter.sorted.len);
    try std.testing.expect(graph.isAncestor(oid1, oid3));
}

test "TopoSort reverse" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});

    var sorter = TopoSort.init(std.testing.allocator, &graph, .{ .reverse = true });
    defer sorter.deinit();

    try sorter.sort();

    try std.testing.expectEqual(@as(usize, 2), sorter.sorted.len);
}

test "TopoSort getStats" {
    var graph = graph_mod.CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid = oid_mod.OID.zero();
    try graph.addCommit(oid, &.{});

    var sorter = TopoSort.init(std.testing.allocator, &graph, .{});
    defer sorter.deinit();

    try sorter.sort();

    const stats = sorter.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.commits_sorted);
}
