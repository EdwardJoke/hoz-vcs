//! SSH Transport - SSH connection support
const std = @import("std");
const Io = std.Io;

pub const SshTransport = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    username: ?[]const u8,
    key_path: ?[]const u8,
    agent_forward: bool,
    io: Io,
    connected: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, host: []const u8) SshTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = 22,
            .username = null,
            .key_path = null,
            .agent_forward = false,
            .connected = false,
        };
    }

    pub fn setUsername(self: *SshTransport, username: []const u8) void {
        self.username = username;
    }

    pub fn setPort(self: *SshTransport, port: u16) void {
        self.port = port;
    }

    pub fn setKeyPath(self: *SshTransport, path: []const u8) void {
        self.key_path = path;
    }

    pub fn setAgentForward(self: *SshTransport, enabled: bool) void {
        self.agent_forward = enabled;
    }

    pub fn connect(self: *SshTransport) !void {
        if (self.connected) return;
        self.connected = true;
    }

    pub fn disconnect(self: *SshTransport) void {
        if (!self.connected) return;
        self.connected = false;
    }

    pub fn fetchRefs(self: *SshTransport, path: []const u8) ![]const u8 {
        const ssh_cmd = try self.buildSshCommand(path, "git-upload-pack");
        defer self.allocator.free(ssh_cmd);

        const result = try self.runGitCommand(ssh_cmd);
        return result;
    }

    pub fn fetchPack(self: *SshTransport, path: []const u8, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        const ssh_cmd = try self.buildSshCommand(path, "git-upload-pack");
        defer self.allocator.free(ssh_cmd);

        var request_data = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch |err| return err;
        defer request_data.deinit(self.allocator);

        for (wants) |want| {
            const line = try std.fmt.allocPrint(self.allocator, "want {s}\n", .{want});
            defer self.allocator.free(line);
            try request_data.appendSlice(self.allocator, line);
        }

        for (haves) |have| {
            const line = try std.fmt.allocPrint(self.allocator, "have {s}\n", .{have});
            defer self.allocator.free(line);
            try request_data.appendSlice(self.allocator, line);
        }

        try request_data.appendSlice(self.allocator, "\n");

        const result = try self.runGitCommandWithStdin(ssh_cmd, request_data.items);
        return result;
    }

    fn buildSshCommand(self: *SshTransport, path: []const u8, service: []const u8) ![]const u8 {
        var cmd_parts = std.ArrayList([]const u8).initCapacity(self.allocator, 16) catch |err| return err;
        defer cmd_parts.deinit(self.allocator);

        try cmd_parts.append(self.allocator, "ssh");

        if (self.port != 22) {
            try cmd_parts.append(self.allocator, "-p");
            try cmd_parts.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{self.port}));
        }

        if (self.key_path) |key| {
            try cmd_parts.append(self.allocator, "-i");
            try cmd_parts.append(self.allocator, key);
        }

        if (self.agent_forward) {
            try cmd_parts.append(self.allocator, "-A");
        }

        try cmd_parts.append(self.allocator, "-o");
        try cmd_parts.append(self.allocator, "StrictHostKeyChecking=accept-new");

        var target = std.ArrayList(u8).initCapacity(self.allocator, 64) catch |err| return err;
        defer target.deinit(self.allocator);

        if (self.username) |user| {
            try target.appendSlice(self.allocator, user);
            try target.append(self.allocator, '@');
        }
        try target.appendSlice(self.allocator, self.host);

        try cmd_parts.append(self.allocator, try target.toOwnedSlice(self.allocator));

        const remote_path = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service={s}", .{ path, service });
        defer self.allocator.free(remote_path);
        try cmd_parts.append(self.allocator, remote_path);

        var result_cmd = std.ArrayList(u8).initCapacity(self.allocator, 512) catch |err| return err;
        errdefer result_cmd.deinit(self.allocator);

        for (cmd_parts.items, 0..) |part, i| {
            if (i > 0) try result_cmd.appendSlice(self.allocator, " ");
            if (std.mem.indexOfAny(u8, part, " \t\n\"'$")) |_| {
                try result_cmd.appendSlice(self.allocator, "\"");
                for (part) |c| {
                    if (c == '"' or c == '$' or c == '\\') try result_cmd.append(self.allocator, '\\');
                    try result_cmd.append(self.allocator, c);
                }
                try result_cmd.appendSlice(self.allocator, "\"");
            } else {
                try result_cmd.appendSlice(self.allocator, part);
            }
        }

        return result_cmd.toOwnedSlice(self.allocator);
    }

    fn runGitCommand(self: *SshTransport, ssh_cmd: []const u8) ![]const u8 {
        const full_cmd = try std.fmt.allocPrint(self.allocator, "{s} 2>/dev/null", .{ssh_cmd});
        defer self.allocator.free(full_cmd);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", full_cmd },
            .stdin = .inherit,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        const term = try child.wait(self.io);

        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    return error.SshCommandFailed;
                }
            },
            else => return error.SshCommandFailed,
        }

        var stdout_file = child.stdout.?;
        defer stdout_file.close(self.io);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try stdout_file.readStreaming(self.io, &.{&buf});
            if (n == 0) break;
            try result.appendSlice(self.allocator, buf[0..n]);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn runGitCommandWithStdin(self: *SshTransport, ssh_cmd: []const u8, stdin_data: []const u8) ![]u8 {
        const shell_cmd = try std.fmt.allocPrint(self.allocator, "cat << 'HOZEOF' | {s}", .{ssh_cmd});
        defer self.allocator.free(shell_cmd);

        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "/bin/sh", "-c", shell_cmd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        try child.stdin.?.writeStreamingAll(self.io, stdin_data);
        child.stdin.?.close(self.io);

        const term = try child.wait(self.io);

        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    return error.SshCommandFailed;
                }
            },
            else => return error.SshCommandFailed,
        }

        var stdout_file = child.stdout.?;
        defer stdout_file.close(self.io);

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        while (true) {
            const n = try stdout_file.readStreaming(self.io, &.{&buf});
            if (n == 0) break;
            try result.appendSlice(self.allocator, buf[0..n]);
        }

        return try result.toOwnedSlice(self.allocator);
    }
};

pub const SshOptions = struct {
    host: []const u8,
    port: u16 = 22,
    username: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    agent_forward: bool = false,
    known_hosts_check: bool = true,
};

pub const ParsedSshUrl = struct {
    username: ?[]const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub fn parseSshUrl(url: []const u8) !ParsedSshUrl {
    var remaining = url;
    var username: ?[]const u8 = null;
    var host: []const u8 = undefined;
    var port: u16 = 22;
    var path: []const u8 = "";

    if (std.mem.startsWith(u8, remaining, "ssh://")) {
        remaining = remaining[6..];
    } else if (std.mem.startsWith(u8, remaining, "git@")) {
        const at_idx = std.mem.indexOf(u8, remaining, "@");
        if (at_idx) |idx| {
            username = remaining[4..idx];
            remaining = remaining[idx + 1 ..];
        }
    }

    const colon_idx = std.mem.indexOf(u8, remaining, ":");
    const slash_idx = std.mem.indexOf(u8, remaining, "/");

    if (colon_idx != null and (slash_idx == null or colon_idx.? < slash_idx.?)) {
        host = remaining[0..colon_idx.?];
        const port_str = remaining[colon_idx.? + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch 22;
        if (slash_idx) |sidx| {
            path = remaining[sidx..];
        }
    } else {
        if (slash_idx) |sidx| {
            host = remaining[0..sidx];
            path = remaining[sidx..];
        } else {
            host = remaining;
        }
    }

    return .{
        .username = username,
        .host = host,
        .port = port,
        .path = path,
    };
}

test "SshTransport init" {
    const allocator = std.testing.allocator;
    const transport = SshTransport.init(allocator, "github.com");
    try std.testing.expectEqualStrings("github.com", transport.host);
    try std.testing.expect(transport.port == 22);
}

test "SshTransport setUsername" {
    const allocator = std.testing.allocator;
    var transport = SshTransport.init(allocator, "github.com");
    transport.setUsername("git");
    try std.testing.expectEqualStrings("git", transport.username);
}

test "parseSshUrl git@ style" {
    const result = try parseSshUrl("git@github.com:user/repo.git");
    try std.testing.expectEqualStrings("git", result.username);
    try std.testing.expectEqualStrings("github.com", result.host);
    try std.testing.expectEqualStrings("/user/repo.git", result.path);
}
