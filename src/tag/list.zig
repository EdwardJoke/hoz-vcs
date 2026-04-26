//! Tag List - List tags with pattern filtering
const std = @import("std");
const Io = std.Io;

pub const TagLister = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagLister {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn listAll(self: *TagLister) ![]const []const u8 {
        const cwd = Io.Dir.cwd();
        const tags_dir = cwd.openDir(self.io, ".git/refs/tags", .{}) catch return &.{};
        defer tags_dir.close(self.io);

        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }

        var walker = tags_dir.walk(self.allocator) catch return &.{};
        defer walker.deinit();

        while (true) {
            const entry = walker.next(self.io) catch break;
            const e = entry orelse break;
            if (e.kind != .file) continue;
            const name = try self.allocator.dupe(u8, e.basename);
            try names.append(self.allocator, name);
        }

        return names.toOwnedSlice(self.allocator);
    }

    pub fn listMatching(self: *TagLister, pattern: []const u8) ![]const []const u8 {
        const all = try self.listAll();
        defer {
            for (all) |t| self.allocator.free(t);
            self.allocator.free(all);
        }

        if (std.mem.eql(u8, pattern, "*")) return all;

        var matched = std.ArrayList([]const u8).empty;
        errdefer {
            for (matched.items) |m| self.allocator.free(m);
            matched.deinit(self.allocator);
        }

        for (all) |tag| {
            if (self.globMatch(tag, pattern)) {
                try matched.append(self.allocator, try self.allocator.dupe(u8, tag));
            }
        }

        return matched.toOwnedSlice(self.allocator);
    }

    pub fn listWithDetails(self: *TagLister) ![]const []const u8 {
        const tags = try self.listAll();
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            for (tags) |t| self.allocator.free(t);
            self.allocator.free(tags);
            return &.{};
        };
        defer git_dir.close(self.io);

        var details = std.ArrayList([]const u8).empty;
        errdefer {
            for (details.items) |d| self.allocator.free(d);
            details.deinit(self.allocator);
        }
        defer {
            for (tags) |t| self.allocator.free(t);
            self.allocator.free(tags);
        }

        for (tags) |tag| {
            const ref_path = try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag});
            defer self.allocator.free(ref_path);

            const oid_hex = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(64)) catch |err| {
                if (err == error.FileNotFound) continue;
                const detail = try std.fmt.allocPrint(self.allocator, "{s} (error)", .{tag});
                try details.append(self.allocator, detail);
                continue;
            };
            defer self.allocator.free(oid_hex);

            const trimmed = std.mem.trim(u8, oid_hex, " \t\r\n");
            const detail = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ tag, trimmed });
            try details.append(self.allocator, detail);
        }

        return details.toOwnedSlice(self.allocator);
    }

    fn globMatch(self: *TagLister, text: []const u8, pattern: []const u8) bool {
        _ = self;
        if (pattern.len == 0) return text.len == 0;
        if (std.mem.endsWith(u8, pattern, "*")) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, text, prefix);
        }
        if (std.mem.startsWith(u8, pattern, "*")) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, text, suffix);
        }
        return std.mem.eql(u8, text, pattern);
    }
};

test "TagLister init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const lister = TagLister.init(std.testing.allocator, io);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}

test "TagLister globMatch basic patterns" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var lister = TagLister.init(std.testing.allocator, io);

    try std.testing.expect(lister.globMatch("v1.0", "v*") == true);
    try std.testing.expect(lister.globMatch("v2.0", "v1.*") == false);
    try std.testing.expect(lister.globMatch("v1.0", "*") == true);
    try std.testing.expect(lister.globMatch("release-v1", "*-v1") == true);
    try std.testing.expect(lister.globMatch("v1.0", "v1.0") == true);
}
