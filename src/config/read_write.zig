//! Config Read/Write - TOML file handling
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
                const line = content[start..i];
                if (line.len > 0 and !std.mem.startsWith(u8, line, "#")) {
                    try lines.append(self.allocator, line);
                }
                start = i + 1;
            }
        }
        if (start < content.len) {
            const line = content[start..];
            if (line.len > 0 and !std.mem.startsWith(u8, line, "#")) {
                try lines.append(self.allocator, line);
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

    pub fn write(self: *ConfigWriter, path: []const u8, entries: []const struct { key: []const u8, value: []const u8 }) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        for (entries) |entry| {
            try buf.writer().print("{s} = {s}\n", .{ entry.key, entry.value });
        }

        const cwd = Io.Dir.cwd();
        try cwd.writeFile(self.allocator, path, buf.items, .{});
    }

    pub fn formatEntry(self: *ConfigWriter, key: []const u8, value: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s} = {s}", .{ key, value });
    }

    pub fn getBool(self: *ConfigWriter, value: []const u8) ?bool {
        _ = self;
        const trimmed = std.mem.trim(u8, value, " \t");
        if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "yes")) {
            return true;
        }
        if (std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "no")) {
            return false;
        }
        return null;
    }
};

test "ConfigReader init" {
    const reader = ConfigReader.init(std.testing.allocator);
    try std.testing.expect(reader.allocator == std.testing.allocator);
}

test "ConfigReader read method exists" {
    var reader = ConfigReader.init(std.testing.allocator);
    const io = std.Io.Threaded.new(.{}).?;
    const entries = try reader.read(io, "/path/to/config");
    _ = entries;
    try std.testing.expect(true);
}

test "ConfigWriter init" {
    const writer = ConfigWriter.init(std.testing.allocator);
    try std.testing.expect(writer.allocator == std.testing.allocator);
}

test "ConfigWriter write method exists" {
    var writer = ConfigWriter.init(std.testing.allocator);
    try writer.write("/path/to/config", &.{});
    try std.testing.expect(true);
}
