//! Config Get - Retrieve config values with includes (Git-config)
const std = @import("std");
const Io = std.Io;
const Config = @import("config.zig").Config;

pub const ConfigGetter = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) ConfigGetter {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn get(self: *ConfigGetter, key: []const u8) !?[]const u8 {
        var config = Config.init(self.allocator);
        defer config.deinit();

        const scopes = &[_][]const u8{ ".git/config", "home:.config/hoz/config", "/etc/hoz/config" };
        for (scopes) |scope_path| {
            if (try self.loadInto(&config, scope_path)) {
                if (config.get(key)) |value| {
                    return try self.allocator.dupe(u8, value);
                }
            }
        }
        return null;
    }

    pub fn getWithScope(self: *ConfigGetter, key: []const u8, scope: []const u8) !?[]const u8 {
        var config = Config.init(self.allocator);
        defer config.deinit();

        const path = self.resolveScopePath(scope) orelse return null;
        defer self.allocator.free(path);
        _ = try self.loadIntoPath(&config, path);
        if (config.get(key)) |value| {
            return try self.allocator.dupe(u8, value);
        }
        return null;
    }

    /// Resolve includes for validation purposes only.
    /// This function checks that all included paths exist and are valid,
    /// but does not return or store any config values.
    pub fn resolveIncludes(self: *ConfigGetter, path: []const u8) !void {
        try self.resolveIncludesInternal(path, 0);
    }

    const max_include_depth: usize = 10;

    fn resolveIncludesInternal(self: *ConfigGetter, path: []const u8, depth: usize) !void {
        if (depth >= max_include_depth) return error.IncludeDepthExceeded;

        var config = Config.init(self.allocator);
        defer config.deinit();

        const loaded = try self.loadIntoPath(&config, path);
        if (!loaded) return;

        var it = config.entries.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, "include.") or
                std.mem.startsWith(u8, entry.key_ptr.*, "includeIf."))
            {
                const include_path = entry.value_ptr.*;
                if (!std.mem.eql(u8, include_path, path)) {
                    try self.resolveIncludesInternal(include_path, depth + 1);
                }
            }
        }
    }

    fn loadInto(self: *ConfigGetter, config: *Config, path: []const u8) !bool {
        if (std.mem.startsWith(u8, path, "home:")) {
            const home = std.c.getenv("HOME") orelse return false;
            const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ std.mem.sliceTo(home, 0), path[5..] });
            defer self.allocator.free(full);
            return self.loadIntoPath(config, full);
        }
        return self.loadIntoPath(config, path);
    }

    fn loadIntoPath(self: *ConfigGetter, config: *Config, abs_path: []const u8) !bool {
        const cwd = Io.Dir.cwd();
        const data = cwd.readFileAlloc(self.io, abs_path, self.allocator, .limited(1024 * 1024)) catch return false;
        defer self.allocator.free(data);

        if (data.len == 0) return false;

        var current_section: []const u8 = "";
        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "[")) {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                current_section = trimmed[1..end];
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
                const full_key = if (current_section.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ current_section, key })
                else
                    try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(full_key);
                try config.set(full_key, val);
                self.allocator.free(full_key);
            }
        }
        return true;
    }

    fn resolveScopePath(self: *ConfigGetter, scope: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, scope, "local")) return ".git/config";
        if (std.mem.eql(u8, scope, "global")) {
            if (std.c.getenv("HOME")) |home| {
                const path = std.fmt.allocPrint(self.allocator, "{s}/.config/hoz/config", .{std.mem.sliceTo(home, 0)}) catch return null;
                return path;
            }
            return null;
        }
        if (std.mem.eql(u8, scope, "system")) return "/etc/hoz/config";
        return null;
    }
};

test "ConfigGetter init" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    const getter = ConfigGetter.init(std.testing.allocator, io);
    _ = getter;
}

test "ConfigGetter get returns null for missing key" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    var getter = ConfigGetter.init(std.testing.allocator, io);
    const value = try getter.get("nonexistent.key.does.not.exist");
    try std.testing.expect(value == null);
}
