//! Git Checkout - Switch branches or restore working tree files
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const CheckoutOptions = @import("../checkout/options.zig").CheckoutOptions;
const CheckoutStrategy = @import("../checkout/options.zig").CheckoutStrategy;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const HeadManager = @import("../ref/head.zig").HeadManager;
const Commit = @import("../object/commit.zig").Commit;
const Tree = @import("../object/tree.zig").Tree;
const Blob = @import("../object/blob.zig").Blob;
const compress_mod = @import("../compress/zlib.zig");
const object_mod = @import("../object/object.zig");

pub const Checkout = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: CheckoutOptions,
    target: ?[]const u8,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Checkout {
        return .{
            .allocator = allocator,
            .io = io,
            .options = CheckoutOptions{},
            .target = null,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Checkout) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

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

    fn isBranchName(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |c| {
            if (c == '^' or c == '~') return false;
        }
        if (std.mem.indexOf(u8, name, "..")) |_| return false;
        return true;
    }

    fn resolveTarget(self: *Checkout, ref_store: *RefStore, target: []const u8) !OID {
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

    fn readCommitData(self: *Checkout, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = try git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator);
    }

    fn checkoutTreeToWorkdir(self: *Checkout, git_dir: Io.Dir, tree_oid: OID) !void {
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

    fn applyTreeEntries(self: *Checkout, tree_data: []const u8, base_path: []const u8, git_dir: Io.Dir) !void {
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

    fn readObjectData(self: *Checkout, git_dir: Io.Dir, oid: OID) ![]u8 {
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

test "Checkout init" {
    const io = std.Io.Threaded.new(.{}).?;
    const checkout = Checkout.init(std.testing.allocator, io, undefined, .{});
    try std.testing.expect(checkout.target == null);
}

test "CheckoutStrategy enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(CheckoutStrategy.force));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(CheckoutStrategy.safe));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(CheckoutStrategy.update_only));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(CheckoutStrategy.migrate));
}

test "Checkout isBranchName detects valid names" {
    try std.testing.expect(Checkout.isBranchName("main") == true);
    try std.testing.expect(Checkout.isBranchName("feature/test") == true);
    try std.testing.expect(Checkout.isBranchName("abc123def456") == false);
    try std.testing.expect(Checkout.isBranchName("HEAD~1") == false);
    try std.testing.expect(Checkout.isBranchName("main^") == false);
}
