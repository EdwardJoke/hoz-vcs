//! Remote Manager - Manage remote repositories
const std = @import("std");
const Io = std.Io;

pub const Remote = struct {
    name: []const u8,
    url: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
};

pub const RemoteManager = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir_path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io) RemoteManager {
        return .{ .allocator = allocator, .io = io, .git_dir_path = null };
    }

    pub fn initWithGitDir(allocator: std.mem.Allocator, io: Io, git_dir: []const u8) RemoteManager {
        return .{ .allocator = allocator, .io = io, .git_dir_path = git_dir };
    }

    pub fn addRemote(self: *RemoteManager, name: []const u8, url: []const u8) !Remote {
        if (self.git_dir_path) |git_dir| {
            const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
            defer self.allocator.free(config_path);

            const content = self.readConfig(config_path) catch "";
            var buf = std.ArrayListUnmanaged(u8).empty;
            errdefer buf.deinit(self.allocator);

            if (content.len > 0) {
                try buf.appendSlice(self.allocator, content);
                if (!std.mem.endsWith(u8, content, "\n")) {
                    try buf.append(self.allocator, '\n');
                }
            }

            try buf.writer().print(
                \\[remote "{s}"]
                \\    url = {s}
                \\    fetch = +refs/heads/*:refs/remotes/{s}/*
                \\
            , .{ name, url, name });

            const cwd = Io.Dir.cwd();
            try cwd.writeFile(self.allocator, config_path, buf.items, .{});
        }

        return Remote{
            .name = name,
            .url = url,
            .fetch_url = url,
            .push_url = url,
        };
    }

    pub fn removeRemote(self: *RemoteManager, name: []const u8) !void {
        if (self.git_dir_path == null) return;
        const git_dir = self.git_dir_path.?;
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
        defer self.allocator.free(config_path);

        const content = self.readConfig(config_path) catch return;
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const section_header = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
        defer self.allocator.free(section_header);

        var in_target_section = false;
        var lines = std.mem.tokenizeAny(u8, content, "\n");

        while (lines.next()) |line| {
            const trim_line = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trim_line, "[")) {
                in_target_section = std.mem.eql(u8, trim_line, section_header);
            }
            if (!in_target_section) {
                if (buf.items.len > 0) try buf.append('\n');
                try buf.appendSlice(line);
            } else {
                in_target_section = true;
            }
        }

        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.allocator, config_path, buf.items, .{});
    }

    pub fn getRemote(self: *RemoteManager, name: []const u8) !?Remote {
        if (self.git_dir_path == null) return null;
        const git_dir = self.git_dir_path.?;
        const config_path = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
        defer self.allocator.free(config_path);

        const content = self.readConfig(config_path) catch return null;
        const section_header = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
        defer self.allocator.free(section_header);

        var in_target_section = false;
        var found_remote: ?Remote = null;

        var lines = std.mem.tokenizeAny(u8, content, "\n");
        while (lines.next()) |line| {
            const trim_line = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trim_line, "[")) {
                if (in_target_section and found_remote == null) break;
                in_target_section = std.mem.eql(u8, trim_line, section_header);
                continue;
            }

            if (in_target_section) {
                if (std.mem.indexOf(u8, trim_line, "=")) |eq_idx| {
                    const key = std.mem.trim(u8, trim_line[0..eq_idx], " \t");
                    const val = std.mem.trim(u8, trim_line[eq_idx + 1 ..], " \t");

                    if (std.mem.eql(u8, key, "url")) {
                        const url_copy = try self.allocator.dupe(u8, val);
                        found_remote = .{
                            .name = name,
                            .url = url_copy,
                            .fetch_url = url_copy,
                            .push_url = url_copy,
                        };
                    }
                }
            }
        }

        return found_remote;
    }

    pub fn renameRemote(self: *RemoteManager, old_name: []const u8, new_name: []const u8) !Remote {
        _ = new_name;
        return (try self.getRemote(old_name)) orelse Remote{
            .name = old_name,
            .url = "",
            .fetch_url = "",
            .push_url = "",
        };
    }

    pub fn setUrl(self: *RemoteManager, name: []const u8, url: []const u8) !Remote {
        _ = url;
        return (try self.getRemote(name)) orelse Remote{
            .name = name,
            .url = "",
            .fetch_url = "",
            .push_url = "",
        };
    }

    pub fn showRemote(self: *RemoteManager, name: []const u8) !RemoteShowInfo {
        const remote = (try self.getRemote(name)) orelse return RemoteShowInfo{
            .name = name,
            .fetch_url = "",
            .push_url = "",
            .branches = &.{},
            .tags = &.{},
        };

        return RemoteShowInfo{
            .name = remote.name,
            .fetch_url = remote.fetch_url,
            .push_url = remote.push_url,
            .branches = &.{},
            .tags = &.{},
        };
    }

    fn readConfig(self: *RemoteManager, path: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();
        return cwd.readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024));
    }
};

pub const RemoteShowInfo = struct {
    name: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
    branches: []const []const u8,
    tags: []const []const u8,
};

pub const PruneOptions = struct {
    dry_run: bool = false,
};

pub const PruneResult = struct {
    pruned_refs: []const []const u8,
    dry_run: bool,
};

pub fn pruneRemote(self: *RemoteManager, name: []const u8, options: PruneOptions) !PruneResult {
    _ = self;
    _ = name;
    _ = options;
    return PruneResult{
        .pruned_refs = &.{},
        .dry_run = options.dry_run,
    };
}

test "Remote structure" {
    const remote = Remote{ .name = "origin", .url = "https://github.com/user/repo.git", .fetch_url = "", .push_url = "" };
    try std.testing.expectEqualStrings("origin", remote.name);
}

test "RemoteManager init" {
    const io = std.Io.Threaded.new(.{});
    const manager = RemoteManager.init(std.testing.allocator, io.?);
    try std.testing.expect(manager.allocator == std.testing.allocator);
}

test "RemoteManager addRemote method exists" {
    const io = std.Io.Threaded.new(.{});
    var manager = RemoteManager.init(std.testing.allocator, io.?);
    const remote = try manager.addRemote("origin", "https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("origin", remote.name);
}

test "RemoteManager removeRemote method exists" {
    const io = std.Io.Threaded.new(.{});
    var manager = RemoteManager.init(std.testing.allocator, io.?);
    try manager.removeRemote("origin");
    try std.testing.expect(true);
}

test "RemoteManager getRemote method exists" {
    const io = std.Io.Threaded.new(.{});
    var manager = RemoteManager.init(std.testing.allocator, io.?);
    const remote = try manager.getRemote("origin");
    try std.testing.expect(remote == null);
}

test "RemoteManager renameRemote method exists" {
    const io = std.Io.Threaded.new(.{});
    var manager = RemoteManager.init(std.testing.allocator, io.?);
    const remote = try manager.renameRemote("origin", "new-origin");
    try std.testing.expectEqualStrings("new-origin", remote.name);
}
