//! Error Messages - Polish error messages for user-friendliness
const std = @import("std");

pub const ErrorPolisher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ErrorPolisher {
        return .{ .allocator = allocator };
    }

    pub fn polish(self: *ErrorPolisher, err: ErrorType) []const u8 {
        _ = self;
        switch (err) {
            .not_a_repo => return "fatal: not a git repository",
            .invalid_path => return "error: invalid path",
            .file_not_found => return "error: file not found",
            .permission_denied => return "error: permission denied",
            .merge_conflict => return "error: merge conflict",
            .detached_head => return "error: detached HEAD state",
            .invalid_ref => return "error: invalid reference",
            .branch_exists => return "error: branch already exists",
            .no_commits => return "error: your current branch does not have any commits yet",
            .up_to_date => return "Already up to date.",
            .fast_forward => return "Fast-forward",
            .unknown_command => return "error: unknown command",
        }
    }

    pub const ErrorType = enum {
        not_a_repo,
        invalid_path,
        file_not_found,
        permission_denied,
        merge_conflict,
        detached_head,
        invalid_ref,
        branch_exists,
        no_commits,
        up_to_date,
        fast_forward,
        unknown_command,
    };
};

test "ErrorPolisher init" {
    const polisher = ErrorPolisher.init(std.testing.allocator);
    try std.testing.expect(polisher.allocator == std.testing.allocator);
}

test "ErrorPolisher polish" {
    const polisher = ErrorPolisher.init(std.testing.allocator);
    const msg = polisher.polish(.not_a_repo);
    try std.testing.expectEqualStrings("fatal: not a git repository", msg);
}

test "ErrorPolisher all error types" {
    const polisher = ErrorPolisher.init(std.testing.allocator);
    try std.testing.expectEqualStrings("error: file not found", polisher.polish(.file_not_found));
    try std.testing.expectEqualStrings("error: merge conflict", polisher.polish(.merge_conflict));
    try std.testing.expectEqualStrings("error: branch already exists", polisher.polish(.branch_exists));
}