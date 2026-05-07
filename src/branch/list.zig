//! Branch List - List branches
const std = @import("std");
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const Io = std.Io;
const compress_mod = @import("../compress/zlib.zig");

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
    oid: ?OID,
    is_current: bool,
    is_remote: bool,
    is_head: bool,
    upstream: ?[]const u8,
    ahead: ?u32,
    behind: ?u32,
};

pub const BranchLister = struct {
    allocator: std.mem.Allocator,
    io: Io,
    ref_store: *RefStore,
    options: ListOptions,
    head_target: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, ref_store: *RefStore, options: ListOptions) BranchLister {
        return .{
            .allocator = allocator,
            .io = io,
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
            return try branches.toOwnedSlice(self.allocator);
        }

        const prefix = if (self.options.all) "" else "refs/heads/";
        const refs = self.ref_store.list(prefix) catch @as([]const Ref, &.{});

        for (refs) |ref| {
            const full_name = ref.name;
            if (!std.mem.startsWith(u8, full_name, "refs/heads/")) {
                continue;
            }

            const branch_name = full_name["refs/heads/".len..];
            const branch_ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch_name});
            defer self.allocator.free(branch_ref_name);

            if (self.options.pattern) |pattern| {
                if (!self.matchesPattern(branch_name, pattern)) {
                    continue;
                }
            }

            if (self.options.contain) |commit| {
                const contain_ref = self.ref_store.read(branch_ref_name) catch continue;
                if (!contain_ref.isDirect()) continue;

                const branch_oid = contain_ref.target.direct;
                const commit_oid = OID.fromHex(commit) catch continue;

                if (branch_oid.eql(commit_oid)) {} else {
                    const contains = self.isAncestor(commit_oid, branch_oid) catch continue;
                    if (!contains) continue;
                }
            }

            const is_current = self.head_target != null and
                std.mem.startsWith(u8, self.head_target.?, "refs/heads/") and
                std.mem.eql(u8, self.head_target.?["refs/heads/".len..], branch_name);

            const info = try self.getBranchInfoFromRef(ref, is_current);
            try branches.append(self.allocator, info);
        }

        return try branches.toOwnedSlice(self.allocator);
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

        const refs = self.ref_store.list("refs/heads/") catch @as([]const Ref, &.{});

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

        return branches.toOwnedSlice(self.allocator);
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
                .oid = null,
                .is_current = is_current,
                .is_remote = false,
                .is_head = false,
                .upstream = null,
                .ahead = null,
                .behind = null,
            };
        };

        const oid = if (ref.isDirect()) ref.target.direct else null;
        var upstream: ?[]const u8 = null;
        var ahead: ?u32 = null;
        var behind: ?u32 = null;

        if (ref.isSymbolic()) {
            const target = ref.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/remotes/")) {
                upstream = target;
                if (oid) |o| {
                    const tracking = self.computeAheadBehind(o, target) catch null;
                    if (tracking) |t| {
                        ahead = t.ahead;
                        behind = t.behind;
                    }
                }
            }
        }

        return BranchInfo{
            .name = name,
            .oid = oid,
            .is_current = is_current,
            .is_remote = false,
            .is_head = false,
            .upstream = upstream,
            .ahead = ahead,
            .behind = behind,
        };
    }

    fn getBranchInfoFromRef(self: *BranchLister, ref: Ref, is_current: bool) !BranchInfo {
        const full_name = ref.name;
        const branch_name = if (std.mem.startsWith(u8, full_name, "refs/heads/"))
            full_name["refs/heads/".len..]
        else
            full_name;

        var upstream: ?[]const u8 = null;
        var ahead: ?u32 = null;
        var behind: ?u32 = null;

        if (ref.isSymbolic()) {
            const target = ref.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/remotes/")) {
                upstream = target;
            }
        }

        const oid = if (ref.isDirect()) ref.target.direct else null;

        if (upstream != null) {
            if (oid) |o| {
                const tracking = self.computeAheadBehind(o, upstream.?) catch null;
                if (tracking) |t| {
                    ahead = t.ahead;
                    behind = t.behind;
                }
            }
        }

        return BranchInfo{
            .name = branch_name,
            .oid = oid,
            .is_current = is_current,
            .is_remote = false,
            .is_head = false,
            .upstream = upstream,
            .ahead = ahead,
            .behind = behind,
        };
    }

    fn computeAheadBehind(self: *BranchLister, branch_oid: OID, upstream_ref: []const u8) !struct { ahead: u32, behind: u32 } {
        const upstream_ref_resolved = try self.ref_store.resolve(upstream_ref);
        const upstream_oid = if (upstream_ref_resolved.isDirect()) upstream_ref_resolved.target.direct else return .{ .ahead = 0, .behind = 0 };

        if (branch_oid.eql(upstream_oid)) {
            return .{ .ahead = 0, .behind = 0 };
        }

        var branch_reachable = std.array_hash_map.String(void).empty;
        defer branch_reachable.deinit(self.allocator);
        _ = self.collectReachable(&branch_oid.toHex(), &branch_reachable) catch 0;

        var upstream_reachable = std.array_hash_map.String(void).empty;
        defer upstream_reachable.deinit(self.allocator);
        _ = self.collectReachable(&upstream_oid.toHex(), &upstream_reachable) catch 0;

        var ahead: u32 = 0;
        var behind: u32 = 0;

        var branch_it = branch_reachable.iterator();
        while (branch_it.next()) |entry| {
            if (!upstream_reachable.contains(entry.key_ptr.*)) {
                ahead += 1;
            }
        }

        var upstream_it = upstream_reachable.iterator();
        while (upstream_it.next()) |entry| {
            if (!branch_reachable.contains(entry.key_ptr.*)) {
                behind += 1;
            }
        }

        return .{ .ahead = ahead, .behind = behind };
    }

    fn collectReachable(self: *BranchLister, start_oid: []const u8, visited: *std.array_hash_map.String(void)) !u32 {
        if (start_oid.len < 40) return 0;
        if (visited.contains(start_oid)) return 0;

        visited.put(self.allocator, start_oid, {}) catch return 0;

        const parents = self.getParentOids(start_oid) catch &.{};
        defer {
            for (parents) |p| self.allocator.free(p);
            self.allocator.free(parents);
        }

        var count: u32 = 1;
        for (parents) |parent| {
            count += try self.collectReachable(parent, visited);
        }
        return count;
    }

    fn matchesPattern(self: *BranchLister, name: []const u8, pattern: []const u8) bool {
        _ = self;
        if (std.mem.indexOf(u8, name, pattern)) |_| {
            return true;
        }
        return false;
    }

    fn isAncestor(self: *BranchLister, ancestor_oid: OID, descendant_oid: OID) !bool {
        if (ancestor_oid.eql(descendant_oid)) {
            return true;
        }

        var visited = std.array_hash_map.String(void).empty;
        defer visited.deinit(self.allocator);

        var current = try self.allocator.dupe(u8, &descendant_oid.toHex());
        defer self.allocator.free(current);

        var depth: u32 = 0;
        while (depth < 10000) : (depth += 1) {
            if (visited.contains(current)) break;
            visited.put(self.allocator, current, {}) catch break;

            if (std.mem.eql(u8, current, &ancestor_oid.toHex())) {
                return true;
            }

            const parents = self.getParentOids(current) catch &.{};
            defer {
                for (parents) |p| self.allocator.free(p);
                self.allocator.free(parents);
            }

            if (parents.len == 0) break;
            self.allocator.free(current);
            current = try self.allocator.dupe(u8, parents[0]);
        }
        return false;
    }

    fn getParentOids(self: *BranchLister, oid_str: []const u8) ![][]const u8 {
        if (oid_str.len < 40) return &.{};

        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{ oid_str[0..2], oid_str[2..40] });
        defer self.allocator.free(obj_path);

        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(self.io, obj_path, .{}) catch return &.{};
        defer file.close(self.io);

        var reader = file.reader(self.io, &.{});
        const compressed = try reader.interface.allocRemaining(self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(compressed);

        const data = compress_mod.Zlib.decompress(compressed, self.allocator) catch return &.{};
        defer self.allocator.free(data);

        var parents = std.ArrayList([]const u8).empty;
        errdefer {
            for (parents.items) |p| self.allocator.free(p);
            parents.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, '\n');
        _ = iter.next();
        while (iter.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) break;
            const parent_oid = line["parent ".len..];
            if (parent_oid.len >= 40) {
                try parents.append(self.allocator, try self.allocator.dupe(u8, parent_oid[0..40]));
            }
        }

        return parents.toOwnedSlice(self.allocator);
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
        .oid = null,
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
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    const options = ListOptions{};
    const lister = BranchLister.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(lister.options.all == false);
}

test "BranchLister init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const store = RefStore{
        .git_dir = undefined,
        .allocator = std.testing.allocator,
        .io = io,
        .odb = null,
    };
    var options = ListOptions{};
    options.verbose = true;
    options.all = true;
    const lister = BranchLister.init(std.testing.allocator, io, &store, options);

    try std.testing.expect(lister.options.verbose == true);
    try std.testing.expect(lister.options.all == true);
}

test "BranchLister has list method" {
    const Lister = BranchLister;
    try std.testing.expect(@hasDecl(Lister, "list"));
}

test "BranchLister has listCurrent method" {
    const Lister = BranchLister;
    try std.testing.expect(@hasDecl(Lister, "listCurrent"));
}

test "BranchLister has filterBranches method" {
    const Lister = BranchLister;
    try std.testing.expect(@hasDecl(Lister, "filterBranches"));
}
