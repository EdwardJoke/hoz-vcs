//! Config Read/Write - Git-config file handling
const std = @import("std");
const Io = std.Io;

pub const ConfigReader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigReader {
        return .{ .allocator = allocator };
    }

    pub fn read(self: *ConfigReader, io: Io, path: []const u8) ![][]const u8 {
        const cwd = Io.Dir.cwd();
        const content = try cwd.readFileAlloc(io, path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(content);

        var lines = std.ArrayList([]const u8).initCapacity(self.allocator, 64) catch |err| return err;
        errdefer lines.deinit(self.allocator);
        var start: usize = 0;
        for (content, 0..) |byte, i| {
            if (byte == '\n') {
                const line = std.mem.trim(u8, content[start..i], "\r");
                if (line.len > 0 and !std.mem.startsWith(u8, line, "#")) {
                    const owned = try self.allocator.dupe(u8, line);
                    try lines.append(self.allocator, owned);
                }
                start = i + 1;
            }
        }
        if (start < content.len) {
            const line = std.mem.trim(u8, content[start..], "\r");
            if (line.len > 0 and !std.mem.startsWith(u8, line, "#")) {
                const owned = try self.allocator.dupe(u8, line);
                try lines.append(self.allocator, owned);
            }
        }
        return lines.toOwnedSlice(self.allocator);
    }

    pub fn parseLine(self: *ConfigReader, line: []const u8) !?struct { key: []const u8, value: []const u8 } {
        _ = self;
        const trim_line = std.mem.trim(u8, line, " \t");
        if (trim_line.len == 0 or std.mem.startsWith(u8, trim_line, "#")) {
            return null;
        }
        if (std.mem.startsWith(u8, trim_line, "[") and std.mem.endsWith(u8, trim_line, "]")) {
            return null;
        }
        const eq_idx = std.mem.indexOf(u8, trim_line, "=") orelse return null;
        const key = std.mem.trim(u8, trim_line[0..eq_idx], " \t");
        const value = std.mem.trim(u8, trim_line[eq_idx + 1 ..], " \t");
        return .{ .key = key, .value = value };
    }

    pub fn getRemoteUrl(self: *ConfigReader, io: Io, git_dir: []const u8, remote_name: []const u8) !?[]const u8 {
        const config_path = try std.mem.concat(self.allocator, u8, &.{ git_dir, "/config" });
        defer self.allocator.free(config_path);

        const lines = self.read(io, config_path) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }

        var in_section = false;
        const expected_section = try std.mem.concat(self.allocator, u8, &.{ "remote \"", remote_name, "\"" });
        defer self.allocator.free(expected_section);

        for (lines) |line| {
            const trim_line = std.mem.trim(u8, line, " \t");
            if (std.mem.startsWith(u8, trim_line, "[") and std.mem.endsWith(u8, trim_line, "]")) {
                in_section = std.mem.eql(u8, trim_line, expected_section);
            } else if (in_section) {
                if (try self.parseLine(line)) |entry| {
                    if (std.mem.eql(u8, entry.key, "url")) {
                        return try self.allocator.dupe(u8, entry.value);
                    }
                }
            }
        }
        return null;
    }
};

pub const ConfigWriter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigWriter {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *ConfigWriter, io: Io, path: []const u8, entries: []const struct { key: []const u8, value: []const u8 }) !void {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer buf.deinit(self.allocator);

        for (entries) |entry| {
            const line = try std.fmt.allocPrint(self.allocator, "{s} = {s}\n", .{ entry.key, entry.value });
            defer self.allocator.free(line);
            try buf.appendSlice(self.allocator, line);
        }

        const cwd = Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = path, .data = buf.items });
    }

    pub fn formatEntry(self: *ConfigWriter, key: []const u8, value: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s} = {s}", .{ key, value });
    }

    pub fn getBool(self: *ConfigWriter, value: []const u8) ?bool {
        _ = self;
        const trimmed = std.mem.trim(u8, value, " \t");
        if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "on")) {
            return true;
        }
        if (std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "no") or std.mem.eql(u8, trimmed, "off")) {
            return false;
        }
        return null;
    }
};

test "ConfigReader init" {
    const reader = ConfigReader.init(std.testing.allocator);
    _ = reader;
}

test "ConfigReader read method exists" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    var reader = ConfigReader.init(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, reader.read(io, "/path/to/nonexistent/config"));
}

test "ConfigWriter init" {
    const writer = ConfigWriter.init(std.testing.allocator);
    _ = writer;
}

test "ConfigWriter write method exists" {
    var writer = ConfigWriter.init(std.testing.allocator);
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = std.Io.Threaded.io(&threaded);
    try std.testing.expectError(error.FileNotFound, writer.write(io, "/path/to/nonexistent/config", &.{}));
}
