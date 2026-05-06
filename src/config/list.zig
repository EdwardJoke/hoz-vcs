//! Config List - List all config entries (Git-config)
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
        errdefer {
            for (all.items) |e| self.allocator.free(e);
            all.deinit(self.allocator);
        }

        const scopes = &[_][]const u8{ ".git/config", "home:.config/hoz/config", "/etc/hoz/config" };
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
        const path = try std.fmt.allocPrint(self.allocator, "{s}/.config/hoz/config", .{home});
        defer self.allocator.free(path);
        return self.readConfigFilePath(path);
    }

    pub fn listSystem(self: *ConfigLister) ![]const []const u8 {
        return self.readConfigFilePath("/etc/hoz/config");
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

        var current_section: []const u8 = "";
        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "[")) {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                current_section = trimmed[1..end];
                const line = try self.allocator.dupe(u8, trimmed);
                try lines.append(self.allocator, line);
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |_| {
                const line = if (current_section.len > 0)
                    try std.fmt.allocPrint(self.allocator, "[{s}] {s}", .{ current_section, trimmed })
                else
                    try self.allocator.dupe(u8, trimmed);
                try lines.append(self.allocator, line);
            }
        }

        return lines.toOwnedSlice(self.allocator);
    }

    fn getHomeDir(self: *ConfigLister) ?[]const u8 {
        _ = self;
        const home = std.c.getenv("HOME") orelse return null;
        return std.mem.sliceTo(home, 0);
    }
};

test "ConfigLister init" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    const lister = ConfigLister.init(std.testing.allocator, io);
    _ = lister;
}

test "ConfigLister listLocal method exists" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    var lister = ConfigLister.init(std.testing.allocator, io);
    const entries = try lister.listLocal();
    defer {
        for (entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(entries);
    }
    try std.testing.expect(true);
}
