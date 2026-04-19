//! Object Graph - Graph traversal and ancestry path finding
const std = @import("std");
const oid_mod = @import("oid.zig");
const object_mod = @import("object.zig");
const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const blob_mod = @import("blob.zig");
const tag_mod = @import("tag.zig");

pub const GraphError = error{
    NotACommit,
    ObjectNotFound,
    CycleDetected,
    MaxDepthExceeded,
    NoPathFound,
};

pub const WalkOrder = enum {
    breadth_first,
    depth_first_pre,
    depth_first_post,
};

pub const AncestorResult = struct {
    is_ancestor: bool,
    distance: u32,
};

pub const PathResult = struct {
    path: []const oid_mod.OID,
    distance: u32,
};

pub const GraphWalker = struct {
    visited: std.AutoHashMap(oid_mod.OID, void),
    allocator: std.mem.Allocator,
    max_depth: u32,

    pub fn init(allocator: std.mem.Allocator) GraphWalker {
        return .{
            .visited = std.AutoHashMap(oid_mod.OID, void).init(allocator),
            .allocator = allocator,
            .max_depth = 1000,
        };
    }

    pub fn deinit(self: *GraphWalker) void {
        self.visited.deinit();
    }

    pub fn isAncestor(self: *GraphWalker, ancestor_oid: oid_mod.OID, descendant_oid: oid_mod.OID, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !AncestorResult {
        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();

        var distance: u32 = 0;
        try queue.append(descendant_oid);

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);

            if (current.eql(ancestor_oid)) {
                return AncestorResult{ .is_ancestor = true, .distance = distance };
            }

            if (self.visited.contains(current)) {
                continue;
            }
            try self.visited.put(current, {});

            if (distance >= self.max_depth) {
                return GraphError.MaxDepthExceeded;
            }

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!self.visited.contains(parent)) {
                        try queue.append(parent);
                    }
                }
            } else {
                return GraphError.ObjectNotFound;
            }

            distance += 1;
        }

        return AncestorResult{ .is_ancestor = false, .distance = 0 };
    }

    pub fn findPath(self: *GraphWalker, from: oid_mod.OID, to: oid_mod.OID, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !PathResult {
        var came_from = std.AutoHashMap(oid_mod.OID, oid_mod.OID).init(self.allocator);
        defer came_from.deinit();

        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();

        try queue.append(from);
        try came_from.put(from, from);

        var distance: u32 = 0;

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);

            if (current.eql(to)) {
                var path = std.ArrayList(oid_mod.OID).init(self.allocator);
                defer path.deinit();

                var node = to;
                while (true) {
                    try path.append(node);
                    if (node.eql(from)) break;
                    const prev = came_from.get(node) orelse break;
                    node = prev;
                }

                std.mem.reverse(oid_mod.OID, path.items);
                return PathResult{ .path = try path.toOwnedSlice(), .distance = distance };
            }

            if (distance >= self.max_depth) {
                return GraphError.MaxDepthExceeded;
            }

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!came_from.contains(parent)) {
                        try queue.append(parent);
                        try came_from.put(parent, current);
                    }
                }
            }

            distance += 1;
        }

        return GraphError.NoPathFound;
    }

    pub fn traverse(self: *GraphWalker, start: oid_mod.OID, order: WalkOrder, callback: *const fn (oid: oid_mod.OID, depth: u32) bool, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !void {
        switch (order) {
            .breadth_first => try self.breadthFirstWalk(start, callback, getCommit),
            .depth_first_pre => try self.depthFirstPreWalk(start, 0, callback, getCommit),
            .depth_first_post => try self.depthFirstPostWalk(start, 0, callback, getCommit),
        }
    }

    fn breadthFirstWalk(self: *GraphWalker, start: oid_mod.OID, callback: *const fn (oid: oid_mod.OID, depth: u32) bool, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !void {
        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();

        var depth_queue = std.ArrayList(u32).init(self.allocator);
        defer depth_queue.deinit();

        try queue.append(start);
        try depth_queue.append(0);
        try self.visited.put(start, {});

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            const depth = depth_queue.orderedRemove(0);

            if (!callback(current, depth)) {
                return;
            }

            if (depth >= self.max_depth) {
                return GraphError.MaxDepthExceeded;
            }

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!self.visited.contains(parent)) {
                        try self.visited.put(parent, {});
                        try queue.append(parent);
                        try depth_queue.append(depth + 1);
                    }
                }
            }
        }
    }

    fn depthFirstPreWalk(self: *GraphWalker, current: oid_mod.OID, depth: u32, callback: *const fn (oid: oid_mod.OID, depth: u32) bool, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !void {
        if (self.visited.contains(current)) {
            return;
        }
        try self.visited.put(current, {});

        if (!callback(current, depth)) {
            return;
        }

        if (depth >= self.max_depth) {
            return GraphError.MaxDepthExceeded;
        }

        if (getCommit(current)) |commit| {
            for (commit.parents) |parent| {
                try self.depthFirstPreWalk(parent, depth + 1, callback, getCommit);
            }
        }
    }

    fn depthFirstPostWalk(self: *GraphWalker, current: oid_mod.OID, depth: u32, callback: *const fn (oid: oid_mod.OID, depth: u32) bool, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !void {
        if (self.visited.contains(current)) {
            return;
        }
        try self.visited.put(current, {});

        if (depth >= self.max_depth) {
            return GraphError.MaxDepthExceeded;
        }

        if (getCommit(current)) |commit| {
            for (commit.parents) |parent| {
                try self.depthFirstPostWalk(parent, depth + 1, callback, getCommit);
            }
        }

        _ = callback(current, depth);
    }

    pub fn getAncestors(self: *GraphWalker, start: oid_mod.OID, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) ![]oid_mod.OID {
        var ancestors = std.ArrayList(oid_mod.OID).init(self.allocator);
        errdefer ancestors.deinit();

        var stack = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer stack.deinit();

        try stack.append(start);
        try self.visited.put(start, {});

        while (stack.items.len > 0) {
            const current = stack.pop();

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!self.visited.contains(parent)) {
                        try self.visited.put(parent, {});
                        try ancestors.append(parent);
                        try stack.append(parent);
                    }
                }
            }
        }

        return try ancestors.toOwnedSlice();
    }

    pub fn getDescendants(self: *GraphWalker, start: oid_mod.OID, getObject: *const fn (oid: oid_mod.OID) ?object_mod.Object, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) ![]oid_mod.OID {
        var descendants = std.ArrayList(oid_mod.OID).init(self.allocator);
        errdefer descendants.deinit();

        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();

        try queue.append(start);

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);

            if (getObject(current)) |obj| {
                switch (obj.obj_type) {
                    .commit => {
                        if (getCommit(current)) |commit| {
                            for (commit.parents) |parent| {
                                if (!self.visited.contains(parent)) {
                                    try self.visited.put(parent, {});
                                    try descendants.append(parent);
                                    try queue.append(parent);
                                }
                            }
                        }
                    },
                    .tree => {},
                    .blob => {},
                    .tag => {},
                }
            }
        }

        return try descendants.toOwnedSlice();
    }

    pub fn getMergeBase(self: *GraphWalker, oid1: oid_mod.OID, oid2: oid_mod.OID, getCommit: *const fn (oid: oid_mod.OID) ?*const commit_mod.Commit) !?oid_mod.OID {
        var ancestors1 = std.AutoHashMap(oid_mod.OID, u32).init(self.allocator);
        defer ancestors1.deinit();

        var queue = std.ArrayList(oid_mod.OID).init(self.allocator);
        defer queue.deinit();

        try queue.append(oid1);
        try ancestors1.put(oid1, 0);

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            const depth1 = ancestors1.get(current).?;

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!ancestors1.contains(parent)) {
                        try ancestors1.put(parent, depth1 + 1);
                        try queue.append(parent);
                    }
                }
            }
        }

        var visited2 = std.AutoHashMap(oid_mod.OID, u32).init(self.allocator);
        defer visited2.deinit();

        try queue.append(oid2);
        try visited2.put(oid2, 0);

        var best_depth: u32 = std.math.maxInt(u32);
        var merge_base: ?oid_mod.OID = null;

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            const depth2 = visited2.get(current).?;

            if (ancestors1.get(current)) |depth1| {
                const combined = depth1 + depth2;
                if (combined < best_depth) {
                    best_depth = combined;
                    merge_base = current;
                }
            }

            if (getCommit(current)) |commit| {
                for (commit.parents) |parent| {
                    if (!visited2.contains(parent)) {
                        try visited2.put(parent, depth2 + 1);
                        try queue.append(parent);
                    }
                }
            }
        }

        return merge_base;
    }
};

test "GraphWalker init and deinit" {
    var walker = GraphWalker.init(std.testing.allocator);
    defer walker.deinit();
    try std.testing.expect(walker.visited.count() == 0);
}

test "AncestorResult structure" {
    const result = AncestorResult{ .is_ancestor = true, .distance = 5 };
    try std.testing.expect(result.is_ancestor == true);
    try std.testing.expect(result.distance == 5);
}

test "PathResult structure" {
    const path = [_]oid_mod.OID{oid_mod.oidZero(), oid_mod.oidZero()};
    const result = PathResult{ .path = &path, .distance = 2 };
    try std.testing.expect(result.distance == 2);
}
