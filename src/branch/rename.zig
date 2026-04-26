//! Branch Rename - Rename branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const RefErr = @import("../ref/ref.zig").RefError;

pub const RenameError = error{
    BranchNotFound,
    BranchAlreadyExists,
    InvalidBranchName,
} || RefErr;

pub const RenameOptions = struct {
    force: bool = false,
    reflog: bool = false,
};

pub const RenameResult = struct {
    old_name: []const u8,
    new_name: []const u8,
    forced: bool,
};

pub const BranchRenamer = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: RenameOptions,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: RenameOptions) BranchRenamer {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn rename(self: *BranchRenamer, old_name: []const u8, new_name: []const u8) !RenameResult {
        const old_ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{old_name});
        defer self.allocator.free(old_ref_name);

        const new_ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{new_name});
        defer self.allocator.free(new_ref_name);

        if (!self.ref_store.exists(old_ref_name)) {
            return RenameError.BranchNotFound;
        }

        if (self.ref_store.exists(new_ref_name) and !self.options.force) {
            return RenameError.BranchAlreadyExists;
        }

        const old_ref = try self.ref_store.read(old_ref_name);
        const target_oid = if (old_ref.isDirect()) old_ref.target.direct else return RenameError.InvalidBranchName;

        const new_ref = Ref.directRef(new_ref_name, target_oid);
        try self.ref_store.write(new_ref);
        self.ref_store.delete(old_ref_name) catch {};

        return RenameResult{
            .old_name = old_name,
            .new_name = new_name,
            .forced = self.options.force,
        };
    }

    pub fn renameCurrent(self: *BranchRenamer, new_name: []const u8) !RenameResult {
        const head = self.ref_store.read("HEAD") catch return RenameError.BranchNotFound;
        if (!head.isSymbolic()) {
            return RenameError.InvalidBranchName;
        }

        const head_target = head.target.symbolic;
        if (!std.mem.startsWith(u8, head_target, "refs/heads/")) {
            return RenameError.InvalidBranchName;
        }

        const old_name = head_target["refs/heads/".len..];
        return try self.rename(old_name, new_name);
    }
};

test "RenameOptions default values" {
    const options = RenameOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.reflog == false);
}

test "RenameResult structure" {
    const result = RenameResult{
        .old_name = "old-branch",
        .new_name = "new-branch",
        .forced = false,
    };

    try std.testing.expectEqualStrings("old-branch", result.old_name);
    try std.testing.expectEqualStrings("new-branch", result.new_name);
    try std.testing.expect(result.forced == false);
}

test "BranchRenamer init" {
    const options = RenameOptions{};
    var ref_store: RefStore = undefined;
    const renamer = BranchRenamer.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(renamer.allocator == std.testing.allocator);
}

test "BranchRenamer init with options" {
    var opts = RenameOptions{};
    opts.force = true;
    var ref_store: RefStore = undefined;
    const renamer = BranchRenamer.init(std.testing.allocator, &ref_store, opts);

    try std.testing.expect(renamer.options.force == true);
}

test "BranchRenamer rename method exists" {
    const options = RenameOptions{};
    var ref_store: RefStore = undefined;
    const renamer = BranchRenamer.init(std.testing.allocator, &ref_store, options);

    const result = try renamer.rename("old-name", "new-name");
    try std.testing.expectEqualStrings("old-name", result.old_name);
}

test "BranchRenamer renameCurrent method exists" {
    const options = RenameOptions{};
    var ref_store: RefStore = undefined;
    const renamer = BranchRenamer.init(std.testing.allocator, &ref_store, options);

    const result = try renamer.renameCurrent("new-branch-name");
    try std.testing.expectEqualStrings("new-branch-name", result.new_name);
}
