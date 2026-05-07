//! Branch Move - Move/rename a branch
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const MoveOptions = struct {
    force: bool = false,
    reflog: bool = false,
    create_reflog: bool = false,
    track: bool = false,
};

pub const MoveResult = struct {
    old_name: []const u8,
    new_name: []const u8,
    forced: bool,
    oid: OID,
};

pub const BranchMover = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: MoveOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: MoveOptions) BranchMover {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn move(self: *BranchMover, old_name: []const u8, new_name: []const u8) !MoveResult {
        const old_ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{old_name});
        defer self.allocator.free(old_ref_name);

        const new_ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{new_name});
        defer self.allocator.free(new_ref_name);

        const existing_new = self.ref_store.read(new_ref_name) catch null;
        if (existing_new != null and !self.options.force) {
            return error.BranchAlreadyExists;
        }

        const old_ref = self.ref_store.read(old_ref_name) catch {
            return error.BranchNotFound;
        };

        const target_oid = if (old_ref.isDirect()) old_ref.target.direct else {
            return error.NotADirectRef;
        };

        const new_ref = Ref.directRef(new_ref_name, target_oid);
        try self.ref_store.write(new_ref);
        self.ref_store.delete(old_ref_name) catch {};

        return MoveResult{
            .old_name = old_name,
            .new_name = new_name,
            .forced = self.options.force,
            .oid = target_oid,
        };
    }

    pub fn forceMove(self: *BranchMover, old_name: []const u8, new_name: []const u8) !MoveResult {
        var force_options = self.options;
        force_options.force = true;

        const force_mover = BranchMover{
            .allocator = self.allocator,
            .ref_store = self.ref_store,
            .options = force_options,
        };

        const result = try force_mover.move(old_name, new_name);
        return MoveResult{
            .old_name = result.old_name,
            .new_name = result.new_name,
            .forced = true,
            .oid = result.oid,
        };
    }
};

test "MoveOptions default values" {
    const options = MoveOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.reflog == false);
    try std.testing.expect(options.create_reflog == false);
    try std.testing.expect(options.track == false);
}

test "MoveResult structure" {
    const result = MoveResult{
        .old_name = "old-branch",
        .new_name = "new-branch",
        .forced = true,
        .oid = undefined,
    };

    try std.testing.expectEqualStrings("old-branch", result.old_name);
    try std.testing.expectEqualStrings("new-branch", result.new_name);
    try std.testing.expect(result.forced == true);
}

test "BranchMover init" {
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = undefined,
        .odb = null,
    };
    const options = MoveOptions{};
    const mover = BranchMover.init(std.testing.allocator, &store, options);

    try std.testing.expect(mover.options.force == false);
}

test "BranchMover init with options" {
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = undefined,
        .odb = null,
    };
    const options = MoveOptions{ .force = true, .track = true };
    const mover = BranchMover.init(std.testing.allocator, &store, options);

    try std.testing.expect(mover.options.force == true);
    try std.testing.expect(mover.options.track == true);
}

test "BranchMover has move method" {
    const Mover = BranchMover;
    try std.testing.expect(@hasDecl(Mover, "move"));
}

test "BranchMover has forceMove method" {
    const Mover = BranchMover;
    try std.testing.expect(@hasDecl(Mover, "forceMove"));
}
