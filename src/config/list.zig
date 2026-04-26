//! Config List - List all config entries
const std = @import("std");
const Io = std.Io;

pub const ConfigLister = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) ConfigLister {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn listAll(self: *ConfigLister) ![]const []const u8 {
        var all = std.ArrayList([]const u8).empty;
        defer {
            for (all.items) |e| self.allocator.free(e);
            all.deinit(self.allocator);
        }

        const scopes = &[_][]const u8{ ".git/config", "home:.gitconfig", "/etc/gitconfig" };
        for (scopes) |scope_path| {
            const entries = try self.readConfigFile(scope_path);
            defer {
                for (entries) |e| self.allocator.free(e);
                self.allocator.free(entries);
            }
            for (entries) |entry| {
                const owned = try self.allocator.dupe(u8, entry);
                try all.append(self.allocator, owned);
            }
        }

        return all.toOwnedSlice(self.allocator);
    }

    pub fn listLocal(self: *ConfigLister) ![]const []const u8 {
        return self.readConfigFile(".git/config");
    }

    pub fn listGlobal(self: *ConfigLister) ![]const []const u8 {
        const home = self.getHomeDir() orelse return &.{};
        const path = try std.fmt.allocPrint(self.allocator, "{s}/.gitconfig", .{home});
        defer self.allocator.free(path);
        return self.readConfigFilePath(path);
    }

    pub fn listSystem(self: *ConfigLister) ![]const []const u8 {
        return self.readConfigFilePath("/etc/gitconfig");
    }

    fn readConfigFile(self: *ConfigLister, path: []const u8) ![]const []const u8 {
        if (std.mem.startsWith(u8, path, "home:")) {
            const home = self.getHomeDir() orelse return &.{};
            const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home, path[5..] });
            defer self.allocator.free(full);
            return self.readConfigFilePath(full);
        }
        return self.readConfigFilePath(path);
    }

    fn readConfigFilePath(self: *ConfigLister, abs_path: []const u8) ![]const []const u8 {
        const cwd = Io.Dir.cwd();
        const data = cwd.readFileAlloc(self.io, abs_path, self.allocator, .limited(1024 * 1024)) catch return &.{};
        defer self.allocator.free(data);

        if (data.len == 0) return &.{};

        var lines = std.ArrayList([]const u8).empty;
        errdefer {
            for (lines.items) |l| self.allocator.free(l);
            lines.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, data, "\n");
        while (iter.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
            const line = try self.allocator.dupe(u8, trimmed);
            try lines.append(self.allocator, line);
        }

        return lines.toOwnedSlice(self.allocator);
    }

    fn getHomeDir(self: *ConfigLister) ?[]const u8 {
        const cwd = Io.Dir.cwd();
        const home = std.os.getenv("HOME") orelse return null;
        return home;
    }
};

test "ConfigLister init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    const lister = ConfigLister.init(std.testing.allocator, io);
    try std.testing.expect(lister.allocator == std.testing.allocator);
}

test "ConfigLister listLocal method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var lister = ConfigLister.init(std.testing.allocator, io);
    const entries = try lister.listLocal();
    _ = entries;
    try std.testing.expect(true);
}
