//! Clone Bare - Bare repository clone
const std = @import("std");
const Io = std.Io;
const CloneOptions = @import("options.zig").CloneOptions;
const CloneResult = @import("options.zig").CloneResult;
const network = @import("../network/network.zig");
const protocol = @import("../network/protocol.zig");
const packet = @import("../network/packet.zig");
const transport = @import("../network/transport.zig");
const refs = @import("../network/refs.zig");

pub const CloneError = error{
    TransportError,
    RefNotFound,
    CloneFailed,
    ShallowNotSupported,
};

pub const BareCloner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BareCloner {
        return .{ .allocator = allocator };
    }

    pub fn clone(self: *BareCloner, url: []const u8, path: []const u8) !void {
        return self.cloneWithOptions(url, path, .{});
    }

    pub fn cloneWithOptions(self: *BareCloner, url: []const u8, path: []const u8, options: CloneOptions) !void {
        _ = path;
        const parsed_url = try protocol.parseProtocolUrl(url);
        const t = transport.Transport.init(self.allocator, .{
            .url = url,
        });
        _ = t;
        _ = parsed_url;
        _ = options;
        return error.NotImplemented;
    }

    pub fn cloneWithDepth(self: *BareCloner, url: []const u8, path: []const u8, depth: u32) !void {
        const options = CloneOptions{ .depth = depth };
        return self.cloneWithOptions(url, path, options);
    }

    pub fn createBareRepository(self: *BareCloner, path: []const u8) !void {
        _ = self;
        _ = path;
        return error.NotImplemented;
    }

    pub fn setupRemoteTrackingRefs(self: *BareCloner, remote_name: []const u8) !void {
        _ = self;
        _ = remote_name;
        return error.NotImplemented;
    }
};

pub fn normalizeClonePath(url: []const u8) []const u8 {
    if (std.mem.endsWith(u8, url, ".git")) {
        return url[0 .. url.len - 4];
    }
    return url;
}

pub fn getRepoNameFromUrl(url: []const u8) []const u8 {
    var path = url;
    if (std.mem.indexOf(u8, path, "://")) |idx| {
        path = path[idx + 3 ..];
    }
    if (std.mem.indexOf(u8, path, "@")) |idx| {
        path = path[idx + 1 ..];
    }
    if (std.mem.endsWith(u8, path, ".git")) {
        path = path[0 .. path.len - 4];
    }
    while (std.mem.endsWith(u8, path, "/")) {
        path = path[0 .. path.len - 1];
    }
    if (std.mem.indexOf(u8, path, "/")) |idx| {
        return path[idx + 1 ..];
    }
    return path;
}

test "BareCloner init" {
    const cloner = BareCloner.init(std.testing.allocator);
    try std.testing.expect(cloner.allocator == std.testing.allocator);
}

test "BareCloner clone method exists" {
    var cloner = BareCloner.init(std.testing.allocator);
    try cloner.clone("https://github.com/user/repo.git", "/tmp/repo");
    try std.testing.expect(true);
}

test "BareCloner cloneWithDepth method exists" {
    var cloner = BareCloner.init(std.testing.allocator);
    try cloner.cloneWithDepth("https://github.com/user/repo.git", "/tmp/repo", 50);
    try std.testing.expect(true);
}

test "normalizeClonePath with .git suffix" {
    const path = normalizeClonePath("https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("https://github.com/user/repo", path);
}

test "normalizeClonePath without .git suffix" {
    const path = normalizeClonePath("https://github.com/user/repo");
    try std.testing.expectEqualStrings("https://github.com/user/repo", path);
}

test "getRepoNameFromUrl simple" {
    const name = getRepoNameFromUrl("https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("repo", name);
}

test "getRepoNameFromUrl with ssh" {
    const name = getRepoNameFromUrl("ssh://git@github.com/user/repo.git");
    try std.testing.expectEqualStrings("repo", name);
}
