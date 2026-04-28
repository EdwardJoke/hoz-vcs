//! Fetch Prune - Prune stale remote tracking branches
const std = @import("std");
const Io = std.Io;

pub const PruneOptions = struct {
    dry_run: bool = false,
    verbose: bool = false,
    prune_timeout_days: u32 = 14,
};

pub const PruneResult = struct {
    success: bool,
    branches_pruned: u32,
    branches_remaining: u32,
    errors: u32,
};

pub const StaleBranch = struct {
    name: []const u8,
    remote: []const u8,
    last_fetch: i64,
    reason: []const u8,
};

pub const FetchPruner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: PruneOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: PruneOptions) FetchPruner {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn prune(self: *FetchPruner) !PruneResult {
        const stale_refs = try self.findStaleBranches("origin");
        defer self.allocator.free(stale_refs);
        return PruneResult{ .success = true, .branches_pruned = @intCast(stale_refs.len), .branches_remaining = 0, .errors = 0 };
    }

    pub fn pruneRemote(self: *FetchPruner, remote: []const u8) !PruneResult {
        if (remote.len == 0) {
            return PruneResult{ .success = false, .branches_pruned = 0, .branches_remaining = 0, .errors = 1 };
        }

        const stale_refs = try self.findStaleBranches(remote);
        defer self.allocator.free(stale_refs);

        var pruned: u32 = 0;
        var errors: u32 = 0;

        for (stale_refs) |ref| {
            if (self.options.dry_run) {
                pruned += 1;
            } else {
                const success = self.deleteStaleBranch(ref);
                if (success) {
                    pruned += 1;
                } else {
                    errors += 1;
                }
            }
        }

        return PruneResult{
            .success = errors == 0,
            .branches_pruned = pruned,
            .branches_remaining = @as(u32, @intCast(stale_refs.len)) - pruned,
            .errors = errors,
        };
    }

    pub fn pruneMatching(self: *FetchPruner, pattern: []const u8) !PruneResult {
        if (pattern.len == 0) {
            return PruneResult{ .success = false, .branches_pruned = 0, .branches_remaining = 0, .errors = 1 };
        }

        const stale_refs = try self.findMatchingStaleBranches(pattern);
        defer self.allocator.free(stale_refs);

        var pruned: u32 = 0;
        var errors: u32 = 0;

        for (stale_refs) |ref| {
            if (self.options.dry_run) {
                pruned += 1;
            } else {
                const success = self.deleteStaleBranch(ref);
                if (success) {
                    pruned += 1;
                } else {
                    errors += 1;
                }
            }
        }

        return PruneResult{
            .success = errors == 0,
            .branches_pruned = pruned,
            .branches_remaining = @as(u32, @intCast(stale_refs.len)) - pruned,
            .errors = errors,
        };
    }

    pub fn findStaleBranches(self: *FetchPruner, remote: []const u8) ![]const StaleBranch {
        var result = std.ArrayList(StaleBranch).empty;
        errdefer {
            for (result.items) |*r| {
                self.allocator.free(r.name);
                self.allocator.free(r.remote);
                self.allocator.free(r.reason);
            }
            result.deinit(self.allocator);
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return &[_]StaleBranch{};
        defer git_dir.close(self.io);

        const remote_path = std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{remote}) catch return &[_]StaleBranch{};
        defer self.allocator.free(remote_path);

        const refs_dir = git_dir.openDir(self.io, remote_path, .{}) catch return &[_]StaleBranch{};
        defer refs_dir.close(self.io);

        var walker = refs_dir.walk(self.allocator) catch return &[_]StaleBranch{};
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;

            const ref_mtime = refs_dir.statFile(self.io, entry.path) catch continue;
            const last_fetch: i64 = @intCast(ref_mtime.mtime.sec);
            const current_time: i64 = @intCast(std.time.timestamp());

            if (!self.isBranchStale(last_fetch, current_time)) continue;

            const name_copy = self.allocator.dupe(u8, entry.basename) catch continue;
            errdefer self.allocator.free(name_copy);
            const remote_copy = self.allocator.dupe(u8, remote) catch {
                self.allocator.free(name_copy);
                continue;
            };
            errdefer self.allocator.free(remote_copy);
            const reason = self.allocator.dupe(u8, "stale") catch {
                self.allocator.free(name_copy);
                self.allocator.free(remote_copy);
                continue;
            };

            try result.append(self.allocator, .{
                .name = name_copy,
                .remote = remote_copy,
                .last_fetch = last_fetch,
                .reason = reason,
            });
        }

        return result.toOwnedSlice(self.allocator);
    }

    pub fn findMatchingStaleBranches(self: *FetchPruner, pattern: []const u8) ![]const StaleBranch {
        const all_stale = try self.findStaleBranches("origin");
        errdefer {
            for (all_stale) |*r| {
                self.allocator.free(r.name);
                self.allocator.free(r.remote);
                self.allocator.free(r.reason);
            }
            self.allocator.free(all_stale);
        }

        var matched = std.ArrayList(StaleBranch).empty;
        errdefer {
            for (matched.items) |*r| {
                self.allocator.free(r.name);
                self.allocator.free(r.remote);
                self.allocator.free(r.reason);
            }
            matched.deinit(self.allocator);
        }

        for (all_stale) |branch| {
            if (self.globMatch(branch.name, pattern)) {
                const name_copy = self.allocator.dupe(u8, branch.name) catch continue;
                const remote_copy = self.allocator.dupe(u8, branch.remote) catch {
                    self.allocator.free(name_copy);
                    continue;
                };
                const reason_copy = self.allocator.dupe(u8, branch.reason) catch {
                    self.allocator.free(name_copy);
                    self.allocator.free(remote_copy);
                    continue;
                };
                try matched.append(self.allocator, .{
                    .name = name_copy,
                    .remote = remote_copy,
                    .last_fetch = branch.last_fetch,
                    .reason = reason_copy,
                });
            }
        }

        for (all_stale) |*r| {
            self.allocator.free(r.name);
            self.allocator.free(r.remote);
            self.allocator.free(r.reason);
        }
        self.allocator.free(all_stale);

        return matched.toOwnedSlice(self.allocator);
    }

    pub fn deleteStaleBranch(self: *FetchPruner, branch: StaleBranch) bool {
        if (branch.name.len == 0) return false;

        const cwd = Io.Dir.cwd();
        const ref_path = std.fmt.allocPrint(self.allocator, ".git/refs/remotes/{s}/{s}", .{ branch.remote, branch.name }) catch return false;
        defer self.allocator.free(ref_path);

        cwd.deleteFile(self.io, ref_path) catch return false;
        return true;
    }

    pub fn isBranchStale(self: *FetchPruner, last_fetch: i64, current_time: i64) bool {
        const age_days = @divFloor(current_time - last_fetch, 86400);
        return @as(u32, @intCast(age_days)) >= self.options.prune_timeout_days;
    }

    fn globMatch(self: *FetchPruner, text: []const u8, pattern: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, pattern, "*")) return true;
        if (std.mem.endsWith(u8, pattern, "*")) {
            return std.mem.startsWith(u8, text, pattern[0 .. pattern.len - 1]);
        }
        if (std.mem.startsWith(u8, pattern, "*")) {
            return std.mem.endsWith(u8, text, pattern[1..]);
        }
        return std.mem.eql(u8, text, pattern);
    }
};

pub fn pruneStaleRefs(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, remote_name: []const u8, remote_refs: []const []const u8) !u32 {
    var local_refs = std.ArrayList([]const u8).initCapacity(allocator, 64) catch |err| return err;
    defer {
        for (local_refs.items) |ref| allocator.free(ref);
        local_refs.deinit(allocator);
    }

    const cwd = Io.Dir.cwd();
    const refs_dir = try std.mem.concat(allocator, u8, &.{ git_dir, "/refs/remotes/" });
    defer allocator.free(refs_dir);

    try collectRefsFromDir(cwd, io, allocator, refs_dir, remote_name, &local_refs);

    var pruned_count: u32 = 0;

    for (local_refs.items) |local_ref| {
        const is_stale = for (remote_refs) |remote_ref| {
            if (std.mem.eql(u8, local_ref, remote_ref)) break false;
        } else true;

        if (is_stale) {
            const ref_path = try std.mem.concat(allocator, u8, &.{ git_dir, "/", local_ref });
            cwd.deleteFile(io, ref_path) catch {};
            allocator.free(ref_path);
            pruned_count += 1;
        }
    }

    return pruned_count;
}

fn collectRefsFromDir(cwd: Io.Dir, io: Io, allocator: std.mem.Allocator, dir_path: []const u8, remote_name: []const u8, refs: *std.ArrayList([]const u8)) !void {
    const full_dir_path = try std.mem.concat(allocator, u8, &.{ dir_path, remote_name });
    defer allocator.free(full_dir_path);

    const dir = cwd.openDir(io, full_dir_path, .{}) catch return;
    _ = dir;
    _ = refs;
}

test "PruneOptions default values" {
    const options = PruneOptions{};
    try std.testing.expect(options.dry_run == false);
    try std.testing.expect(options.verbose == false);
}

test "PruneResult structure" {
    const result = PruneResult{ .success = true, .branches_pruned = 3, .branches_remaining = 5, .errors = 0 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.branches_pruned == 3);
    try std.testing.expect(result.branches_remaining == 5);
    try std.testing.expect(result.errors == 0);
}

test "FetchPruner init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    const options = PruneOptions{};
    const pruner = FetchPruner.init(std.testing.allocator, io, options);
    try std.testing.expect(pruner.allocator == std.testing.allocator);
}

test "FetchPruner init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var options = PruneOptions{};
    options.dry_run = true;
    options.verbose = true;
    const pruner = FetchPruner.init(std.testing.allocator, io, options);
    try std.testing.expect(pruner.options.dry_run == true);
}

test "FetchPruner prune method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var pruner = FetchPruner.init(std.testing.allocator, io, .{});
    const result = try pruner.prune();
    try std.testing.expect(result.success == true);
}

test "FetchPruner pruneRemote method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var pruner = FetchPruner.init(std.testing.allocator, io, .{});
    const result = try pruner.pruneRemote("origin");
    try std.testing.expect(result.success == true);
}

test "FetchPruner pruneMatching method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var pruner = FetchPruner.init(std.testing.allocator, io, .{});
    const result = try pruner.pruneMatching("refs/remotes/origin/*");
    try std.testing.expect(result.success == true);
}
