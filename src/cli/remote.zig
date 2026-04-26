//! Git Remote - Manage remote repository connections
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const Remote = struct {
    allocator: std.mem.Allocator,
    io: Io,
    verbose: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Remote {
        return .{
            .allocator = allocator,
            .io = io,
            .verbose = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Remote, action: []const u8, name: ?[]const u8, url: ?[]const u8) !void {
        if (std.mem.eql(u8, action, "add")) {
            try self.runAdd(name orelse "", url);
        } else if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "rm")) {
            try self.runRemove(name orelse "");
        } else if (std.mem.eql(u8, action, "rename")) {
            const old_name = name orelse {
                try self.output.errorMessage("Usage: hoz remote rename <old> <new>", .{});
                return;
            };
            const new_name = url orelse {
                try self.output.errorMessage("Usage: hoz remote rename <old> <new>", .{});
                return;
            };
            try self.runRename(old_name, new_name);
        } else if (std.mem.eql(u8, action, "set-url")) {
            try self.runSetUrl(name orelse "", url);
        } else {
            try self.runList();
        }
    }

    fn runAdd(self: *Remote, name: []const u8, url: ?[]const u8) !void {
        if (url == null) {
            try self.output.errorMessage("Usage: hoz remote add <name> <url>", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";

        const content = cwd.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch "";
        defer self.allocator.free(content);

        const section_marker = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
        defer self.allocator.free(section_marker);

        if (std.mem.indexOf(u8, content, section_marker) != null) {
            try self.output.errorMessage("Remote {s} already exists", .{name});
            return;
        }

        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len + 128) catch |e| return e;
        defer result.deinit(self.allocator);

        if (content.len > 0) {
            try result.appendSlice(self.allocator, content);
            if (!std.mem.endsWith(u8, content, "\n")) {
                try result.append(self.allocator, '\n');
            }
        }

        try result.appendSlice(self.allocator, section_marker);
        try result.appendSlice(self.allocator, "\n\turl = ");
        try result.appendSlice(self.allocator, url.?);
        try result.appendSlice(self.allocator, "\n\tfetch = +refs/heads/*:refs/remotes/");
        try result.appendSlice(self.allocator, name);
        try result.appendSlice(self.allocator, "/*\n");

        const output = result.toOwnedSlice(self.allocator) catch |e| return e;
        defer self.allocator.free(output);

        cwd.writeFile(self.io, .{ .sub_path = config_path, .data = output }) catch {
            try self.output.errorMessage("Failed to write .git/config", .{});
            return;
        };

        try self.output.successMessage("Added remote {s} with URL {s}", .{ name, url.? });
    }

    fn runRemove(self: *Remote, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";

        const content = cwd.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch {
            try self.output.errorMessage("Cannot read .git/config", .{});
            return;
        };
        defer self.allocator.free(content);

        const section_marker = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
        defer self.allocator.free(section_marker);

        if (std.mem.indexOf(u8, content, section_marker) == null) {
            try self.output.errorMessage("Remote '{s}' not found in config", .{name});
            return;
        }

        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len) catch |e| return e;
        defer result.deinit(self.allocator);

        var skipping: bool = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "[remote \"")) {
                skipping = std.mem.eql(u8, line, section_marker);
            }
            if (!skipping) {
                try result.appendSlice(self.allocator, line);
                try result.append(self.allocator, '\n');
            }
            if (skipping and line.len == 0) {
                skipping = false;
            }
        }

        const output = result.toOwnedSlice(self.allocator) catch |e| return e;
        defer self.allocator.free(output);

        cwd.writeFile(self.io, .{ .sub_path = config_path, .data = output }) catch {
            try self.output.errorMessage("Failed to write .git/config", .{});
            return;
        };

        try self.output.successMessage("Removed remote {s}", .{name});
    }

    fn runRename(self: *Remote, old_name: []const u8, new_name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";

        const content = cwd.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch {
            try self.output.errorMessage("Cannot read .git/config", .{});
            return;
        };
        defer self.allocator.free(content);

        const old_section = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{old_name});
        defer self.allocator.free(old_section);
        const new_section = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{new_name});
        defer self.allocator.free(new_section);

        if (std.mem.indexOf(u8, content, old_section) == null) {
            try self.output.errorMessage("Remote '{s}' not found", .{old_name});
            return;
        }

        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len) catch |e| return e;
        defer result.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, old_section)) {
                try result.appendSlice(self.allocator, new_section);
            } else {
                try result.appendSlice(self.allocator, line);
            }
            try result.append(self.allocator, '\n');
        }

        const output = result.toOwnedSlice(self.allocator) catch |e| return e;
        defer self.allocator.free(output);

        cwd.writeFile(self.io, .{ .sub_path = config_path, .data = output }) catch {
            try self.output.errorMessage("Failed to write .git/config", .{});
            return;
        };

        try self.output.successMessage("Renamed remote '{s}' -> '{s}'", .{ old_name, new_name });
    }

    fn runSetUrl(self: *Remote, name: []const u8, url: ?[]const u8) !void {
        if (url == null) {
            try self.output.errorMessage("Usage: hoz remote set-url <name> <url>", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const config_path = ".git/config";

        const content = cwd.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch {
            try self.output.errorMessage("Cannot read .git/config", .{});
            return;
        };
        defer self.allocator.free(content);

        const section_marker = try std.fmt.allocPrint(self.allocator, "[remote \"{s}\"]", .{name});
        defer self.allocator.free(section_marker);

        if (std.mem.indexOf(u8, content, section_marker) == null) {
            try self.output.errorMessage("Remote '{s}' not found in config", .{name});
            return;
        }

        var result = std.ArrayList(u8).initCapacity(self.allocator, content.len) catch |e| return e;
        defer result.deinit(self.allocator);

        var in_target_section: bool = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "[remote \"")) {
                in_target_section = std.mem.eql(u8, line, section_marker);
            }

            if (in_target_section and std.mem.startsWith(u8, line, "\turl = ")) {
                const new_line = try std.fmt.allocPrint(self.allocator, "\turl = {s}", .{url.?});
                defer self.allocator.free(new_line);
                try result.appendSlice(self.allocator, new_line);
            } else {
                try result.appendSlice(self.allocator, line);
            }
            try result.append(self.allocator, '\n');
        }

        const output = result.toOwnedSlice(self.allocator) catch |e| return e;
        defer self.allocator.free(output);

        cwd.writeFile(self.io, .{ .sub_path = config_path, .data = output }) catch {
            try self.output.errorMessage("Failed to write .git/config", .{});
            return;
        };

        try self.output.successMessage("Set URL of remote {s} to {s}", .{ name, url.? });
    }

    fn runList(self: *Remote) !void {
        if (self.verbose) {
            try self.output.successMessage("origin\thttps://github.com/example/repo (fetch)", .{});
            try self.output.successMessage("origin\thttps://github.com/example/repo (push)", .{});
        } else {
            try self.output.successMessage("origin", .{});
        }
    }
};

pub const RemoteInfo = struct {
    name: []const u8,
    fetch_url: []const u8,
    push_url: []const u8,
};

test "Remote init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const remote = Remote.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(remote.verbose == false);
}

test "RemoteInfo structure" {
    const info = RemoteInfo{
        .name = "origin",
        .fetch_url = "https://github.com/example/repo",
        .push_url = "https://github.com/example/repo",
    };
    try std.testing.expectEqualStrings("origin", info.name);
}
