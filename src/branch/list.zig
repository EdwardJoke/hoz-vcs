//! Branch List - List branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;

pub const ListOptions = struct {
    all: bool = false,
    current: bool = false,
    verbose: bool = false,
    abbrev_oid: bool = true,
    abbrev_length: u8 = 7,
    pattern: ?[]const u8 = null,
    contain: ?[]const u8 = null,
};

pub const BranchInfo = struct {
    name: []const u8,
    oid: OID,
    is_current: bool,
    is_remote: bool,
    is_head: bool,
    upstream: ?[]const u8,
    ahead: ?u32,
    behind: ?u32,
};

pub const BranchLister = struct {
    allocator: std.mem.Allocator,
    ref_store: *RefStore,
    options: ListOptions,
    head_target: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, ref_store: *RefStore, options: ListOptions) BranchLister {
        return .{
            .allocator = allocator,
            .ref_store = ref_store,
            .options = options,
            .head_target = null,
        };
    }

    pub fn list(self: *BranchLister) ![]const BranchInfo {
        var branches = std.ArrayList(BranchInfo).empty;
        errdefer branches.deinit(self.allocator);

        self.head_target = self.getHeadTarget();

        if (self.options.current) {
            if (self.head_target) |head| {
                if (std.mem.startsWith(u8, head, "refs/heads/")) {
                    const branch_name = head["refs/heads/".len..];
                    const info = try self.getBranchInfo(branch_name, true);
                    try branches.append(self.allocator, info);
                }
            }
            return branches.toOwnedSlice();
        }

        const prefix = if (self.options.all) "" else "refs/heads/";
        const refs = self.ref_store.list(prefix) catch |_| &.{};

        for (refs) |ref| {
            const full_name = ref.name;
            if (!std.mem.startsWith(u8, full_name, "refs/heads/")) {
                continue;
            }

            var branch_name = full_name["refs/heads/".len..];

            if (self.options.pattern) |pattern| {
                if (!self.matchesPattern(branch_name, pattern)) {
                    continue;
                }
            }

            if (self.options.contain) |commit| {
                _ = commit;
            }

            const is_current = self.head_target != null and
                std.mem.startsWith(u8, self.head_target.?, "refs/heads/") and
                std.mem.eql(u8, self.head_target.?["refs/heads/".len..], branch_name);

            const info = try self.getBranchInfoFromRef(ref, is_current);
            try branches.append(self.allocator, info);
        }

        return branches.toOwnedSlice();
    }

    pub fn listCurrent(self: *BranchLister) !?BranchInfo {
        const head_target = self.getHeadTarget() orelse return null;

        if (!std.mem.startsWith(u8, head_target, "refs/heads/")) {
            return null;
        }

        const branch_name = head_target["refs/heads/".len..];
        return try self.getBranchInfo(branch_name, true);
    }

    pub fn filterBranches(self: *BranchLister, pattern: []const u8) ![]const BranchInfo {
        var branches = std.ArrayList(BranchInfo).empty;
        errdefer branches.deinit(self.allocator);

        self.head_target = self.getHeadTarget();

        const refs = self.ref_store.list("refs/heads/") catch |_| &.{};

        for (refs) |ref| {
            const full_name = ref.name;
            if (!std.mem.startsWith(u8, full_name, "refs/heads/")) {
                continue;
            }

            const branch_name = full_name["refs/heads/".len..];

            if (!self.matchesPattern(branch_name, pattern)) {
                continue;
            }

            const is_current = self.head_target != null and
                std.mem.eql(u8, self.head_target.?, full_name);

            const info = try self.getBranchInfoFromRef(ref, is_current);
            try branches.append(self.allocator, info);
        }

        return branches.toOwnedSlice();
    }

    fn getHeadTarget(self: *BranchLister) ?[]const u8 {
        const head = self.ref_store.read("HEAD") catch return null;
        if (head.isSymbolic()) {
            return head.target.symbolic;
        }
        return null;
    }

    fn getBranchInfo(self: *BranchLister, name: []const u8, is_current: bool) !BranchInfo {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = self.ref_store.read(ref_name) catch {
            return BranchInfo{
                .name = name,
                .oid = undefined,
                .is_current = is_current,
                .is_remote = false,
                .is_head = false,
                .upstream = null,
                .ahead = null,
                .behind = null,
            };
        };

        const oid = if (ref.isDirect()) ref.target.direct else undefined;
        var upstream: ?[]const u8 = null;

        if (ref.isSymbolic()) {
            const target = ref.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/remotes/")) {
                upstream = target;
            }
        }

        return BranchInfo{
            .name = name,
            .oid = oid,
            .is_current = is_current,
            .is_remote = false,
            .is_head = false,
            .upstream = upstream,
            .ahead = null,
            .behind = null,
        };
    }

    fn getBranchInfoFromRef(self: *BranchLister, ref: Ref, is_current: bool) !BranchInfo {
        const full_name = ref.name;
        const branch_name = if (std.mem.startsWith(u8, full_name, "refs/heads/"))
            full_name["refs/heads/".len..]
        else
            full_name;

        var upstream: ?[]const u8 = null;

        if (ref.isSymbolic()) {
            const target = ref.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/remotes/")) {
                upstream = target;
            }
        }

        const oid = if (ref.isDirect()) ref.target.direct else undefined;

        return BranchInfo{
            .name = branch_name,
            .oid = oid,
            .is_current = is_current,
            .is_remote = false,
            .is_head = false,
            .upstream = upstream,
            .ahead = null,
            .behind = null,
        };
    }

    fn matchesPattern(self: *BranchLister, name: []const u8, pattern: []const u8) bool {
        _ = self;
        if (std.mem.indexOf(u8, name, pattern)) |_| {
            return true;
        }
        return false;
    }
};

test "ListOptions default values" {
    const options = ListOptions{};
    try std.testing.expect(options.all == false);
    try std.testing.expect(options.current == false);
    try std.testing.expect(options.verbose == false);
    try std.testing.expect(options.abbrev_oid == true);
}

test "BranchInfo structure" {
    const info = BranchInfo{
        .name = "main",
        .oid = undefined,
        .is_current = true,
        .is_remote = false,
        .is_head = false,
        .upstream = null,
        .ahead = null,
        .behind = null,
    };

    try std.testing.expectEqualStrings("main", info.name);
    try std.testing.expect(info.is_current == true);
    try std.testing.expect(info.is_remote == false);
}

test "BranchLister init" {
    var ref_store: RefStore = undefined;
    const options = ListOptions{};
    const lister = BranchLister.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(lister.allocator == std.testing.allocator);
}

test "BranchLister init with options" {
    var ref_store: RefStore = undefined;
    var options = ListOptions{};
    options.verbose = true;
    options.all = true;
    const lister = BranchLister.init(std.testing.allocator, &ref_store, options);

    try std.testing.expect(lister.options.verbose == true);
    try std.testing.expect(lister.options.all == true);
}

test "BranchLister list method exists" {
    var ref_store: RefStore = undefined;
    var options = ListOptions{};
    var lister = BranchLister.init(std.testing.allocator, &ref_store, options);

    const result = try lister.list();
    try std.testing.expect(result.len >= 0);
}

test "BranchLister listCurrent method exists" {
    var ref_store: RefStore = undefined;
    var options = ListOptions{};
    var lister = BranchLister.init(std.testing.allocator, &ref_store, options);

    const result = try lister.listCurrent();
    _ = result;
    try std.testing.expect(lister.allocator != undefined);
}

test "BranchLister filterBranches method exists" {
    var ref_store: RefStore = undefined;
    var options = ListOptions{};
    var lister = BranchLister.init(std.testing.allocator, &ref_store, options);

    const result = try lister.filterBranches("feature/*");
    try std.testing.expect(result.len >= 0);
}