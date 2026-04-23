//! Amend Last Commit - Modify the most recent commit
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const Commit = @import("../object/commit.zig").Commit;
const Builder = @import("builder.zig").CommitBuilder;
const ODB = @import("../object/odb.zig").ODB;
const RefStore = @import("../ref/store.zig").RefStore;

pub const AmendOptions = struct {
    author: ?Commit.Identity = null,
    committer: ?Commit.Identity = null,
    message: ?[]const u8 = null,
};

pub const Amender = struct {
    allocator: std.mem.Allocator,
    odb: *ODB,
    ref_store: *RefStore,

    pub fn init(allocator: std.mem.Allocator, odb: *ODB, ref_store: *RefStore) Amender {
        return .{
            .allocator = allocator,
            .odb = odb,
            .ref_store = ref_store,
        };
    }

    pub fn amend(
        self: *Amender,
        options: AmendOptions,
    ) !OID {
        _ = self;
        _ = options;
        return OID.zero();
    }
};

test "Amender init" {
    const odb: ODB = undefined;
    const ref_store: RefStore = undefined;
    const amender = Amender.init(std.testing.allocator, &odb, &ref_store);

    try std.testing.expect(amender.allocator == std.testing.allocator);
}

test "Amender init with odbs and refstore" {
    const odb: ODB = undefined;
    const ref_store: RefStore = undefined;
    const amender = Amender.init(std.testing.allocator, &odb, &ref_store);

    try std.testing.expect(amender.odb == &odb);
    try std.testing.expect(amender.ref_store == &ref_store);
}

test "AmendOptions default values" {
    const options = AmendOptions{};
    try std.testing.expect(options.author == null);
    try std.testing.expect(options.committer == null);
    try std.testing.expect(options.message == null);
}