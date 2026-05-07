//! Git Branch - List, create, delete, rename, checkout branches
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;
const BranchLister = @import("../branch/list.zig").BranchLister;
const BranchCreator = @import("../branch/create.zig").BranchCreator;
const BranchDeleter = @import("../branch/delete.zig").BranchDeleter;
const BranchRenamer = @import("../branch/rename.zig").BranchRenamer;
const BranchUpstream = @import("../branch/upstream.zig").BranchUpstream;
const BranchInfo = @import("../branch/list.zig").BranchInfo;
const ListOptions = @import("../branch/list.zig").ListOptions;
const RefStore = @import("../ref/store.zig").RefStore;
const DeleteOptions = @import("../branch/delete.zig").DeleteOptions;
const RenameOptions = @import("../branch/rename.zig").RenameOptions;
const UpstreamOptions = @import("../branch/upstream.zig").UpstreamOptions;
const CheckoutOptions = @import("../checkout/options.zig").CheckoutOptions;
const CheckoutStrategy = @import("../checkout/options.zig").CheckoutStrategy;
const OID = @import("../object/oid.zig").OID;
const HeadManager = @import("../ref/head.zig").HeadManager;
const Commit = @import("../object/commit.zig").Commit;
const Tree = @import("../object/tree.zig").Tree;
const Blob = @import("../object/blob.zig").Blob;
const compress_mod = @import("../compress/zlib.zig");
const object_mod = @import("../object/object.zig");

pub const BranchAction = enum {
    list,
    create,
    delete,
    rename,
    set_upstream,
    unset_upstream,
    checkout,
};

pub const Branch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    action: BranchAction,
    new_branch_name: ?[]const u8,
    old_branch_name: ?[]const u8,
    upstream_name: ?[]const u8,
    options: ListOptions,
    output: Output,
    target: ?[]const u8,
    checkout_options: CheckoutOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Branch {
        return .{
            .allocator = allocator,
            .io = io,
            .action = .list,
            .new_branch_name = null,
            .old_branch_name = null,
            .upstream_name = null,
            .options = ListOptions{},
            .output = Output.init(writer, style, allocator),
            .target = null,
            .checkout_options = CheckoutOptions{},
        };
    }

    pub fn run(self: *Branch) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (self.action) {
            .list => try self.runList(git_dir),
            .create => try self.runCreate(git_dir),
            .delete => try self.runDelete(),
            .rename => try self.runRename(),
            .set_upstream => try self.runSetUpstream(git_dir),
            .unset_upstream => try self.runUnsetUpstream(git_dir),
            .checkout => try self.runCheckout(git_dir),
        }
    }

    fn runList(self: *Branch, git_dir: Io.Dir) !void {
        var ref_store = RefStore.init(git_dir, self.allocator, self.io);

        var lister = BranchLister.init(self.allocator, self.io, &ref_store, self.options);
        const branches = try lister.list();
        defer self.allocator.free(branches);

        try self.output.section("Branches");

        for (branches, 0..) |branch, idx| {
            const is_last = idx == branches.len - 1;
            const kind: TreeKind = if (is_last) .last else .branch;
            const current_marker = if (branch.is_current) "●" else " ";
            try self.output.treeNode(kind, 0, "{s} {s}", .{ current_marker, branch.name });
        }
    }

    fn runCreate(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |name| {
            var ref_store = RefStore.init(git_dir, self.allocator, self.io);

            var creator = BranchCreator.init(self.allocator, &ref_store);
            const head = try ref_store.read("HEAD");
            const oid = if (head.isDirect()) head.target.direct else undefined;

            const result = try creator.create(name, oid);
            try self.output.successMessage("Branch created: {s}", .{result.name});
        } else {
            try self.output.errorMessage("Branch name required for create action", .{});
            return;
        }
    }

    fn runDelete(self: *Branch) !void {
        if (self.old_branch_name) |name| {
            const cwd = Io.Dir.cwd();
            const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
                try self.output.errorMessage("Not in a git repository", .{});
                return;
            };
            defer git_dir.close(self.io);

            var ref_store = RefStore.init(git_dir, self.allocator, self.io);
            const options = DeleteOptions{};
            var deleter = BranchDeleter.init(self.allocator, self.io, &ref_store, options);

            const result = try deleter.delete(name);
            if (result.deleted) {
                try self.output.successMessage("Branch deleted: {s}", .{result.name});
            } else {
                try self.output.errorMessage("Failed to delete branch: {s}", .{result.name});
            }
        } else {
            try self.output.errorMessage("Branch name required for delete action", .{});
            return;
        }
    }

    fn runRename(self: *Branch) !void {
        if (self.old_branch_name) |old| {
            if (self.new_branch_name) |new| {
                const cwd = Io.Dir.cwd();
                const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
                    try self.output.errorMessage("Not in a git repository", .{});
                    return;
                };
                defer git_dir.close(self.io);

                var ref_store = RefStore.init(git_dir, self.allocator, self.io);
                const options = RenameOptions{};
                var renamer = BranchRenamer.init(self.allocator, &ref_store, options);

                const result = try renamer.rename(old, new);
                try self.output.successMessage("Branch renamed: {s} -> {s}", .{ result.old_name, result.new_name });
            } else {
                try self.output.errorMessage("New branch name required for rename action", .{});
                return;
            }
        } else {
            try self.output.errorMessage("Old branch name required for rename action", .{});
            return;
        }
    }

    fn runSetUpstream(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |branch| {
            if (self.upstream_name) |upstream| {
                var ref_store = RefStore.init(git_dir, self.allocator, self.io);
                const options = UpstreamOptions{};

                var branch_upstream = BranchUpstream.init(self.allocator, self.io, &ref_store, options);

                const upstream_ref = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{upstream});
                defer self.allocator.free(upstream_ref);

                const result = try branch_upstream.setUpstream(branch, upstream_ref);
                if (result.was_updated) {
                    try self.output.successMessage("Branch '{s}' set up to track remote branch '{s}'", .{ branch, upstream });
                } else {
                    try self.output.errorMessage("Failed to set upstream for branch: {s}", .{branch});
                }
            } else {
                try self.output.errorMessage("Upstream name required. Usage: branch -u <upstream> <branch>", .{});
            }
        } else {
            try self.output.errorMessage("Branch name required. Usage: branch -u <upstream> <branch>", .{});
        }
    }

    fn runUnsetUpstream(self: *Branch, git_dir: Io.Dir) !void {
        if (self.new_branch_name) |branch| {
            var ref_store = RefStore.init(git_dir, self.allocator, self.io);
            const options = UpstreamOptions{};

            var branch_upstream = BranchUpstream.init(self.allocator, self.io, &ref_store, options);

            const result = try branch_upstream.unsetUpstream(branch);
            if (result.was_updated) {
                try self.output.successMessage("Unset upstream for branch '{s}'", .{branch});
            } else {
                try self.output.infoMessage("Branch '{s}' had no upstream set", .{branch});
            }
        } else {
            try self.output.errorMessage("Branch name required. Usage: branch --unset-upstream <branch>", .{});
        }
    }

    fn runCheckout(self: *Branch, git_dir: Io.Dir) !void {
        const target = self.target orelse {
            try self.output.errorMessage("No branch or commit specified", .{});
            return;
        };

        var ref_store = RefStore.init(git_dir, self.allocator, self.io);
        var head_mgr = HeadManager.init(&ref_store, self.allocator);

        const target_oid = self.resolveTarget(&ref_store, target) catch |err| {
            try self.output.errorMessage("Failed to resolve '{s}': {}", .{ target, err });
            return;
        };

        const commit_data = self.readCommitData(git_dir, target_oid) catch |err| {
            try self.output.errorMessage("Failed to read commit '{s}': {}", .{ target_oid.toHex(), err });
            return;
        };
        defer self.allocator.free(commit_data);

        const commit = Commit.parse(self.allocator, commit_data) catch |err| {
            try self.output.errorMessage("Failed to parse commit: {}", .{err});
            return;
        };
        defer {
            self.allocator.free(commit.parents);
            if (commit.message.len > 0) self.allocator.free(commit.message);
        }

        if (isBranchName(target)) {
            head_mgr.setBranch(target) catch |err| {
                try self.output.errorMessage("Failed to update HEAD to branch '{s}': {}", .{ target, err });
                return;
            };
        } else {
            head_mgr.detach(target_oid) catch |err| {
                try self.output.errorMessage("Failed to detach HEAD: {}", .{err});
                return;
            };
        }

        try self.output.infoMessage("Checking out: {s}", .{target});

        try self.checkoutTreeToWorkdir(git_dir, commit.tree);

        try self.output.successMessage("Checked out {s} (tree {s})", .{ target, commit.tree.toHex() });
    }

    pub fn isBranchName(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |c| {
            if (c == '^' or c == '~') return false;
        }
        if (std.mem.indexOf(u8, name, "..")) |_| return false;
        return true;
    }

    fn resolveTarget(self: *Branch, ref_store: *RefStore, target: []const u8) !OID {
        const branch_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{target});
        defer self.allocator.free(branch_ref);

        if (ref_store.resolve(branch_ref)) |ref| {
            if (ref.isDirect()) {
                return ref.target.direct;
            }
        } else |_| {}

        if (ref_store.resolve(target)) |ref| {
            if (ref.isDirect()) {
                return ref.target.direct;
            }
        } else |_| {}

        return OID.fromHex(target) catch error.RefNotFound;
    }

    fn readCommitData(self: *Branch, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn checkoutTreeToWorkdir(self: *Branch, git_dir: Io.Dir, tree_oid: OID) !void {
        const tree_data = self.readObjectData(git_dir, tree_oid) catch {
            try self.output.errorMessage("Failed to read tree object", .{});
            return;
        };
        defer self.allocator.free(tree_data);

        const obj = object_mod.parse(tree_data) catch {
            try self.output.errorMessage("Failed to parse tree object", .{});
            return;
        };
        if (obj.obj_type != .tree) return;

        try self.applyTreeEntries(obj.data, ".", git_dir);
    }

    fn applyTreeEntries(self: *Branch, tree_data: []const u8, base_path: []const u8, git_dir: Io.Dir) !void {
        var pos: usize = 0;
        while (pos < tree_data.len) {
            const space_idx = std.mem.indexOf(u8, tree_data[pos..], " ") orelse break;
            const mode_str = tree_data[pos .. pos + space_idx];
            pos += space_idx + 1;

            const null_idx = std.mem.indexOf(u8, tree_data[pos..], "\x00") orelse break;
            const name = tree_data[pos .. pos + null_idx];
            pos += null_idx + 1;

            if (pos + 20 > tree_data.len) break;
            const oid_bytes = tree_data[pos .. pos + 20];
            pos += 20;

            var entry_oid: OID = undefined;
            @memcpy(&entry_oid.bytes, oid_bytes);

            const full_path = if (std.mem.eql(u8, base_path, "."))
                name
            else
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_path, name });
            defer if (!std.mem.eql(u8, base_path, ".")) {
                if (full_path.ptr != name.ptr) self.allocator.free(full_path);
            };

            const mode_val = parseModeU32(mode_str) catch continue;

            switch (mode_val) {
                0o040000 => {
                    Io.Dir.cwd().createDirPath(self.io, full_path) catch {};
                    const subtree_data = self.readObjectData(git_dir, entry_oid) catch continue;
                    defer self.allocator.free(subtree_data);
                    const sub_obj = object_mod.parse(subtree_data) catch continue;
                    if (sub_obj.obj_type == .tree) {
                        try self.applyTreeEntries(sub_obj.data, full_path, git_dir);
                    }
                },
                0o100644, 0o100755 => {
                    const blob_data = self.readObjectData(git_dir, entry_oid) catch continue;
                    defer self.allocator.free(blob_data);
                    const blob_obj = object_mod.parse(blob_data) catch continue;
                    if (blob_obj.obj_type == .blob) {
                        const cwd = Io.Dir.cwd();
                        cwd.writeFile(self.io, .{ .sub_path = full_path, .data = blob_obj.data }) catch {};
                    }
                },
                else => {},
            }
        }
    }

    fn readObjectData(self: *Branch, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }
};

fn parseModeU32(mode_str: []const u8) !u32 {
    var mode: u32 = 0;
    for (mode_str) |c| {
        if (c < '0' or c > '7') return error.InvalidMode;
        mode = (mode << 3) | @as(u32, c - '0');
    }
    return mode;
}

test "Branch init" {
    const io = std.Io.Threaded.new(.{}).?;
    const branch = Branch.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(branch.action == .list);
}

test "BranchAction enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(BranchAction.list));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(BranchAction.create));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(BranchAction.delete));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(BranchAction.rename));
    try std.testing.expectEqual(@as(u2, 6), @intFromEnum(BranchAction.checkout));
}

test "Branch has checkout fields" {
    const io = std.Io.Threaded.new(.{}).?;
    const branch = Branch.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(branch.target == null);
    try std.testing.expect(branch.checkout_options.force == false);
}

test "isBranchName detects valid names" {
    try std.testing.expect(Branch.isBranchName("main") == true);
    try std.testing.expect(Branch.isBranchName("feature/test") == true);
    try std.testing.expect(Branch.isBranchName("abc123def456") == false);
    try std.testing.expect(Branch.isBranchName("HEAD~1") == false);
    try std.testing.expect(Branch.isBranchName("main^") == false);
}
