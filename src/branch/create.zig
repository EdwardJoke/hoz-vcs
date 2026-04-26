//! Branch Create - Create new branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const CreateError = error{
    BranchAlreadyExists,
    CannotResolveRef,
} || Ref.RefError;

pub const CreateOptions = struct {
    force: bool = false,
    track: ?enum { automatic, no_track } = .automatic,
    reflog: bool = false,
};

pub const CreateResult = struct {
    name: []const u8,
    oid: OID,
    forced: bool,
};

pub const BranchCreator = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: CreateOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore) BranchCreator {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = CreateOptions{},
        };
    }

    pub fn create(self: *BranchCreator, name: []const u8, oid: OID) !CreateResult {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        if (self.ref_store.exists(ref_name) and !self.options.force) {
            return error.BranchAlreadyExists;
        }

        const ref = Ref.directRef(ref_name, oid);
        try self.ref_store.write(ref);

        return CreateResult{
            .name = name,
            .oid = oid,
            .forced = self.options.force,
        };
    }

    pub fn createFromRef(self: *BranchCreator, name: []const u8, start_ref: []const u8) !CreateResult {
        const resolved = try self.ref_store.resolve(start_ref);
        const target_oid = resolved.target.direct orelse return error.CannotResolveRef;
        return try self.create(name, target_oid);
    }
};

test "CreateOptions default values" {
    const options = CreateOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.track == .automatic);
    try std.testing.expect(options.reflog == false);
}

test "CreateResult structure" {
    const result = CreateResult{
        .name = "feature-branch",
        .oid = undefined,
        .forced = false,
    };

    try std.testing.expectEqualStrings("feature-branch", result.name);
    try std.testing.expect(result.forced == false);
}

test "BranchCreator init" {
    var ref_store: RefStore = undefined;
    const creator = BranchCreator.init(std.testing.allocator, &ref_store);

    try std.testing.expect(creator.allocator == std.testing.allocator);
}

test "BranchCreator init with options" {
    var ref_store: RefStore = undefined;
    var creator = BranchCreator.init(std.testing.allocator, &ref_store);
    creator.options.force = true;

    try std.testing.expect(creator.options.force == true);
}

test "BranchCreator create method exists" {
    var ref_store: RefStore = undefined;
    var creator = BranchCreator.init(std.testing.allocator, &ref_store);

    const result = try creator.create("main", undefined);
    try std.testing.expectEqualStrings("main", result.name);
}

test "BranchCreator createFromRef method exists" {
    var ref_store: RefStore = undefined;
    var creator = BranchCreator.init(std.testing.allocator, &ref_store);

    const result = try creator.createFromRef("feature", "HEAD");
    try std.testing.expectEqualStrings("feature", result.name);
}
