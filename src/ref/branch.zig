//! Branch management for Hoz
const std = @import("std");
const Io = std.Io;
const RefStore = @import("store.zig").RefStore;
const Ref = @import("ref.zig").Ref;
const RefError = @import("ref.zig").RefError;
const Oid = @import("../object/oid.zig").Oid;
const Commit = @import("../object/commit.zig").Commit;

pub const BranchError = error{
    UpstreamNotFound,
    RemoteNotConfigured,
    InvalidBranchName,
} || RefError;

pub const BranchTracking = struct {
    branch: []const u8,
    upstream: ?[]const u8,
    remote: ?[]const u8,
};

pub const BranchManager = struct {
    store: *RefStore,
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    config: ?*const anyopaque,

    pub fn init(store: *RefStore, allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) BranchManager {
        return .{
            .store = store,
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .config = null,
        };
    }

    pub fn create(self: BranchManager, name: []const u8, oid: Oid) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.directRef(ref_name, oid);
        try self.store.write(ref);
    }

    pub fn createFromRef(self: BranchManager, name: []const u8, target: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        const ref = Ref.symbolicRef(ref_name, target);
        try self.store.write(ref);
    }

    pub fn get(self: BranchManager, name: []const u8) RefError!Ref {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        return self.store.read(ref_name);
    }

    pub fn exists(self: BranchManager, name: []const u8) bool {
        const ref_name = std.fmt.comptimePrint("refs/heads/{s}", .{name});
        return self.store.exists(ref_name);
    }

    pub fn delete(self: BranchManager, name: []const u8) RefError!void {
        const ref_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{name});
        defer self.allocator.free(ref_name);

        try self.store.delete(ref_name);
    }

    pub fn list(self: BranchManager) RefError![]const Ref {
        return self.store.list("refs/heads/");
    }

    pub fn current(self: BranchManager) RefError!?[]const u8 {
        const head = self.store.read("HEAD") catch {
            return null;
        };

        if (head.isSymbolic()) {
            const target = head.target.symbolic;
            if (std.mem.startsWith(u8, target, "refs/heads/")) {
                return target["refs/heads/".len..];
            }
            return target;
        }

        return null;
    }

    fn getConfigKey(self: BranchManager, branch_name: []const u8, key: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "branch \"{s}\" {s}", .{ branch_name, key });
    }

    fn readConfigValue(self: BranchManager, config_key: []const u8) !?[]const u8 {
        const config_path = ".git/config";
        const content = self.git_dir.readFileAlloc(self.io, config_path, self.allocator, .limited(65536)) catch {
            return null;
        };
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
                var parts = std.mem.splitScalar(u8, trimmed, '=');
                if (const key = parts.next()) {
                    const value = parts.rest();
                    const trimmed_key = std.mem.trim(u8, key, " \t");
                    const trimmed_value = std.mem.trim(u8, value, " \t");
                    if (std.mem.eql(u8, trimmed_key, config_key)) {
                        return try self.allocator.dupe(u8, trimmed_value);
                    }
                }
            }
        }
        return null;
    }

    fn writeConfigValue(self: BranchManager, config_key: []const u8, value: []const u8) !void {
        const config_path = ".git/config";
        var existing_content = self.git_dir.readFileAlloc(self.io, config_path, self.allocator, .limited(65536)) catch null;
        defer if (existing_content) |c| self.allocator.free(c);

        var content_to_write: []const u8 = "";
        if (existing_content) |c| {
            content_to_write = c;
        }

        var lines = std.mem.splitScalar(u8, content_to_write, '\n');
        var new_lines = std.ArrayList(u8).init(self.allocator);
        errdefer new_lines.deinit();

        var found = false;
        var in_branch_section = false;

        const config_key_branch = std.fmt.comptimePrint("branch \"", .{});

        while (lines.next()) |line| {
            try new_lines.appendSlice(line);
            try new_lines.append('\n');

            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
                if (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]")) {
                    in_branch_section = false;
                }
                if (std.mem.startsWith(u8, trimmed, config_key_branch)) {
                    const bracket_idx = std.mem.indexOf(u8, trimmed, "\"");
                    const end_bracket_idx = if (bracket_idx) |bi| std.mem.indexOf(u8, trimmed[bi + 1 ..], "\"") else null;
                    if (bracket_idx != null and end_bracket_idx != null) {
                        in_branch_section = true;
                    }
                }
                if (in_branch_section) {
                    var parts = std.mem.splitScalar(u8, trimmed, '=');
                    if (const key = parts.next()) {
                        const trimmed_key = std.mem.trim(u8, key, " \t");
                        if (std.mem.eql(u8, trimmed_key, config_key)) {
                            found = true;
                        }
                    }
                }
            }
        }

        if (!found) {
            try new_lines.appendSlice("        ");
            try new_lines.appendSlice(config_key);
            try new_lines.append('=');
            try new_lines.appendSlice(value);
            try new_lines.append('\n');
        }

        self.git_dir.writeFile(self.io, .{ .sub_path = config_path, .data = new_lines.items }) catch {};
    }

    pub fn getUpstream(self: BranchManager, branch_name: []const u8) BranchError!?[]const u8 {
        const key = try self.getConfigKey(branch_name, "pushRemote");
        defer self.allocator.free(key);
        if (try self.readConfigValue(key)) |upstream| {
            return upstream;
        }

        const remote_key = try self.getConfigKey(branch_name, "remote");
        defer self.allocator.free(remote_key);
        if (try self.readConfigValue(remote_key)) |remote| {
            const merge_key = try self.getConfigKey(branch_name, "merge");
            defer self.allocator.free(merge_key);
            if (try self.readConfigValue(merge_key)) |merge| {
                const merge_ref = if (std.mem.startsWith(u8, merge, "refs/heads/"))
                    merge["refs/heads/".len..]
                else
                    merge;
                const upstream_ref = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}/{s}", .{ remote, merge_ref });
                defer self.allocator.free(upstream_ref);
                return upstream_ref;
            }
        }

        return null;
    }

    pub fn setUpstream(self: BranchManager, branch_name: []const u8, upstream: []const u8) BranchError!void {
        const remote_key = try self.getConfigKey(branch_name, "remote");
        defer self.allocator.free(remote_key);

        const merge_key = try self.getConfigKey(branch_name, "merge");
        defer self.allocator.free(merge_key);

        if (std.mem.startsWith(u8, upstream, "refs/remotes/")) {
            const rest = upstream["refs/remotes/".len..];
            if (const slash_idx = std.mem.indexOf(u8, rest, "/")) {
                const remote = rest[0..slash_idx];
                const branch = rest[slash_idx + 1..];
                try self.writeConfigValue(remote_key, remote);
                const merge_ref = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch});
                defer self.allocator.free(merge_ref);
                try self.writeConfigValue(merge_key, merge_ref);
                return;
            }
        }

        return error.InvalidUpstream;
    }

    pub fn getUpstreamStatus(self: BranchManager, branch_name: []const u8) BranchError!struct { ahead: u32, behind: u32 } {
        const upstream = try self.getUpstream(branch_name) orelse {
            return .{ .ahead = 0, .behind = 0 };
        };
        defer self.allocator.free(upstream);

        const local_ref = try self.store.read("refs/heads/" ++ branch_name);
        const local_oid = local_ref.getOid();

        const upstream_ref = self.store.read(upstream) catch {
            return .{ .ahead = 0, .behind = 0 };
        };
        const upstream_oid = upstream_ref.getOid();

        if (local_oid.eql(upstream_oid)) {
            return .{ .ahead = 0, .behind = 0 };
        }

        var ahead: u32 = 0;
        var behind: u32 = 0;

        var visited = std.AutoHashMap(Oid, void).init(self.allocator);
        defer visited.deinit();

        var to_visit = std.ArrayList(Oid).init(self.allocator);
        defer to_visit.deinit();

        try to_visit.append(local_oid);
        try visited.put(local_oid, {});

        while (to_visit.pop()) |oid| {
            if (oid.eql(upstream_oid)) continue;

            const commit_data = self.readCommitData(oid) catch {
                continue;
            };
            defer self.allocator.free(commit_data);

            for (commit_data.parents) |parent_oid| {
                if (parent_oid.eql(upstream_oid)) {
                    ahead +%= 1;
                } else if (!visited.contains(parent_oid)) {
                    try visited.put(parent_oid, {});
                    try to_visit.append(parent_oid);
                }
            }
        }

        visited = std.AutoHashMap(Oid, void).init(self.allocator);
        to_visit = std.ArrayList(Oid).init(self.allocator);

        try to_visit.append(upstream_oid);
        try visited.put(upstream_oid, {});

        while (to_visit.pop()) |oid| {
            if (oid.eql(local_oid)) continue;

            const commit_data = self.readCommitData(oid) catch {
                continue;
            };
            defer self.allocator.free(commit_data);

            for (commit_data.parents) |parent_oid| {
                if (parent_oid.eql(local_oid)) {
                    behind +%= 1;
                } else if (!visited.contains(parent_oid)) {
                    try visited.put(parent_oid, {});
                    try to_visit.append(parent_oid);
                }
            }
        }

        return .{ .ahead = ahead, .behind = behind };
    }

    fn readCommitData(self: BranchManager, oid: Oid) ![]const u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{
            hex[0..2], hex[2..40]
        });
        defer self.allocator.free(obj_path);

        return self.git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(65536)) catch {
            return error.ObjectNotFound;
        };
    }

    pub fn hasUpstream(self: BranchManager, branch_name: []const u8) bool {
        if (self.getUpstream(branch_name)) |_| {
            return true;
        } else |_| {
            return false;
        }
    }
};

test "BranchManager init" {
    try std.testing.expect(true);
}

test "BranchManager branch name format" {
    const name = "main";
    const expected = "refs/heads/main";
    const result = std.fmt.comptimePrint("refs/heads/{s}", .{name});
    try std.testing.expectEqualStrings(expected, result);
}
