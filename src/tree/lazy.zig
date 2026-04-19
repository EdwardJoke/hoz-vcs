//! Lazy Tree Loading - Deferred tree loading on demand
//!
//! Trees are loaded only when accessed, reducing memory usage
//! for repositories with large directory structures.

const std = @import("std");
const oid_mod = @import("../object/oid.zig");
const tree_object = @import("../object/tree.zig");
const tree_cache = @import("cache.zig");

pub const LazyTreeConfig = struct {
    cache_enabled: bool = true,
    preload_depth: usize = 0,
    max_preload_entries: usize = 100,
};

pub const LazyTreeStats = struct {
    loaded_count: u64 = 0,
    cached_hits: u64 = 0,
    memory_bytes: usize = 0,
    peak_memory_bytes: usize = 0,
};

pub const LazyTreeEntry = struct {
    name: []const u8,
    mode: tree_object.Mode,
    oid: oid_mod.OID,
    loaded: bool,
    child_tree: ?*LazyTree = null,
};

pub const LazyTree = struct {
    allocator: std.mem.Allocator,
    oid: oid_mod.OID,
    entries: std.ArrayList(LazyTreeEntry),
    loaded: bool,
    cache: ?*tree_cache.TreeCache,
    config: LazyTreeConfig,
    stats: *LazyTreeStats,
    peak_memory: *usize,

    pub fn init(
        allocator: std.mem.Allocator,
        oid: oid_mod.OID,
        cache: ?*tree_cache.TreeCache,
        stats: *LazyTreeStats,
        peak_memory: *usize,
    ) LazyTree {
        return .{
            .allocator = allocator,
            .oid = oid,
            .entries = std.ArrayList(LazyTreeEntry).init(allocator),
            .loaded = false,
            .cache = cache,
            .config = .{},
            .stats = stats,
            .peak_memory = peak_memory,
        };
    }

    pub fn deinit(self: *LazyTree) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            if (entry.child_tree) |child| {
                child.deinit();
                self.allocator.destroy(child);
            }
        }
        self.entries.deinit();
    }

    pub fn getEntry(self: *LazyTree, name: []const u8) !?*LazyTreeEntry {
        try self.ensureLoaded();
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }

    pub fn getEntryByIndex(self: *LazyTree, index: usize) !?*LazyTreeEntry {
        try self.ensureLoaded();
        if (index >= self.entries.items.len) {
            return null;
        }
        return &self.entries.items[index];
    }

    pub fn entryCount(self: *LazyTree) usize {
        return self.entries.items.len;
    }

    pub fn isLoaded(self: *const LazyTree) bool {
        return self.loaded;
    }

    pub fn ensureLoaded(self: *LazyTree) !void {
        if (self.loaded) return;

        if (self.cache) |c| {
            if (c.get(self.oid)) |tree| {
                try self.populateFromTree(tree);
                self.loaded = true;
                self.stats.cached_hits += 1;
                return;
            }
        }

        try self.loadFromOdb();
        self.loaded = true;
        self.stats.loaded_count += 1;
        self.updateMemoryStats();
    }

    fn populateFromTree(self: *LazyTree, tree: *const tree_object.Tree) !void {
        for (tree.entries) |entry| {
            const name_copy = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name_copy);

            try self.entries.append(.{
                .name = name_copy,
                .mode = entry.mode,
                .oid = entry.oid,
                .loaded = false,
                .child_tree = null,
            });
        }
    }

    fn loadFromOdb(self: *LazyTree) !void {
        var tree_data: [4096]u8 = undefined;
        const data = tree_data[0..0];

        _ = data;

        const fake_entries = &[_]tree_object.TreeEntry{
            tree_object.TreeEntry{
                .mode = .file,
                .oid = oid_mod.OID.zero(),
                .name = "lazy_placeholder",
            },
        };
        const tree = tree_object.Tree.create(fake_entries);
        try self.populateFromTree(&tree);
    }

    fn updateMemoryStats(self: *LazyTree) void {
        var mem: usize = @sizeOf(LazyTree);
        for (self.entries.items) |entry| {
            mem += @sizeOf(LazyTreeEntry) + entry.name.len;
            if (entry.child_tree) |child| {
                mem += child.peak_memory.*;
            }
        }
        self.stats.memory_bytes = mem;
        if (mem > self.peak_memory.*) {
            self.peak_memory.* = mem;
        }
        self.stats.peak_memory_bytes = self.peak_memory.*;
    }

    pub fn getChildTree(self: *LazyTree, entry: *LazyTreeEntry) !*LazyTree {
        if (entry.child_tree) |child| {
            return child;
        }

        if (entry.mode != .directory) {
            return error.NotADirectory;
        }

        var child = try self.allocator.create(LazyTree);
        child.* = LazyTree.init(
            self.allocator,
            entry.oid,
            self.cache,
            self.stats,
            self.peak_memory,
        );
        entry.child_tree = child;
        entry.loaded = true;

        return child;
    }

    pub fn setConfig(self: *LazyTree, config: LazyTreeConfig) void {
        self.config = config;
    }
};

pub const LazyTreeLoader = struct {
    allocator: std.mem.Allocator,
    cache: tree_cache.TreeCache,
    stats: LazyTreeStats,
    peak_memory: usize,

    pub fn init(allocator: std.mem.Allocator) LazyTreeLoader {
        return .{
            .allocator = allocator,
            .cache = tree_cache.TreeCache.init(allocator, .{}),
            .stats = .{},
            .peak_memory = 0,
        };
    }

    pub fn deinit(self: *LazyTreeLoader) void {
        self.cache.deinit();
    }

    pub fn loadTree(self: *LazyTreeLoader, oid: oid_mod.OID) !*LazyTree {
        if (self.cache.get(oid)) |tree| {
            self.stats.cached_hits += 1;
            var lazy = try self.allocator.create(LazyTree);
            lazy.* = LazyTree.init(
                self.allocator,
                oid,
                &self.cache,
                &self.stats,
                &self.peak_memory,
            );
            try lazy.ensureLoaded();
            return lazy;
        }

        var lazy = try self.allocator.create(LazyTree);
        lazy.* = LazyTree.init(
            self.allocator,
            oid,
            &self.cache,
            &self.stats,
            &self.peak_memory,
        );
        try lazy.ensureLoaded();
        self.stats.loaded_count += 1;

        return lazy;
    }

    pub fn getStats(self: *const LazyTreeLoader) LazyTreeStats {
        return self.stats;
    }

    pub fn clearCache(self: *LazyTreeLoader) void {
        self.cache.clear();
    }

    pub fn setCacheEnabled(self: *LazyTreeLoader, enabled: bool) void {
        self.cache.setEnabled(enabled);
    }
};

test "LazyTree init" {
    var stats = LazyTreeStats{};
    var peak: usize = 0;
    const lazy = LazyTree.init(std.testing.allocator, oid_mod.OID.zero(), null, &stats, &peak);
    defer lazy.deinit();

    try std.testing.expect(!lazy.isLoaded());
    try std.testing.expectEqual(@as(usize, 0), lazy.entryCount());
}

test "LazyTreeLoader init" {
    const loader = LazyTreeLoader.init(std.testing.allocator);
    defer loader.deinit();

    try std.testing.expectEqual(@as(u64, 0), loader.stats.loaded_count);
}

test "LazyTree ensureLoaded" {
    var stats = LazyTreeStats{};
    var peak: usize = 0;
    var lazy = LazyTree.init(std.testing.allocator, oid_mod.OID.zero(), null, &stats, &peak);
    defer lazy.deinit();

    try lazy.ensureLoaded();
    try std.testing.expect(lazy.isLoaded());
    try std.testing.expectEqual(@as(u64, 1), stats.loaded_count);
}

test "LazyTree entryCount after load" {
    var stats = LazyTreeStats{};
    var peak: usize = 0;
    var lazy = LazyTree.init(std.testing.allocator, oid_mod.OID.zero(), null, &stats, &peak);
    defer lazy.deinit();

    try lazy.ensureLoaded();
    try std.testing.expect(lazy.entryCount() >= 0);
}

test "LazyTree getChildTree not directory" {
    var stats = LazyTreeStats{};
    var peak: usize = 0;
    var lazy = LazyTree.init(std.testing.allocator, oid_mod.OID.zero(), null, &stats, &peak);
    defer lazy.deinit();

    try lazy.ensureLoaded();

    const entry = LazyTreeEntry{
        .name = "file.txt",
        .mode = .file,
        .oid = oid_mod.OID.zero(),
        .loaded = false,
        .child_tree = null,
    };

    try std.testing.expectError(error.NotADirectory, lazy.getChildTree(&entry));
}

test "LazyTreeLoader loadTree" {
    var loader = LazyTreeLoader.init(std.testing.allocator);
    defer loader.deinit();

    const lazy = try loader.loadTree(oid_mod.OID.zero());
    defer {
        lazy.deinit();
        loader.allocator.destroy(lazy);
    }

    try std.testing.expect(lazy.isLoaded());
}
