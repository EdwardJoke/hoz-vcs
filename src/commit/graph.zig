//! Commit Graph - Directed acyclic graph of commits
//!
//! Represents the commit history as a graph structure for efficient
//! traversal, ancestry queries, and topological operations.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const commit_object = @import("../object/commit.zig");

pub const CommitGraphConfig = struct {
    max_commits: usize = 100000,
    cache_ancestry: bool = true,
    incremental_build: bool = true,
};

pub const CommitGraphStats = struct {
    commit_count: u64 = 0,
    edge_count: u64 = 0,
    max_generation: u32 = 0,
    build_time_ms: u64 = 0,
};

pub const CommitNode = struct {
    oid: oid_mod.OID,
    parents: []const oid_mod.OID,
    generation: u32,
    generation_computed: bool,
};

pub const CommitGraph = struct {
    allocator: std.mem.Allocator,
    config: CommitGraphConfig,
    nodes: std.AutoArrayHashMap(oid_mod.OID, CommitNode),
    children_map: std.AutoArrayHashMap(oid_mod.OID, std.ArrayList(oid_mod.OID)),
    roots: std.ArrayList(oid_mod.OID),
    stats: CommitGraphStats,

    pub fn init(allocator: std.mem.Allocator, config: CommitGraphConfig) CommitGraph {
        return .{
            .allocator = allocator,
            .config = config,
            .nodes = std.AutoArrayHashMap(oid_mod.OID, CommitNode).init(allocator),
            .children_map = std.AutoArrayHashMap(oid_mod.OID, std.ArrayList(oid_mod.OID)).init(allocator),
            .roots = std.ArrayList(oid_mod.OID).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *CommitGraph) void {
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.parents);
        }
        self.nodes.deinit();

        var child_iter = self.children_map.iterator();
        while (child_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.children_map.deinit();
        self.roots.deinit();
    }

    pub fn addCommit(self: *CommitGraph, oid: oid_mod.OID, parents: []const oid_mod.OID) !void {
        if (self.nodes.getKey(oid)) |_| {
            return;
        }

        const parents_copy = try self.allocator.dupe(oid_mod.OID, parents);
        errdefer self.allocator.free(parents_copy);

        try self.nodes.put(oid, .{
            .oid = oid,
            .parents = parents_copy,
            .generation = 0,
            .generation_computed = false,
        });

        if (parents.len == 0) {
            try self.roots.append(oid);
        } else {
            for (parents) |parent| {
                var children = self.children_map.getOrPut(parent) catch continue;
                if (!children.found_existing) {
                    children.value_ptr.* = std.ArrayList(oid_mod.OID).init(self.allocator);
                }
                children.value_ptr.append(oid) catch continue;
            }
        }

        self.stats.commit_count += 1;
        self.stats.edge_count += parents.len;
    }

    pub fn getCommit(self: *CommitGraph, oid: oid_mod.OID) ?*const CommitNode {
        return self.nodes.get(oid);
    }

    pub fn hasCommit(self: *CommitGraph, oid: oid_mod.OID) bool {
        return self.nodes.contains(oid);
    }

    pub fn getParents(self: *CommitGraph, oid: oid_mod.OID) []const oid_mod.OID {
        if (self.nodes.get(oid)) |node| {
            return node.parents;
        }
        return &.{};
    }

    pub fn getChildren(self: *CommitGraph, oid: oid_mod.OID) []const oid_mod.OID {
        if (self.children_map.get(oid)) |children| {
            return children.items;
        }
        return &.{};
    }

    pub fn isAncestor(self: *CommitGraph, ancestor_oid: oid_mod.OID, descendant_oid: oid_mod.OID) bool {
        if (!self.nodes.contains(ancestor_oid) or !self.nodes.contains(descendant_oid)) {
            return false;
        }
        return self.isReachable(ancestor_oid, descendant_oid);
    }

    pub fn isReachable(self: *CommitGraph, from: oid_mod.OID, to: oid_mod.OID) bool {
        var visited = std.AutoArrayHashMap(oid_mod.OID, void).init(self.allocator);
        defer visited.deinit();
        visited.put(from, {}) catch return false;

        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();
        queue.append(from) catch return false;

        while (queue.popOrNull()) |current| {
            if (std.mem.eql(u8, &current.bytes, &to.bytes)) {
                return true;
            }
            for (self.getChildren(current)) |child| {
                if (!visited.contains(child)) {
                    visited.put(child, {}) catch return false;
                    queue.append(child) catch return false;
                }
            }
        }
        return false;
    }

    pub fn getAncestryPath(self: *CommitGraph, from: oid_mod.OID, to: oid_mod.OID) !?[]const oid_mod.OID {
        var visited = std.AutoArrayHashMap(oid_mod.OID, void).init(self.allocator);
        defer visited.deinit();
        visited.put(from, {}) catch return false;

        var parent_map = std.AutoArrayHashMap(oid_mod.OID, oid_mod.OID).init(self.allocator);
        defer parent_map.deinit();

        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();
        queue.append(from) catch return false;

        while (queue.popOrNull()) |current| {
            if (std.mem.eql(u8, &current.bytes, &to.bytes)) {
                var path = std.ArrayList(oid_mod.OID).init(self.allocator);
                errdefer path.deinit();

                var node = to;
                while (true) {
                    try path.append(node);
                    if (std.mem.eql(u8, &node.bytes, &from.bytes)) break;
                    node = parent_map.get(node) orelse break;
                }
                std.mem.reverse(oid_mod.OID, path.items);
                return path.toOwnedSlice();
            }
            for (self.getChildren(current)) |child| {
                if (!visited.contains(child)) {
                    visited.put(child, {}) catch return false;
                    parent_map.put(child, current) catch return false;
                    queue.append(child) catch return false;
                }
            }
        }
        return null;
    }

    pub fn computeGenerations(self: *CommitGraph) !void {
        for (self.roots.items) |root| {
            try self.computeGenerationRecursive(root, 0);
        }

        var max_gen: u32 = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.generation > max_gen) {
                max_gen = entry.value_ptr.generation;
            }
        }
        self.stats.max_generation = max_gen;
    }

    fn computeGenerationRecursive(self: *CommitGraph, oid: oid_mod.OID, gen: u32) !void {
        if (self.nodes.getEntry(oid)) |entry| {
            if (entry.value_ptr.generation_computed and entry.value_ptr.generation >= gen) {
                return;
            }
            entry.value_ptr.generation = gen;
            entry.value_ptr.generation_computed = true;
        }

        for (self.getChildren(oid)) |child| {
            try self.computeGenerationRecursive(child, gen + 1);
        }
    }

    pub fn getRoots(self: *CommitGraph) []const oid_mod.OID {
        return self.roots.items;
    }

    pub fn commitCount(self: *CommitGraph) usize {
        return self.nodes.count();
    }

    pub fn getStats(self: *const CommitGraph) CommitGraphStats {
        return self.stats;
    }
};

test "CommitGraph init" {
    const graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();
    try std.testing.expectEqual(@as(u64, 0), graph.stats.commit_count);
}

test "CommitGraph addCommit" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});

    try std.testing.expectEqual(@as(u64, 2), graph.stats.commit_count);
    try std.testing.expectEqual(@as(u64, 1), graph.stats.edge_count);
}

test "CommitGraph hasCommit" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid = oid_mod.OID.zero();
    try graph.addCommit(oid, &.{});

    try std.testing.expect(graph.hasCommit(oid));
    try std.testing.expect(!graph.hasCommit(oid_mod.OID.zero()));
}

test "CommitGraph getParents" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try graph.addCommit(oid2, &.{oid1});
    const parents = graph.getParents(oid2);

    try std.testing.expectEqual(@as(usize, 1), parents.len);
}

test "CommitGraph getChildren" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});

    const children = graph.getChildren(oid1);
    try std.testing.expectEqual(@as(usize, 1), children.len);
}

test "CommitGraph isAncestor" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});
    try graph.addCommit(oid3, &.{oid2});

    try std.testing.expect(graph.isAncestor(oid1, oid3));
    try std.testing.expect(!graph.isAncestor(oid3, oid1));
}

test "CommitGraph computeGenerations" {
    var graph = CommitGraph.init(std.testing.allocator, .{});
    defer graph.deinit();

    const oid1 = oid_mod.OID.zero();
    const oid2: oid_mod.OID = .{ .bytes = .{1} ** 20 };
    const oid3: oid_mod.OID = .{ .bytes = .{2} ** 20 };

    try graph.addCommit(oid1, &.{});
    try graph.addCommit(oid2, &.{oid1});
    try graph.addCommit(oid3, &.{oid2});

    try graph.computeGenerations();

    try std.testing.expectEqual(@as(u32, 0), graph.getCommit(oid1).?.generation);
    try std.testing.expectEqual(@as(u32, 1), graph.getCommit(oid2).?.generation);
    try std.testing.expectEqual(@as(u32, 2), graph.getCommit(oid3).?.generation);
}
