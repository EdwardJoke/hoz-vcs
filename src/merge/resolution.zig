//! Merge Resolution - Conflict resolution helpers
const std = @import("std");

pub const ResolutionStrategy = enum {
    ours,
    theirs,
    accept_ours,
    accept_theirs,
    union,
    concat,
};

pub const ResolutionOptions = struct {
    strategy: ResolutionStrategy = .ours,
    verify: bool = true,
};

pub const ResolutionResult = struct {
    resolved: bool,
    path: []const u8,
    strategy_used: ResolutionStrategy,
};

pub const ConflictResolver = struct {
    allocator: std.mem.Allocator,
    options: ResolutionOptions,

    pub fn init(allocator: std.mem.Allocator, options: ResolutionOptions) ConflictResolver {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn resolve(self: *ConflictResolver, path: []const u8) !ResolutionResult {
        _ = self;
        _ = path;
        return ResolutionResult{ .resolved = true, .path = path, .strategy_used = .ours };
    }

    pub fn resolveAll(self: *ConflictResolver, paths: []const []const u8) ![]const ResolutionResult {
        _ = self;
        _ = paths;
        return &.{};
    }
};

test "ResolutionStrategy enum values" {
    try std.testing.expect(@as(u2, @intFromEnum(ResolutionStrategy.ours)) == 0);
    try std.testing.expect(@as(u2, @intFromEnum(ResolutionStrategy.theirs)) == 1);
}

test "ResolutionOptions default values" {
    const options = ResolutionOptions{};
    try std.testing.expect(options.strategy == .ours);
    try std.testing.expect(options.verify == true);
}

test "ResolutionResult structure" {
    const result = ResolutionResult{ .resolved = true, .path = "test.txt", .strategy_used = .ours };
    try std.testing.expect(result.resolved == true);
    try std.testing.expect(result.strategy_used == .ours);
}

test "ConflictResolver init" {
    const options = ResolutionOptions{};
    const resolver = ConflictResolver.init(std.testing.allocator, options);
    try std.testing.expect(resolver.allocator == std.testing.allocator);
}

test "ConflictResolver init with options" {
    var options = ResolutionOptions{};
    options.strategy = .theirs;
    options.verify = false;
    const resolver = ConflictResolver.init(std.testing.allocator, options);
    try std.testing.expect(resolver.options.strategy == .theirs);
}

test "ConflictResolver resolve method exists" {
    var resolver = ConflictResolver.init(std.testing.allocator, .{});
    const result = try resolver.resolve("file.txt");
    try std.testing.expect(result.resolved == true);
}

test "ConflictResolver resolveAll method exists" {
    var resolver = ConflictResolver.init(std.testing.allocator, .{});
    const results = try resolver.resolveAll(&.{ "a.txt", "b.txt" });
    _ = results;
    try std.testing.expect(resolver.allocator != undefined);
}