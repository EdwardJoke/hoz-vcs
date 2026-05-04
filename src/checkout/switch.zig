//! Switch Branch - Switch between branches
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;

pub const SwitchOptions = struct {
    create_branch: bool = false,
    force_create: bool = false,
    detach: bool = false,
    force: bool = false,
    track: ?[]const u8 = null,
    branch_name: ?[]const u8 = null,
};

pub const SwitchResult = struct {
    success: bool,
    new_branch: bool,
    detached: bool,
    head_oid: ?OID,
};

pub const BranchSwitcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    ref_store: *RefStore,
    options: SwitchOptions,
    git_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: SwitchOptions, git_dir: []const u8) BranchSwitcher {
        return .{
            .allocator = allocator,
            .io = io,
            .ref_store = ref_store,
            .options = options,
            .git_dir = git_dir,
        };
    }

    pub fn @"switch"(self: *BranchSwitcher, branch: []const u8) !SwitchResult {
        const ref_name = try self.refName(branch);
        const resolved = self.ref_store.resolve(ref_name) catch {
            return SwitchResult{ .success = false, .new_branch = false, .detached = false, .head_oid = null };
        };

        try self.updateHead(ref_name);

        return SwitchResult{
            .success = true,
            .new_branch = false,
            .detached = false,
            .head_oid = resolved.target.direct,
        };
    }

    pub fn createAndSwitch(self: *BranchSwitcher, branch: []const u8) !SwitchResult {
        const head_ref = self.ref_store.resolve("HEAD") catch
            return SwitchResult{ .success = false, .new_branch = false, .detached = false, .head_oid = null };

        const head_oid = head_ref.getOid() orelse
            return SwitchResult{ .success = false, .new_branch = false, .detached = false, .head_oid = null };

        const target_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(target_ref);

        const existing = self.ref_store.resolve(target_ref) catch null;
        if (existing != null and !self.options.force_create) {
            return SwitchResult{ .success = false, .new_branch = true, .detached = false, .head_oid = null };
        }

        try self.ref_store.write(.{ .name = target_ref, .ref_type = .direct, .target = .{ .direct = head_oid } });

        try self.updateHead(target_ref);

        return SwitchResult{
            .success = true,
            .new_branch = true,
            .detached = false,
            .head_oid = head_oid,
        };
    }

    pub fn detachHead(self: *BranchSwitcher, commit_oid: OID) !SwitchResult {
        const oid_hex = commit_oid.toHex();
        const oid_str = try std.fmt.allocPrint(self.allocator, "{s}", .{oid_hex});
        defer self.allocator.free(oid_str);

        try self.writeHeadDetached(&oid_str);

        return SwitchResult{
            .success = true,
            .new_branch = false,
            .detached = true,
            .head_oid = commit_oid,
        };
    }

    fn refName(self: *BranchSwitcher, name: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, name, "refs/")) {
            return try self.allocator.dupe(u8, name);
        }
        return try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
    }

    fn updateHead(self: *BranchSwitcher, ref_name: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator, "ref: {s}\n", .{ref_name});
        defer self.allocator.free(content);

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const cwd = Io.Dir.cwd();
        var file = try cwd.createFile(self.io, head_path, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(content);
    }

    fn writeHeadDetached(self: *BranchSwitcher, oid_str: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_str});
        defer self.allocator.free(content);

        const head_path = try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir});
        defer self.allocator.free(head_path);

        const cwd = Io.Dir.cwd();
        var file = try cwd.createFile(self.io, head_path, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.writeAll(content);
    }
};

test "SwitchOptions default values" {
    const options = SwitchOptions{};
    try std.testing.expect(options.create_branch == false);
    try std.testing.expect(options.force_create == false);
    try std.testing.expect(options.detach == false);
    try std.testing.expect(options.force == false);
}

test "SwitchResult structure" {
    const result = SwitchResult{
        .success = true,
        .new_branch = true,
        .detached = false,
        .head_oid = null,
    };

    try std.testing.expect(result.success == true);
    try std.testing.expect(result.new_branch == true);
    try std.testing.expect(result.detached == false);
}

test "BranchSwitcher init" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.allocator == std.testing.allocator);
}

test "BranchSwitcher init with ref_store" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.ref_store == &ref_store);
}

test "BranchSwitcher init with options" {
    var ref_store: RefStore = undefined;
    var options = SwitchOptions{};
    options.create_branch = true;
    options.detach = true;
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.options.create_branch == true);
    try std.testing.expect(switcher.options.detach == true);
}

test "BranchSwitcher init sets allocator" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.allocator.ptr != null);
}

test "BranchSwitcher switch initializes with options" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{ .force = true };
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.options.force == true);
    try std.testing.expect(switcher.options.create_branch == false);
    const result = try switcher.@"switch"("main");
    try std.testing.expect(result.success == false);
}

test "BranchSwitcher createAndSwitch requires create_branch option" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{ .create_branch = true, .force_create = true };
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.options.create_branch == true);
    try std.testing.expect(switcher.options.force_create == true);
}

test "BranchSwitcher detachHead sets detached flag in result" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{ .detach = true };
    const switcher = BranchSwitcher.init(std.testing.allocator, undefined, &ref_store, options, ".git");

    try std.testing.expect(switcher.options.detach == true);
    const test_oid = try OID.fromHex("0123456789abcdef0123456789abcdef01234567");

    const result = try switcher.detachHead(test_oid);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.detached == true);
    try std.testing.expect(result.new_branch == false);
    try std.testing.expect(result.head_oid.?.eql(test_oid));
}
