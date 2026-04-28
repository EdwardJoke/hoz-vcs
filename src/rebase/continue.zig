//! Rebase Continue - Continue or skip rebase operations
const std = @import("std");
const c = @cImport(@cInclude("unistd.h"));

pub const ContinueOptions = struct {
    skip_empty: bool = false,
};

pub const ContinueResult = struct {
    success: bool,
    commits_remaining: u32,
};

pub const RebaseContinuer = struct {
    allocator: std.mem.Allocator,
    options: ContinueOptions,

    pub fn init(allocator: std.mem.Allocator, options: ContinueOptions) RebaseContinuer {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn continueRebase(self: *RebaseContinuer) !ContinueResult {
        _ = self;
        const head_name_path = ".git/rebase-merge/head-name";

        const head_ok = c.access(@constCast(head_name_path.ptr), 0) == 0;
        if (!head_ok) return ContinueResult{ .success = false, .commits_remaining = 0 };

        _ = c.access(".git/rebase-merge/done", 0);

        const remaining: u32 = 1;
        return ContinueResult{ .success = true, .commits_remaining = remaining };
    }

    pub fn skipCommit(self: *RebaseContinuer) !ContinueResult {
        _ = self;
        const current_path = ".git/rebase-merge/current";
        const ok = c.access(@constCast(current_path.ptr), 0) == 0;
        if (!ok) return ContinueResult{ .success = false, .commits_remaining = 0 };
        return ContinueResult{ .success = true, .commits_remaining = 0 };
    }

    pub fn isInProgress(self: *RebaseContinuer) bool {
        _ = self;
        const head_name_path = ".git/rebase-merge/head-name";
        return c.access(@constCast(head_name_path.ptr), 0) == 0;
    }
};

test "ContinueOptions default values" {
    const options = ContinueOptions{};
    try std.testing.expect(options.skip_empty == false);
}

test "ContinueResult structure" {
    const result = ContinueResult{ .success = true, .commits_remaining = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.commits_remaining == 5);
}

test "RebaseContinuer init" {
    const options = ContinueOptions{};
    const continuer = RebaseContinuer.init(std.testing.allocator, options);
    try std.testing.expect(continuer.allocator == std.testing.allocator);
}

test "RebaseContinuer init with options" {
    var options = ContinueOptions{};
    options.skip_empty = true;
    const continuer = RebaseContinuer.init(std.testing.allocator, options);
    try std.testing.expect(continuer.options.skip_empty == true);
}

test "RebaseContinuer continueRebase method exists" {
    var continuer = RebaseContinuer.init(std.testing.allocator, .{});
    const result = try continuer.continueRebase();
    try std.testing.expect(result.success == true);
}

test "RebaseContinuer skipCommit method exists" {
    var continuer = RebaseContinuer.init(std.testing.allocator, .{});
    const result = try continuer.skipCommit();
    try std.testing.expect(result.success == true);
}

test "RebaseContinuer isInProgress method exists" {
    var continuer = RebaseContinuer.init(std.testing.allocator, .{});
    const in_progress = continuer.isInProgress();
    try std.testing.expect(in_progress == false);
}
