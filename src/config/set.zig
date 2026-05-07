//! Config Set/Unset - Modify config values with section awareness (Git-config)
const std = @import("std");
const Io = std.Io;

pub const ConfigSetter = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) ConfigSetter {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn set(self: *ConfigSetter, key: []const u8, value: []const u8) !void {
        try self.setAtPath(".git/config", key, value);
    }

    pub fn unset(self: *ConfigSetter, key: []const u8) !void {
        try self.unsetAtPath(".git/config", key);
    }

    pub fn setGlobal(self: *ConfigSetter, key: []const u8, value: []const u8) !void {
        const home = std.c.getenv("HOME") orelse return error.HomeNotFound;
        const path = try std.fmt.allocPrint(self.allocator, "{s}/.config/hoz/config", .{std.mem.sliceTo(home, 0)});
        defer self.allocator.free(path);
        try self.setAtPath(path, key, value);
    }

    pub fn setSystem(self: *ConfigSetter, key: []const u8, value: []const u8) !void {
        try self.setAtPath("/etc/hoz/config", key, value);
    }

    fn parseKey(key: []const u8) struct { section: []const u8, subkey: []const u8 } {
        if (std.mem.indexOf(u8, key, ".")) |dot| {
            return .{ .section = key[0..dot], .subkey = key[dot + 1 ..] };
        }
        return .{ .section = "", .subkey = key };
    }

    fn setAtPath(self: *ConfigSetter, path: []const u8, key: []const u8, value: []const u8) !void {
        var lines = try self.readLines(path);
        defer self.freeLines(lines);

        const parts = parseKey(key);

        var found = false;
        var current_section: ?[]const u8 = null;
        var last_section_line: usize = 0;

        for (lines.items, 0..) |line, idx| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "[")) {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                current_section = trimmed[1..end];
                last_section_line = idx;
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const line_key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const sec = current_section orelse "";
                if (std.mem.eql(u8, sec, parts.section) and std.mem.eql(u8, line_key, parts.subkey)) {
                    self.allocator.free(lines.items[idx]);
                    lines.items[idx] = try std.fmt.allocPrint(self.allocator, "\t{s} = {s}", .{ parts.subkey, value });
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            const section_header = try std.fmt.allocPrint(self.allocator, "[{s}]", .{parts.section});
            defer self.allocator.free(section_header);

            var section_exists = false;
            current_section = null;
            for (lines.items) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed, "[")) {
                    const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                    const sec_name = trimmed[1..end];
                    if (std.mem.eql(u8, sec_name, parts.section)) {
                        section_exists = true;
                        break;
                    }
                }
            }

            if (section_exists) {
                var insert_at: usize = lines.items.len;
                current_section = null;
                for (lines.items, 0..) |line, idx| {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (std.mem.startsWith(u8, trimmed, "[")) {
                        const end = std.mem.indexOf(u8, trimmed, "]") orelse continue;
                        const sec_name = trimmed[1..end];
                        if (std.mem.eql(u8, sec_name, parts.section)) {
                            current_section = sec_name;
                        } else if (current_section != null) {
                            insert_at = idx;
                            break;
                        }
                    } else if (current_section != null and std.mem.indexOf(u8, trimmed, "=") != null) {
                        insert_at = idx + 1;
                    }
                }
                const new_line = try std.fmt.allocPrint(self.allocator, "\t{s} = {s}", .{ parts.subkey, value });
                _ = try lines.insert(self.allocator, insert_at, new_line);
            } else {
                const header = try self.allocator.dupe(u8, section_header);
                try lines.append(self.allocator, header);
                const new_line = try std.fmt.allocPrint(self.allocator, "\t{s} = {s}", .{ parts.subkey, value });
                try lines.append(self.allocator, new_line);
            }
        }

        try self.writeLines(path, lines.items);
    }

    fn unsetAtPath(self: *ConfigSetter, path: []const u8, key: []const u8) !void {
        var lines = try self.readLines(path);
        defer self.freeLines(lines);

        const parts = parseKey(key);

        var current_section: ?[]const u8 = null;
        var i: usize = 0;
        while (i < lines.items.len) {
            const line = lines.items[i];
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
                i += 1;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "[")) {
                const end = std.mem.indexOf(u8, trimmed, "]") orelse {
                    i += 1;
                    continue;
                };
                current_section = trimmed[1..end];
                i += 1;
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const line_key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const sec = current_section orelse "";
                if (std.mem.eql(u8, sec, parts.section) and std.mem.eql(u8, line_key, parts.subkey)) {
                    _ = lines.orderedRemove(i);
                    self.allocator.free(line);
                    continue;
                }
            }
            i += 1;
        }

        try self.writeLines(path, lines.items);
    }

    fn readLines(self: *ConfigSetter, path: []const u8) !std.ArrayList([]const u8) {
        var list = std.ArrayList([]const u8).initCapacity(self.allocator, 16) catch |err| return err;
        errdefer {
            for (list.items) |l| self.allocator.free(l);
            list.deinit(self.allocator);
        }

        const cwd = Io.Dir.cwd();
        const data = cwd.readFileAlloc(self.io, path, self.allocator, .limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return list;
            return err;
        };

        defer self.allocator.free(data);

        var iter = std.mem.splitScalar(u8, data, '\n');
        while (iter.next()) |raw| {
            const owned = try self.allocator.dupe(u8, raw);
            try list.append(self.allocator, owned);
        }
        return list;
    }

    fn writeLines(self: *ConfigSetter, path: []const u8, lines: []const []const u8) !void {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 256) catch |err| return err;
        defer buf.deinit(self.allocator);

        for (lines) |line| {
            const line_out = try std.fmt.allocPrint(self.allocator, "{s}\n", .{line});
            defer self.allocator.free(line_out);
            try buf.appendSlice(self.allocator, line_out);
        }

        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.io, .{ .sub_path = path, .data = buf.items });
    }

    fn freeLines(self: *ConfigSetter, lines: std.ArrayList([]const u8)) void {
        for (lines.items) |l| self.allocator.free(l);
        var m = lines;
        m.deinit(self.allocator);
    }
};

test "ConfigSetter init" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    const setter = ConfigSetter.init(std.testing.allocator, io);
    _ = setter;
}

test "ConfigSetter parseKey splits dot notation" {
    const parts = ConfigSetter.parseKey("user.name");
    try std.testing.expectEqualStrings("user", parts.section);
    try std.testing.expectEqualStrings("name", parts.subkey);
}

test "ConfigSetter parseKey bare key" {
    const parts = ConfigSetter.parseKey("barekey");
    try std.testing.expectEqualStrings("", parts.section);
    try std.testing.expectEqualStrings("barekey", parts.subkey);
}
