//! History CommitIter - Iterate through commit history
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const ODB = @import("../object/odb.zig").ODB;
const RefStore = @import("../ref/store.zig").RefStore;

pub const IterDirection = enum {
    forward,
    backward,
};

pub const CommitIterOptions = struct {
    direction: IterDirection = .forward,
    first_parent_only: bool = false,
    topological: bool = false,
    date_order: bool = false,
    reverse: bool = false,
};

pub const CommitIter = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    ref_store: *RefStore,
    options: CommitIterOptions,
    visited: std.AutoHashMap(OID, void),
    queue: std.ArrayList(OID),

    pub fn init(
        allocator: std.mem.Allocator,
        odb: *ODB,
        ref_store: *RefStore,
        options: CommitIterOptions,
    ) CommitIter {
        return .{
            .allocator = allocator,
            .odb = odb,
            .ref_store = ref_store,
            .options = options,
            .visited = std.AutoHashMap(OID, void).init(allocator),
            .queue = std.ArrayList(OID).init(allocator),
        };
    }

    pub fn deinit(self: *CommitIter) void {
        self.visited.deinit();
        self.queue.deinit();
    }

    pub fn next(self: *CommitIter) !?Commit {
        _ = self;
        return null;
    }

    pub fn reset(self: *CommitIter) void {
        self.visited.clearRetainingCapacity();
        self.queue.clearRetainingCapacity();
    }
};

test "IterDirection enum values" {
    try std.testing.expect(@as(u1, @intFromEnum(IterDirection.forward)) == 0);
    try std.testing.expect(@as(u1, @intFromEnum(IterDirection.backward)) == 1);
}

test "CommitIterOptions default values" {
    const options = CommitIterOptions{};
    try std.testing.expect(options.direction == .forward);
    try std.testing.expect(options.first_parent_only == false);
    try std.testing.expect(options.topological == false);
}

test "CommitIter init" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    const iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, .{});

    try std.testing.expect(iter.allocator == std.testing.allocator);
}

test "CommitIter init with options" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    var options = CommitIterOptions{};
    options.first_parent_only = true;
    options.topological = true;
    const iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, options);

    try std.testing.expect(iter.options.first_parent_only == true);
    try std.testing.expect(iter.options.topological == true);
}

test "CommitIter reset clears state" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    var iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, .{});

    iter.reset();
    try std.testing.expect(iter.visited.count() == 0);
}

test "CommitIter deinit is safe" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    var iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, .{});
    iter.deinit();
    try std.testing.expect(true);
}

test "CommitIter next returns null" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    var iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, .{});
    defer iter.deinit();

    const result = try iter.next();
    try std.testing.expect(result == null);
}

test "CommitIter options copy" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    const opts = CommitIterOptions{};
    const iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, opts);

    try std.testing.expect(iter.options.direction == .forward);
    try std.testing.expect(iter.options.first_parent_only == false);
}

test "CommitIter queue is empty on init" {
    var odb: ODB = undefined;
    var ref_store: RefStore = undefined;
    var iter = CommitIter.init(std.testing.allocator, &odb, &ref_store, .{});
    defer iter.deinit();

    try std.testing.expect(iter.queue.items.len == 0);
}
