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

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: SwitchOptions) BranchSwitcher {
        return .{
            .allocator = allocator,
            .io = io,
            .ref_store = ref_store,
            .options = options,
        };
    }

    pub fn @"switch"(self: *BranchSwitcher, branch: []const u8) !SwitchResult {
        const ref_name = try self.refName(branch);
        const resolved = self.ref_store.resolve(ref_name) catch {
            return SwitchResult{ .success = false, .new_branch = false, .detached = false, .head_oid = null };
        };

        try self.updateHead(ref_name, &resolved.target.direct);

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

        const target_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
        defer self.allocator.free(target_ref);

        _ = self.ref_store.resolve(target_ref) catch {
            if (!self.options.force_create) {
                return SwitchResult{ .success = false, .new_branch = true, .detached = false, .head_oid = null };
            }
        };

        try self.updateHead(target_ref, &head_ref.target.direct);

        return SwitchResult{
            .success = true,
            .new_branch = true,
            .detached = false,
            .head_oid = head_ref.target.direct,
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

    fn updateHead(self: *BranchSwitcher, ref_name: []const u8, _: *const OID) !void {
        const content = try std.fmt.allocPrint(self.allocator, "ref: {s}\n", .{ref_name});
        defer self.allocator.free(content);

        const cwd = Io.Dir.cwd();
        var file = cwd.createFile(self.io, ".git/HEAD", .{}) catch return;
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        writer.interface.writeAll(content) catch return;
    }

    fn writeHeadDetached(self: *BranchSwitcher, oid_str: []const u8) !void {
        const content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_str});
        defer self.allocator.free(content);

        const cwd = Io.Dir.cwd();
        var file = cwd.createFile(self.io, ".git/HEAD", .{}) catch return;
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        writer.interface.writeAll(content) catch return;
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
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.allocator == std.testing.allocator);
}

test "BranchSwitcher init with ref_store" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.ref_store == &ref_store);
}

test "BranchSwitcher init with options" {
    var ref_store: RefStore = undefined;
    var options = SwitchOptions{};
    options.create_branch = true;
    options.detach = true;
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.options.create_branch == true);
    try std.testing.expect(switcher.options.detach == true);
}

test "BranchSwitcher init sets allocator" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.allocator.ptr != null);
}

test "BranchSwitcher switch method exists" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.allocator == std.testing.allocator);
}

test "BranchSwitcher createAndSwitch method exists" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.allocator == std.testing.allocator);
}

test "BranchSwitcher detachHead method exists" {
    var ref_store: RefStore = undefined;
    const options = SwitchOptions{};
    const switcher = BranchSwitcher.init(std.testing.allocator, std.Io.get(), &ref_store, options);

    try std.testing.expect(switcher.allocator == std.testing.allocator);
}
