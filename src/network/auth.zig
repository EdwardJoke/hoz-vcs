//! Authentication - Credential helper and auth support
const std = @import("std");
const Io = std.Io;

pub const CredentialType = enum {
    userpass,
    ssh_key,
    bearer,
    cookie,
};

pub const Credential = struct {
    allocator: std.mem.Allocator,
    protocol: []const u8,
    host: []const u8,
    username: ?[]const u8,
    password: ?[]u8,
    path: ?[]const u8,
    auth_type: CredentialType,

    pub fn init(allocator: std.mem.Allocator, protocol: []const u8, host: []const u8) Credential {
        return .{
            .allocator = allocator,
            .protocol = protocol,
            .host = host,
            .username = null,
            .password = null,
            .path = null,
            .auth_type = .userpass,
        };
    }

    pub fn deinit(self: *Credential) void {
        if (self.password) |p| {
            self.allocator.free(p);
        }
    }

    pub fn setUsername(self: *Credential, username: []const u8) void {
        self.username = username;
    }

    pub fn setPassword(self: *Credential, password: []u8) void {
        self.password = password;
    }
};

pub const CredentialHelperResult = struct {
    username: ?[]const u8,
    password: ?[]u8,
};

pub fn runCredentialHelper(allocator: std.mem.Allocator, io: Io, protocol: []const u8, host: []const u8) !?CredentialHelperResult {
    _ = io;
    _ = protocol;
    _ = host;
    return null;
}

pub fn getEnvCredential(allocator: std.mem.Allocator, protocol: []const u8, host: []const u8) ?CredentialHelperResult {
    _ = allocator;
    _ = protocol;
    _ = host;
    return null;
}

test "Credential init" {
    const allocator = std.testing.allocator;
    const cred = Credential.init(allocator, "https", "github.com");
    try std.testing.expectEqualStrings("https", cred.protocol);
    try std.testing.expectEqualStrings("github.com", cred.host);
    try std.testing.expect(cred.username == null);
    try std.testing.expect(cred.password == null);
}

test "Credential setUsername" {
    const allocator = std.testing.allocator;
    var cred = Credential.init(allocator, "https", "github.com");
    cred.setUsername("user");
    try std.testing.expectEqualStrings("user", cred.username);
}
