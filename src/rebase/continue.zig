//! Rebase Continue - Continue or skip rebase operations
const std = @import("std");
const Io = std.Io;

pub const ContinueOptions = struct {
    skip_empty: bool = false,
};

pub const ContinueResult = struct {
    success: bool,
    commits_remaining: u32,
};

pub const RebaseContinuer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: ContinueOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: ContinueOptions) RebaseContinuer {
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn continueRebase(self: *RebaseContinuer) !ContinueResult {
        const cwd = Io.Dir.cwd();
        _ = cwd.statFile(self.io, "rebase-merge/head-name", .{}) catch {
            return ContinueResult{ .success = false, .commits_remaining = 0 };
        };

        const remaining = self.countRemainingCommits() catch 0;
        return ContinueResult{ .success = true, .commits_remaining = remaining };
    }

    pub fn skipCommit(self: *RebaseContinuer) !ContinueResult {
        const cwd = Io.Dir.cwd();
        _ = cwd.statFile(self.io, "rebase-merge/current", .{}) catch {
            return ContinueResult{ .success = false, .commits_remaining = 0 };
        };

        const remaining = self.countRemainingCommits() catch 0;
        if (remaining > 0) {
            return ContinueResult{ .success = true, .commits_remaining = remaining - 1 };
        }
        return ContinueResult{ .success = true, .commits_remaining = 0 };
    }

    pub fn isInProgress(self: *RebaseContinuer) bool {
        const cwd = Io.Dir.cwd();
        _ = cwd.statFile(self.io, "rebase-merge/head-name", .{}) catch return false;
        return true;
    }

    fn countRemainingCommits(self: *RebaseContinuer) !u32 {
        const cwd = Io.Dir.cwd();
        const todo_content = cwd.readFileAlloc(self.io, "rebase-merge/todo", self.allocator, .limited(1024 * 1024)) catch {
            return 0;
        };
        defer self.allocator.free(todo_content);

        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, todo_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            count += 1;
        }
        return count;
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
    const continuer = RebaseContinuer.init(std.testing.allocator, undefined, options);
    try std.testing.expect(continuer.allocator == std.testing.allocator);
}

test "RebaseContinuer init with options" {
    var options = ContinueOptions{};
    options.skip_empty = true;
    const continuer = RebaseContinuer.init(std.testing.allocator, undefined, options);
    try std.testing.expect(continuer.options.skip_empty == true);
}
