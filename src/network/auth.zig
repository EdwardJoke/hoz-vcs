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
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "credential", "fill" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        return null;
    };

    const request = try std.fmt.allocPrint(allocator, "protocol={s}\nhost={s}\n\n", .{ protocol, host });
    defer allocator.free(request);

    try child.stdin.?.writeStreamingAll(io, request);
    child.stdin.?.close(io);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return null;
        },
        else => return null,
    }

    var stdout_file = child.stdout.?;
    defer stdout_file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = stdout_file.reader(io, &buf);
    const output = try reader.interface.allocRemaining(allocator, .limited(65536));

    var username: ?[]const u8 = null;
    var password: ?[]u8 = null;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "username=")) {
            username = try allocator.dupe(u8, line[9..]);
        } else if (std.mem.startsWith(u8, line, "password=")) {
            password = try allocator.dupe(u8, line[9..]);
        }
    }

    if (username == null and password == null) {
        allocator.free(output);
        return null;
    }

    return CredentialHelperResult{
        .username = username,
        .password = password,
    };
}

pub fn getEnvCredential(allocator: std.mem.Allocator, protocol: []const u8, host: []const u8) ?CredentialHelperResult {
    _ = allocator;
    _ = host;
    if (std.mem.eql(u8, protocol, "https")) {
        if (std.c.getenv("HTTPS_PROXY")) |_| {
            return CredentialHelperResult{
                .username = null,
                .password = null,
            };
        }
    } else if (std.mem.eql(u8, protocol, "http")) {
        if (std.c.getenv("HTTP_PROXY")) |_| {
            return CredentialHelperResult{
                .username = null,
                .password = null,
            };
        }
    }
    if (std.c.getenv("GIT_ASKPASS")) |_| {
        return CredentialHelperResult{
            .username = null,
            .password = null,
        };
    }
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
