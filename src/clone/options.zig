//! Clone Options - Options for clone operations
const std = @import("std");

pub const CloneOptions = struct {
    bare: bool = false,
    depth: u32 = 0,
    single_branch: bool = false,
    no_checkout: bool = false,
    local: bool = true,
    recursive: bool = true,
};

pub const CloneResult = struct {
    success: bool,
    path: []const u8,
};

test "CloneOptions default values" {
    const options = CloneOptions{};
    try std.testing.expect(options.bare == false);
    try std.testing.expect(options.depth == 0);
    try std.testing.expect(options.single_branch == false);
}

test "CloneOptions bare clone" {
    var options = CloneOptions{};
    options.bare = true;
    try std.testing.expect(options.bare == true);
}

test "CloneOptions single branch" {
    var options = CloneOptions{};
    options.single_branch = true;
    try std.testing.expect(options.single_branch == true);
}

test "CloneOptions with depth" {
    var options = CloneOptions{};
    options.depth = 100;
    try std.testing.expect(options.depth == 100);
}

test "CloneResult structure" {
    const result = CloneResult{ .success = true, .path = "/path/to/repo" };
    try std.testing.expect(result.success == true);
    try std.testing.expectEqualStrings("/path/to/repo", result.path);
}