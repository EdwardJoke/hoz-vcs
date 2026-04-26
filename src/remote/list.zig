//! Remote List - List remote repositories
const std = @import("std");
const Io = std.Io;

pub const RemoteInfo = struct {
    name: []const u8,
    url: []const u8,
    push_url: []const u8,
    fetched: bool,
};

pub const RemoteLister = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) RemoteLister {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn list(self: *RemoteLister) ![]const RemoteInfo {
        const remotes = try self.parseRemotes(false);
        return self.toRemoteInfoSlice(remotes);
    }

    pub fn listVerbose(self: *RemoteLister) ![]const RemoteInfo {
        const remotes = try self.parseRemotes(true);
        return self.toRemoteInfoSlice(remotes);
    }

    pub fn getRemoteNames(self: *RemoteLister) ![]const []const u8 {
        const remotes = try self.parseRemotes(false);
        defer {
            for (remotes.items) |r| {
                self.allocator.free(r.name);
                self.allocator.free(r.url);
                self.allocator.free(r.push_url);
            }
            remotes.deinit(self.allocator);
        }

        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }

        for (remotes.items) |r| {
            try names.append(self.allocator, try self.allocator.dupe(u8, r.name));
        }

        return names.toOwnedSlice(self.allocator);
    }

    const ParsedRemote = struct {
        name: []const u8,
        url: []const u8,
        push_url: []const u8,
    };

    fn parseRemotes(self: *RemoteLister, verbose: bool) !std.ArrayList(ParsedRemote) {
        const cwd = Io.Dir.cwd();
        const config_data = cwd.readFileAlloc(self.io, ".git/config", self.allocator, .limited(1024 * 1024)) catch return std.ArrayList(ParsedRemote).empty;

        var remotes = std.ArrayList(ParsedRemote).init(self.allocator);
        errdefer {
            for (remotes.items) |r| {
                self.allocator.free(r.name);
                self.allocator.free(r.url);
                self.allocator.free(r.push_url);
            }
            remotes.deinit(self.allocator);
        }
        defer self.allocator.free(config_data);

        var current_remote: ?struct { name: []const u8, url: []const u8, push_url: []const u8 } = null;

        var line_iter = std.mem.splitScalar(u8, config_data, "\n");
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                if (current_remote) |cr| {
                    if (cr.url.len > 0) {
                        try remotes.append(self.allocator, .{
                            .name = cr.name,
                            .url = cr.url,
                            .push_url = if (cr.push_url.len > 0) cr.push_url else try self.allocator.dupe(u8, ""),
                        });
                    } else {
                        self.allocator.free(cr.name);
                        self.allocator.free(cr.url);
                        self.allocator.free(cr.push_url);
                    }
                }
                const inner = trimmed[9 .. trimmed.len - 2];
                current_remote = .{
                    .name = try self.allocator.dupe(u8, inner),
                    .url = &.{},
                    .push_url = &.{},
                };
            } else if (current_remote) |*cr| {
                if (std.mem.startsWith(u8, trimmed, "url")) {
                    const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
                    const val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
                    if (val.len > 0) {
                        if (cr.url.len > 0) self.allocator.free(cr.url);
                        cr.url = try self.allocator.dupe(u8, val);
                    }
                } else if (std.mem.startsWith(u8, trimmed, "pushurl")) {
                    const eq_idx = std.mem.indexOf(u8, trimmed, "=") orelse continue;
                    const val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
                    if (val.len > 0) {
                        if (cr.push_url.len > 0) self.allocator.free(cr.push_url);
                        cr.push_url = try self.allocator.dupe(u8, val);
                    }
                }
            }
        }

        if (current_remote) |cr| {
            if (cr.url.len > 0) {
                try remotes.append(self.allocator, .{
                    .name = cr.name,
                    .url = cr.url,
                    .push_url = if (cr.push_url.len > 0) cr.push_url else try self.allocator.dupe(u8, ""),
                });
            } else {
                self.allocator.free(cr.name);
                self.allocator.free(cr.url);
                self.allocator.free(cr.push_url);
            }
        }

        _ = verbose;
        return remotes;
    }

    fn toRemoteInfoSlice(self: *RemoteLister, remotes: std.ArrayList(ParsedRemote)) ![]const RemoteInfo {
        var infos = std.ArrayList(RemoteInfo).init(self.allocator);
        errdefer infos.deinit(self.allocator);

        for (remotes.items) |r| {
            try infos.append(self.allocator, .{
                .name = r.name,
                .url = r.url,
                .push_url = r.push_url,
                .fetched = false,
            });
        }

        remotes.deinit(self.allocator);
        return infos.toOwnedSlice(self.allocator);
    }
};

test "RemoteInfo structure" {
    const info = RemoteInfo{ .name = "origin", .url = "https://github.com/user/repo.git", .push_url = "", .fetched = false };
    try std.testing.expectEqualStrings("origin", info.name);
    try std.testing.expect(info.fetched == false);
}

test "RemoteLister init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    const lister = RemoteLister.init(std.testing.allocator, io);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}
