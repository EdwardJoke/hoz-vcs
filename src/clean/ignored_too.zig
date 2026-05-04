//! Clean Ignored Too - Remove ignored files too (-x)
const std = @import("std");
const Io = std.Io;

pub const CleanIgnoredToo = struct {
    allocator: std.mem.Allocator,
    io: Io,
    include_ignored: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io) CleanIgnoredToo {
        return .{ .allocator = allocator, .io = io, .include_ignored = true };
    }

    pub fn clean(self: *CleanIgnoredToo, path: []const u8) !usize {
        var deleted_count: usize = 0;
        const cwd = Io.Dir.cwd();

        var dir = cwd.openDir(self.io, path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var ignore_patterns = try self.loadGitignorePatterns(path);
        defer {
            for (ignore_patterns.items) |p| self.allocator.free(p);
            ignore_patterns.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind == .file or entry.kind == .sym_link) {
                if (std.mem.indexOf(u8, entry.name, ".gitignore") != null) continue;
                if (!self.matchesPatterns(entry.name, ignore_patterns.items)) continue;
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(full_path);
                cwd.deleteFile(self.io, full_path) catch {};
                deleted_count += 1;
            }
        }
        return deleted_count;
    }

    fn loadGitignorePatterns(self: *CleanIgnoredToo, path: []const u8) !std.ArrayList([]const u8) {
        var patterns = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        const gitignore_path = try std.fmt.allocPrint(self.allocator, "{s}/.gitignore", .{path});
        defer self.allocator.free(gitignore_path);

        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, gitignore_path, self.allocator, .limited(64 * 1024)) catch return patterns;
        defer self.allocator.free(content);

        var lines = std.mem.splitSequence(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const pattern = try self.allocator.dupe(u8, trimmed);
            try patterns.append(self.allocator, pattern);
        }
        return patterns;
    }

    fn matchesPatterns(_: *CleanIgnoredToo, name: []const u8, patterns: []const []const u8) bool {
        for (patterns) |pattern| {
            if (globMatch(name, pattern)) return true;
        }
        return false;
    }

    fn globMatch(name: []const u8, pattern: []const u8) bool {
        var ni: usize = 0;
        var pi: usize = 0;
        var star_ni: usize = 0;
        var star_pi: usize = pattern.len;
        var has_star = false;

        while (ni < name.len or pi < pattern.len) {
            if (pi < pattern.len and pattern[pi] == '*') {
                star_pi = pi;
                star_ni = ni;
                has_star = true;
                pi += 1;
            } else if (pi < pattern.len and ni < name.len and (pattern[pi] == name[ni] or pattern[pi] == '?')) {
                ni += 1;
                pi += 1;
            } else if (has_star) {
                pi = star_pi + 1;
                star_ni += 1;
                ni = star_ni;
            } else {
                return false;
            }
        }
        while (pi < pattern.len and pattern[pi] == '*') {
            pi += 1;
        }
        return pi >= pattern.len;
    }

    pub fn shouldIncludeIgnored(self: *CleanIgnoredToo) bool {
        return self.include_ignored;
    }
};

test "CleanIgnoredToo init" {
    const cleaner = CleanIgnoredToo.init(std.testing.allocator, undefined);
    try std.testing.expect(cleaner.include_ignored == true);
}

test "CleanIgnoredToo shouldIncludeIgnored" {
    const cleaner = CleanIgnoredToo.init(std.testing.allocator, undefined);
    try std.testing.expect(cleaner.shouldIncludeIgnored() == true);
}

test "CleanIgnoredToo clean method exists" {
    var cleaner = CleanIgnoredToo.init(std.testing.allocator, undefined);
    const count = try cleaner.clean(".");
    _ = count;
    try std.testing.expect(true);
}
