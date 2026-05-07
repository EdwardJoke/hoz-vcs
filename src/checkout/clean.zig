//! Clean - Remove untracked files from working directory
const std = @import("std");
const Io = std.Io;
const ignore_mod = @import("../workdir/ignore.zig");

pub const CleanOptions = struct {
    force: bool = false,
    directories: bool = true,
    ignored: bool = false,
    dry_run: bool = false,
    quiet: bool = false,
    paths: ?[]const []const u8 = null,
};

pub const CleanResult = struct {
    files_removed: u32,
    dirs_removed: u32,
    bytes_freed: u64,
};

pub const Cleaner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: CleanOptions,
    ignore_patterns: []const ignore_mod.Pattern,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: CleanOptions) Cleaner {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .ignore_patterns = &.{},
        };
    }

    pub fn setIgnorePatterns(self: *Cleaner, patterns: []const ignore_mod.Pattern) void {
        self.ignore_patterns = patterns;
    }

    pub fn clean(self: *Cleaner, paths: []const []const u8) !CleanResult {
        var result = CleanResult{ .files_removed = 0, .dirs_removed = 0, .bytes_freed = 0 };
        const cwd = Io.Dir.cwd();

        for (paths) |path| {
            var dir = cwd.openDir(self.io, path, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);

            var iter = dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (entry.kind == .file or entry.kind == .sym_link) {
                    if (self.shouldRemove(entry.name)) {
                        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                        defer self.allocator.free(full_path);

                        const stat = cwd.statFile(self.io, full_path) catch continue;
                        result.bytes_freed += @as(u64, @intCast(stat.size));

                        if (!self.options.dry_run) {
                            cwd.deleteFile(self.io, full_path) catch {};
                        }
                        result.files_removed += 1;
                    }
                } else if (entry.kind == .directory and self.options.directories) {
                    if (self.shouldRemove(entry.name)) {
                        const dir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                        defer self.allocator.free(dir_path);
                        if (!self.options.dry_run) {
                            self.removeDirTree(cwd, dir_path) catch {};
                        }
                        result.dirs_removed += 1;
                    }
                }
            }
        }

        return result;
    }

    fn removeDirTree(self: *Cleaner, cwd: Io.Dir, dir_path: []const u8) !void {
        var dirs = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
        defer {
            while (dirs.popOrNull()) |p| self.allocator.free(p);
            dirs.deinit(self.allocator);
        }
        try dirs.append(self.allocator, dir_path);

        var i: usize = 0;
        while (i < dirs.items.len) : (i += 1) {
            const current = dirs.items[i];
            const sub = cwd.openDir(self.io, current, .{ .iterate = true }) catch continue;
            defer sub.close(self.io);

            var iter = sub.iterate();
            while (iter.next(self.io) catch null) |entry| {
                const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current, entry.name });
                switch (entry.kind) {
                    .directory => try dirs.append(self.allocator, full),
                    .file, .sym_link => {
                        cwd.deleteFile(self.io, full) catch {};
                        self.allocator.free(full);
                    },
                    else => self.allocator.free(full),
                }
            }
        }

        var j: usize = dirs.items.len;
        while (j > 0) {
            j -= 1;
            const p = dirs.items[j];
            cwd.deleteDir(self.io, p) catch {};
        }
    }

    pub fn cleanAll(self: *Cleaner) !CleanResult {
        const paths = self.options.paths orelse &.{"."};
        return self.clean(paths);
    }

    fn shouldRemove(self: *Cleaner, name: []const u8) bool {
        if (std.mem.eql(u8, name, ".git")) return false;
        if (std.mem.eql(u8, name, ".hoz")) return false;
        if (!self.options.ignored and std.mem.startsWith(u8, name, ".")) return false;
        if (!self.options.ignored and self.ignore_patterns.len > 0) {
            if (ignore_mod.isIgnored(self.ignore_patterns, name, false)) return false;
        }
        return true;
    }
};

test "CleanOptions default values" {
    const options = CleanOptions{};
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.directories == true);
    try std.testing.expect(options.ignored == false);
    try std.testing.expect(options.dry_run == false);
}

test "CleanResult structure" {
    const result = CleanResult{
        .files_removed = 5,
        .dirs_removed = 2,
        .bytes_freed = 1024,
    };

    try std.testing.expectEqual(@as(u32, 5), result.files_removed);
    try std.testing.expectEqual(@as(u32, 2), result.dirs_removed);
    try std.testing.expectEqual(@as(u64, 1024), result.bytes_freed);
}

test "Cleaner init" {
    const options = CleanOptions{};
    const cleaner = Cleaner.init(std.testing.allocator, undefined, options);

    try std.testing.expect(cleaner.allocator == std.testing.allocator);
}

test "Cleaner init with options" {
    var options = CleanOptions{};
    options.force = true;
    options.dry_run = true;
    const cleaner = Cleaner.init(std.testing.allocator, undefined, options);

    try std.testing.expect(cleaner.options.force == true);
    try std.testing.expect(cleaner.options.dry_run == true);
}

test "Cleaner clean method exists" {
    var options = CleanOptions{};
    options.dry_run = true;
    const cleaner = Cleaner.init(std.testing.allocator, undefined, options);

    const result = try cleaner.clean(&.{ "." });
    try std.testing.expectEqual(@as(u32, 0), result.files_removed);
}

test "Cleaner cleanAll method exists" {
    var options = CleanOptions{};
    options.dry_run = true;
    const cleaner = Cleaner.init(std.testing.allocator, undefined, options);

    const result = try cleaner.cleanAll();
    try std.testing.expectEqual(@as(u32, 0), result.dirs_removed);
}

test "Cleaner options default values" {
    const options = CleanOptions{};
    const cleaner = Cleaner.init(std.testing.allocator, undefined, options);

    try std.testing.expect(cleaner.options.force == false);
    try std.testing.expect(cleaner.options.directories == true);
    try std.testing.expect(cleaner.options.ignored == false);
}

test "CleanResult files_removed field" {
    const result = CleanResult{
        .files_removed = 10,
        .dirs_removed = 3,
        .bytes_freed = 2048,
    };

    try std.testing.expectEqual(@as(u32, 10), result.files_removed);
}

test "CleanResult dirs_removed field" {
    const result = CleanResult{
        .files_removed = 10,
        .dirs_removed = 3,
        .bytes_freed = 2048,
    };

    try std.testing.expectEqual(@as(u32, 3), result.dirs_removed);
}

test "CleanResult bytes_freed field" {
    const result = CleanResult{
        .files_removed = 10,
        .dirs_removed = 3,
        .bytes_freed = 2048,
    };

    try std.testing.expectEqual(@as(u64, 2048), result.bytes_freed);
}
