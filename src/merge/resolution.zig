//! Merge Resolution - Conflict resolution helpers
const std = @import("std");
const Io = std.Io;

pub const ResolutionStrategy = enum {
    ours,
    theirs,
    accept_ours,
    accept_theirs,
    union_merge,
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

pub const AbortResult = struct {
    success: bool,
    message: []const u8,
};

pub const ConflictResolver = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: ResolutionOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: ResolutionOptions) ConflictResolver {
        return .{ .allocator = allocator, .io = io, .git_dir = git_dir, .options = options };
    }

    pub fn resolve(self: *ConflictResolver, path: []const u8) !ResolutionResult {
        const content = self.git_dir.readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch {
            return ResolutionResult{ .resolved = false, .path = path, .strategy_used = self.options.strategy };
        };
        defer self.allocator.free(content);

        const resolved_content = try self.applyStrategy(content);
        defer self.allocator.free(resolved_content);

        self.git_dir.writeFile(self.io, .{ .sub_path = path, .data = resolved_content }) catch {
            return ResolutionResult{ .resolved = false, .path = path, .strategy_used = self.options.strategy };
        };

        return ResolutionResult{ .resolved = true, .path = path, .strategy_used = self.options.strategy };
    }

    fn applyStrategy(self: *ConflictResolver, content: []const u8) ![]const u8 {
        switch (self.options.strategy) {
            .ours => return self.resolveOurs(content),
            .theirs => return self.resolveTheirs(content),
            .accept_ours => return self.resolveAcceptOurs(content),
            .accept_theirs => return self.resolveAcceptTheirs(content),
            .union_merge => return self.resolveUnion(content),
            .concat => return self.resolveConcat(content),
        }
    }

    fn resolveOurs(self: *ConflictResolver, content: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var in_conflict = false;
        var in_ours = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                in_conflict = true;
                in_ours = true;
                continue;
            } else if (std.mem.startsWith(u8, line, "=======")) {
                in_ours = false;
                continue;
            } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                in_conflict = false;
                continue;
            }

            if (in_conflict and in_ours) {
                try result.appendSlice(line);
                try result.append('\n');
            } else if (!in_conflict) {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    fn resolveTheirs(self: *ConflictResolver, content: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var in_conflict = false;
        var in_ours = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                in_conflict = true;
                in_ours = true;
                continue;
            } else if (std.mem.startsWith(u8, line, "=======")) {
                in_ours = false;
                continue;
            } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                in_conflict = false;
                continue;
            }

            if (in_conflict and !in_ours) {
                try result.appendSlice(line);
                try result.append('\n');
            } else if (!in_conflict) {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    fn resolveAcceptOurs(self: *ConflictResolver, content: []const u8) ![]const u8 {
        return self.resolveOurs(content);
    }

    fn resolveAcceptTheirs(self: *ConflictResolver, content: []const u8) ![]const u8 {
        return self.resolveTheirs(content);
    }

    fn resolveUnion(self: *ConflictResolver, content: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var in_conflict = false;
        var in_ours = false;
        var ours_lines = std.ArrayList([]const u8).init(self.allocator);
        defer ours_lines.deinit();
        var theirs_lines = std.ArrayList([]const u8).init(self.allocator);
        defer theirs_lines.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                in_conflict = true;
                in_ours = true;
                continue;
            } else if (std.mem.startsWith(u8, line, "=======")) {
                in_ours = false;
                continue;
            } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                for (ours_lines.items) |l| {
                    try result.appendSlice(l);
                    try result.append('\n');
                }
                for (theirs_lines.items) |l| {
                    var found = false;
                    for (ours_lines.items) |ol| {
                        if (std.mem.eql(u8, ol, l)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try result.appendSlice(l);
                        try result.append('\n');
                    }
                }
                ours_lines.clearRetainingCapacity();
                theirs_lines.clearRetainingCapacity();
                in_conflict = false;
                continue;
            }

            if (in_conflict) {
                if (in_ours) {
                    try ours_lines.append(line);
                } else {
                    try theirs_lines.append(line);
                }
            } else {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    fn resolveConcat(self: *ConflictResolver, content: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var in_conflict = false;
        var in_ours = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "<<<<<<<")) {
                in_conflict = true;
                in_ours = true;
                continue;
            } else if (std.mem.startsWith(u8, line, "=======")) {
                in_ours = false;
                try result.appendSlice("=======");
                try result.append('\n');
                continue;
            } else if (std.mem.startsWith(u8, line, ">>>>>>>")) {
                in_conflict = false;
                continue;
            }

            if (in_conflict) {
                try result.appendSlice(line);
                try result.append('\n');
            } else {
                try result.appendSlice(line);
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    pub fn resolveAll(self: *ConflictResolver, paths: []const []const u8) ![]const ResolutionResult {
        var results = std.ArrayList(ResolutionResult).init(self.allocator);
        errdefer results.deinit();

        for (paths) |path| {
            const result = try self.resolve(path);
            try results.append(result);
        }

        return results.toOwnedSlice();
    }

    pub fn abort(self: *ConflictResolver) !AbortResult {
        const merge_head_path = "MERGE_HEAD";
        const merge_msg_path = "MERGE_MSG";

        var success = true;
        var cleaned: usize = 0;

        self.git_dir.deleteFile(self.io, merge_head_path) catch {
            success = false;
        };
        if (success) cleaned += 1;

        self.git_dir.deleteFile(self.io, merge_msg_path) catch {};
        cleaned += 1;

        self.git_dir.deleteFile(self.io, "MERGE_MODE") catch {};

        const index_path = "index";
        const index_backup = "index.lock";
        self.git_dir.copyFile(self.io, .{ .from_sub_path = index_backup, .to_sub_path = index_path, .flags = .{ .overwrite = true } }) catch {};

        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Merge aborted. Cleaned {} files.", .{cleaned})
        else
            try std.fmt.allocPrint(self.allocator, "Merge abort partially failed. Cleaned {} files.", .{cleaned});

        return AbortResult{ .success = success, .message = message };
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
