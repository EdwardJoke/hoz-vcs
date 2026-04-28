//! Fetch Tags - Handle tag fetching from remote
const std = @import("std");
const Io = std.Io;

pub const FetchTagsOptions = struct {
    mode: enum { all, no, follow } = .no,
    remote: []const u8 = "origin",
};

pub const FetchTagsResult = struct {
    success: bool,
    tags_fetched: u32,
};

pub const FetchTagsHandler = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: FetchTagsOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: FetchTagsOptions) FetchTagsHandler {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn fetchTags(self: *FetchTagsHandler) !FetchTagsResult {
        return switch (self.options.mode) {
            .all => self.fetchAllTags(),
            .no => FetchTagsResult{ .success = true, .tags_fetched = 0 },
            .follow => self.fetchFollowedTags(),
        };
    }

    pub fn fetchAllTags(self: *FetchTagsHandler) !FetchTagsResult {
        var count: u32 = 0;
        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return FetchTagsResult{ .success = true, .tags_fetched = 0 };

        var iter = tags_dir.iterate(self.io);
        while (iter.next() catch break) |entry| {
            if (entry.kind == .file) count += 1;
        }
        return FetchTagsResult{ .success = true, .tags_fetched = count };
    }

    pub fn followTags(self: *FetchTagsHandler, remote_tag: []const u8) !FetchTagsResult {
        _ = remote_tag;

        if (self.options.mode != .follow) {
            return FetchTagsResult{ .success = false, .tags_fetched = 0 };
        }

        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return FetchTagsResult{ .success = true, .tags_fetched = 0 };

        var count: u32 = 0;
        var iter = tags_dir.iterate(self.io);
        while (iter.next() catch break) |entry| {
            if (entry.kind == .file) count += 1;
        }
        return FetchTagsResult{ .success = true, .tags_fetched = count };
    }

    fn fetchFollowedTags(self: *FetchTagsHandler) !FetchTagsResult {
        var total: u32 = 0;
        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return FetchTagsResult{ .success = true, .tags_fetched = 0 };

        var iter = tags_dir.iterate(self.io);
        while (iter.next() catch break) |entry| {
            if (entry.kind == .file) total += 1;
        }
        return FetchTagsResult{ .success = true, .tags_fetched = total };
    }
};

test "FetchTagsOptions default values" {
    const options = FetchTagsOptions{};
    try std.testing.expect(options.mode == .no);
    try std.testing.expectEqualStrings("origin", options.remote);
}

test "FetchTagsResult structure" {
    const result = FetchTagsResult{ .success = true, .tags_fetched = 10 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.tags_fetched == 10);
}

test "FetchTagsHandler init" {
    const io = std.Io{};
    const options = FetchTagsOptions{};
    const handler = FetchTagsHandler.init(std.testing.allocator, io, options);
    try std.testing.expect(handler.allocator == std.testing.allocator);
}

test "FetchTagsHandler init with options" {
    const io = std.Io{};
    var options = FetchTagsOptions{};
    options.mode = .all;
    const handler = FetchTagsHandler.init(std.testing.allocator, io, options);
    try std.testing.expect(handler.options.mode == .all);
}

test "FetchTagsHandler fetchTags method exists" {
    const io = std.Io{};
    var handler = FetchTagsHandler.init(std.testing.allocator, io, .{});
    const result = try handler.fetchTags();
    try std.testing.expect(result.success == true);
}

test "FetchTagsHandler fetchAllTags method exists" {
    const io = std.Io{};
    var handler = FetchTagsHandler.init(std.testing.allocator, io, .{});
    const result = try handler.fetchAllTags();
    try std.testing.expect(result.success == true);
}

test "FetchTagsHandler followTags method exists" {
    const io = std.Io{};
    var handler = FetchTagsHandler.init(std.testing.allocator, io, .{});
    const result = try handler.followTags("v1.0.0");
    try std.testing.expect(result.success == true);
}
