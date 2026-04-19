//! Commit HEAD Update - Updates HEAD after creating a commit
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const HeadUpdate = struct {
    ref_store: *RefStore,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore) HeadUpdate {
        return .{
            .ref_store = ref_store,
            .allocator = allocator,
        };
    }

    pub fn updateHead(
        self: *HeadUpdate,
        commit_oid: OID,
        ref_name: []const u8,
    ) !void {
        try self.ref_store.write(ref_name, commit_oid);
    }

    pub fn updateHeadSymbolic(
        self: *HeadUpdate,
        target: []const u8,
    ) !void {
        try self.ref_store.writeSymbolic("HEAD", target);
    }

    pub fn getCurrentHead(self: *HeadUpdate) !?OID {
        return self.ref_store.readOid("HEAD");
    }
};

test "HeadUpdate init" {
    var ref_store: RefStore = undefined;
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(std.testing.allocator, updater.allocator);
}

test "HeadUpdate init with ref_store" {
    var ref_store: RefStore = undefined;
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(&ref_store, updater.ref_store);
}

test "HeadUpdate allocator access" {
    var ref_store: RefStore = undefined;
    const updater = HeadUpdate.init(std.testing.allocator, &ref_store);

    try std.testing.expectEqual(std.testing.allocator, updater.allocator);
}
