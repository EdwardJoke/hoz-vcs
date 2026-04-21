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

    pub fn init(allocator: std.mem.Allocator, host: []const u8) SshTransport {
        return .{
            .allocator = allocator,
            .host = host,
            .port = 22,
            .username = null,
            .key_path = null,
            .agent_forward = false,
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

    pub fn connect(self: *SshTransport, io: Io) !void {
        _ = self;
        _ = io;
    }

    pub fn disconnect(self: *SshTransport) void {
        _ = self;
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

pub fn parseSshUrl(url: []const u8) !struct { username: ?[]const u8, host: []const u8, port: u16, path: []const u8 } {
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
