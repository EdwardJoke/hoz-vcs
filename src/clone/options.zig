//! Clone Options - Options for clone operations
const std = @import("std");

pub const CloneOptions = struct {
    bare: bool = false,
    mirror: bool = false,
    depth: u32 = 0,
    single_branch: bool = false,
    no_checkout: bool = false,
    local: bool = true,
    recursive: bool = true,
    filter: ?FilterSpec = null,
};

pub const CloneFlags = struct {
    bare: bool = false,
    mirror: bool = false,
    single_branch: bool = false,
    no_checkout: bool = false,
    local: bool = true,
    recursive: bool = true,
};

pub const FilterSpec = struct {
    blob_filter: BlobFilter = .none,
    tree_depth: u32 = 0,
    allow_unavailable: bool = false,
};

pub const BlobFilter = enum {
    none,
    blob_limit,
    blob_type,
};

pub const CloneResult = struct {
    success: bool,
    path: []const u8,
    branch: ?[]const u8 = null,
};

pub fn defaultCloneOptions() CloneOptions {
    return .{};
}

pub fn cloneOptionsFromFlags(flags: CloneFlags) CloneOptions {
    return .{
        .bare = flags.bare,
        .mirror = flags.mirror,
        .single_branch = flags.single_branch,
        .no_checkout = flags.no_checkout,
        .local = flags.local,
        .recursive = flags.recursive,
    };
}

pub fn isShallowClone(options: CloneOptions) bool {
    return options.depth > 0;
}

pub fn isMirrorClone(options: CloneOptions) bool {
    return options.mirror;
}

test "CloneOptions default values" {
    const options = CloneOptions{};
    try std.testing.expect(options.bare == false);
    try std.testing.expect(options.depth == 0);
    try std.testing.expect(options.single_branch == false);
    try std.testing.expect(options.mirror == false);
}

test "CloneOptions bare clone" {
    var options = CloneOptions{};
    options.bare = true;
    try std.testing.expect(options.bare == true);
}

test "CloneOptions mirror clone" {
    var options = CloneOptions{};
    options.mirror = true;
    try std.testing.expect(options.mirror == true);
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

test "isShallowClone" {
    try std.testing.expect(!isShallowClone(.{ .depth = 0 }));
    try std.testing.expect(isShallowClone(.{ .depth = 1 }));
    try std.testing.expect(isShallowClone(.{ .depth = 100 }));
}

test "isMirrorClone" {
    try std.testing.expect(!isMirrorClone(.{ .mirror = false }));
    try std.testing.expect(isMirrorClone(.{ .mirror = true }));
}
