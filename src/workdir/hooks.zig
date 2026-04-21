//! Hooks - Git-style hook system for Hoz VCS
//!
//! This module provides a hook system for triggering actions on repository events.
//! Hooks are executables stored in .git/hooks that can be triggered by various VCS operations.

const std = @import("std");
const Io = std.Io;

pub const HookType = enum {
    pre_commit,
    prepare_commit_msg,
    commit_msg,
    post_commit,
    pre_rebase,
    pre_push,
    post_checkout,
    post_merge,
    pre_receive,
    update,
    post_receive,
    post_update,
    push_to_checkout,
    reference_transaction,
    sendemail_validation,
};

pub const HookResult = struct {
    success: bool,
    exit_code: u32,
    output: []u8,
};

pub const HookOptions = struct {
    verbose: bool = false,
    quiet: bool = false,
    timeout_ms: u32 = 30000,
};

pub const HookEnvironment = struct {
    pub const HOZ_HOOK_NAME = "HOZ_HOOK_NAME";
    pub const HOZ_HOOK_PATH = "HOZ_HOOK_PATH";
    pub const HOZ_HOOK_ARG1 = "HOZ_HOOK_ARG1";
    pub const HOZ_HOOK_ARG2 = "HOZ_HOOK_ARG2";
    pub const HOZ_HOOK_ARG3 = "HOZ_HOOK_ARG3";
    pub const HOZ_HOOK_STDIN = "HOZ_HOOK_STDIN";
};

pub fn hookNameToString(hook_type: HookType) []const u8 {
    return switch (hook_type) {
        .pre_commit => "pre-commit",
        .prepare_commit_msg => "prepare-commit-msg",
        .commit_msg => "commit-msg",
        .post_commit => "post-commit",
        .pre_rebase => "pre-rebase",
        .pre_push => "pre-push",
        .post_checkout => "post-checkout",
        .post_merge => "post-merge",
        .pre_receive => "pre-receive",
        .update => "update",
        .post_receive => "post-receive",
        .post_update => "post-update",
        .push_to_checkout => "push-to-checkout",
        .reference_transaction => "reference-transaction",
        .sendemail_validation => "sendemail-validation",
    };
}

pub fn getHookPath(git_dir: []const u8, hook_type: HookType) []const u8 {
    const hook_name = hookNameToString(hook_type);
    return std.mem.concat(std.heap.page_allocator, u8, &.{ git_dir, "/hooks/", hook_name }) catch &.{};
}

pub fn hookExists(git_dir: []const u8, hook_type: HookType) bool {
    const path = getHookPath(git_dir, hook_type);
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

pub fn runHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    hook_type: HookType,
    args: []const []const u8,
    stdin_input: ?[]const u8,
    options: HookOptions,
) !HookResult {
    const hook_path = getHookPath(git_dir, hook_type);

    const file = std.fs.cwd().openFile(hook_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return HookResult{
                .success = true,
                .exit_code = 0,
                .output = &.{},
            };
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.mode & 0o111 == 0) {
        return HookResult{
            .success = true,
            .exit_code = 0,
            .output = &.{},
        };
    }

    var child = try std.process.spawn(io, .{
        .argv = &.{
            std.mem.sliceTo(&hook_path, 0),
        } ++ args,
        .stdin = if (stdin_input) |_| .pipe else .none,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (stdin_input) |input| {
        try child.stdin.?.writeAll(io, input);
        child.stdin.?.close();
    }

    const exit_code = child.wait();
    const output = child.stdout.?.readAllAlloc(allocator, 1024 * 1024) catch &.{};
    const stderr = child.stderr.?.readAllAlloc(allocator, 1024 * 1024) catch &.{};

    var combined_output = std.ArrayList(u8).init(allocator);
    try combined_output.appendSlice(output);
    if (stderr.len > 0) {
        try combined_output.appendSlice(stderr);
    }

    return HookResult{
        .success = exit_code == .exited and exit_code.code == 0,
        .exit_code = if (exit_code == .exited) exit_code.code else 1,
        .output = try combined_output.toOwnedSlice(),
    };
}

pub fn runPreCommitHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    options: HookOptions,
) !HookResult {
    return runHook(io, allocator, git_dir, .pre_commit, &.{}, null, options);
}

pub fn runPostCommitHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    options: HookOptions,
) !HookResult {
    return runHook(io, allocator, git_dir, .post_commit, &.{}, null, options);
}

pub fn runPrePushHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    remote: []const u8,
    url: []const u8,
    options: HookOptions,
) !HookResult {
    const stdin_input = std.mem.concat(allocator, u8, &.{ remote, "\n", url, "\n" }) catch return error.OutOfMemory;
    defer allocator.free(stdin_input);
    return runHook(io, allocator, git_dir, .pre_push, &.{ remote, url }, stdin_input, options);
}

pub fn runPostCheckoutHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    prev_ref: []const u8,
    new_ref: []const u8,
    flag: bool,
    options: HookOptions,
) !HookResult {
    const flag_str: []const u8 = if (flag) "1" else "0";
    return runHook(io, allocator, git_dir, .post_checkout, &.{ prev_ref, new_ref, flag_str }, null, options);
}

pub fn runPostMergeHook(
    io: *Io,
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    squash: bool,
    options: HookOptions,
) !HookResult {
    const flag_str: []const u8 = if (squash) "1" else "0";
    return runHook(io, allocator, git_dir, .post_merge, &.{flag_str}, null, options);
}

test "hookNameToString" {
    try std.testing.expectEqualStrings("pre-commit", hookNameToString(.pre_commit));
    try std.testing.expectEqualStrings("post-commit", hookNameToString(.post_commit));
    try std.testing.expectEqualStrings("commit-msg", hookNameToString(.commit_msg));
}

test "hookExists returns false for non-existent hook" {
    const exists = hookExists("/nonexistent/.git", .pre_commit);
    try std.testing.expect(!exists);
}
