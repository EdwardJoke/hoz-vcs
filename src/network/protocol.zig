//! Protocol - Git protocol implementations
//!
//! This module provides implementations for various Git protocols
//! including SSH, HTTP/HTTPS, and smart protocol negotiation.

const std = @import("std");

pub const ProtocolType = enum {
    ssh,
    https,
    http,
    git,
    file,
};

pub const ProtocolOptions = struct {
    protocol: ProtocolType,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    user: ?[]const u8 = null,
    path: []const u8,
};

pub const ProtocolV2Capability = enum {
    agent,
    thin_pack,
    no_thin,
    sideband,
    sideband_64k,
    multi_ack,
    multi_ack_detailed,
    allow_tip_sha1_in_want,
    allow_reachable_sha1_in_want,
    no_progress,
    include_tag,
    blot_push_options,
    push_options,
    atomic,
    delete_refs,
    quiet,
    report_status,
    package,
    filter,
    ref_in_want,
    ls_refs,
    fetch_spec,
};

pub const ProtocolCapabilities = struct {
    version: u8 = 0,
    multi_ack: bool = false,
    multi_ack_detailed: bool = false,
    sideband: bool = false,
    sideband_64k: bool = false,
    atomic: bool = false,
    push_options: bool = false,
    filter: bool = false,
    ref_in_want: bool = false,
    agent: []const u8 = "hoz",
    package: bool = false,
};

pub fn parseProtocolUrl(url: []const u8) !ProtocolOptions {
    if (std.mem.startsWith(u8, url, "ssh://")) {
        return parseSSHUrl(url);
    } else if (std.mem.startsWith(u8, url, "git://")) {
        return parseGitUrl(url);
    } else if (std.mem.startsWith(u8, url, "http://")) {
        return ProtocolOptions{ .protocol = .http, .path = url[7..] };
    } else if (std.mem.startsWith(u8, url, "https://")) {
        return ProtocolOptions{ .protocol = .https, .path = url[8..] };
    } else if (std.mem.startsWith(u8, url, "file://")) {
        return ProtocolOptions{ .protocol = .file, .path = url[7..] };
    }
    return error.InvalidProtocol;
}

fn parseSSHUrl(url: []const u8) !ProtocolOptions {
    var opts = ProtocolOptions{ .protocol = .ssh, .path = "" };
    const without_prefix = url[6..];

    if (std.mem.indexOf(u8, without_prefix, "@")) |at_idx| {
        opts.user = without_prefix[0..at_idx];
        const after_at = without_prefix[at_idx + 1 ..];
        if (std.mem.indexOf(u8, after_at, ":")) |colon_idx| {
            opts.host = after_at[0..colon_idx];
            opts.port = try std.fmt.parseInt(u16, after_at[colon_idx + 1 ..], 10);
            const path_start = std.mem.indexOf(u8, after_at, "/");
            opts.path = if (path_start) |p| after_at[p..] else "/";
        } else {
            if (std.mem.indexOf(u8, after_at, "/")) |slash_idx| {
                opts.host = after_at[0..slash_idx];
                opts.path = after_at[slash_idx..];
            } else {
                opts.host = after_at;
                opts.path = "/";
            }
        }
    } else {
        if (std.mem.indexOf(u8, without_prefix, ":")) |colon_idx| {
            opts.host = without_prefix[0..colon_idx];
            opts.path = without_prefix[colon_idx..];
        } else {
            opts.host = without_prefix;
            opts.path = "/";
        }
    }
    return opts;
}

fn parseGitUrl(url: []const u8) !ProtocolOptions {
    var opts = ProtocolOptions{ .protocol = .git, .path = "" };
    const without_prefix = url[6..];

    if (std.mem.indexOf(u8, without_prefix, "/")) |slash_idx| {
        opts.host = without_prefix[0..slash_idx];
        opts.path = without_prefix[slash_idx..];
    } else {
        opts.host = without_prefix;
        opts.path = "/";
    }
    return opts;
}

pub fn parseCapabilities(line: []const u8) ProtocolCapabilities {
    var caps = ProtocolCapabilities{};

    var iter = std.mem.splitScalar(u8, line, ' ');
    while (iter.next()) |cap| {
        if (std.mem.startsWith(u8, cap, "agent=")) {
            caps.agent = cap[6..];
        } else if (std.mem.eql(u8, cap, "sideband")) {
            caps.sideband = true;
        } else if (std.mem.eql(u8, cap, "sideband-64k")) {
            caps.sideband = true;
            caps.sideband_64k = true;
        } else if (std.mem.eql(u8, cap, "multi_ack")) {
            caps.multi_ack = true;
        } else if (std.mem.eql(u8, cap, "multi_ack_detailed")) {
            caps.multi_ack = true;
            caps.multi_ack_detailed = true;
        } else if (std.mem.eql(u8, cap, "atomic")) {
            caps.atomic = true;
        } else if (std.mem.eql(u8, cap, "push_options")) {
            caps.push_options = true;
        } else if (std.mem.eql(u8, cap, "filter")) {
            caps.filter = true;
        } else if (std.mem.eql(u8, cap, "ref_in_want")) {
            caps.ref_in_want = true;
        } else if (std.mem.eql(u8, cap, "no-progress")) {
            // handled by client preference
        } else if (std.mem.eql(u8, cap, "include-tag")) {
            // handled by client preference
        } else if (std.mem.eql(u8, cap, "thin-pack")) {
            // handled by client preference
        } else if (std.mem.eql(u8, cap, "ls_refs")) {
            caps.version = 2;
        } else if (std.mem.eql(u8, cap, "fetch_spec")) {
            caps.version = 2;
        }
    }

    if (caps.version == 0 and (caps.sideband or caps.multi_ack)) {
        caps.version = 1;
    }

    return caps;
}

pub fn formatCapabilities(caps: ProtocolCapabilities) []const u8 {
    _ = caps;
    return "sideband-64k multi_ack_detailed atomic push_options filter ref_in_want agent=hoz";
}

pub const SSHProtocol = struct {
    host: []const u8,
    port: u16,
    user: []const u8,
    command: []const u8,

    pub fn connect(host: []const u8, port: u16, user: []const u8, path: []const u8) !SSHProtocol {
        _ = path;
        return SSHProtocol{
            .host = host,
            .port = port,
            .user = user,
            .command = "git-upload-pack",
        };
    }

    pub fn formatCommand(self: *const SSHProtocol) []const u8 {
        _ = self;
        return "git-upload-pack";
    }
};

pub const HTTPProtocol = struct {
    url: []const u8,
    follow_redirects: bool,
    ssl_verify: bool,

    pub fn init(url: []const u8) HTTPProtocol {
        return .{
            .url = url,
            .follow_redirects = true,
            .ssl_verify = true,
        };
    }

    pub fn fetch(self: *HTTPProtocol, service: []const u8) !HTTPResponse {
        _ = self;
        _ = service;
        return HTTPResponse{
            .status = 200,
            .body = &.{},
        };
    }
};

pub const HTTPResponse = struct {
    status: u16,
    body: []const u8,
};

pub const SmartProtocol = struct {
    want_refs: bool,
    have_refs: bool,
    done: bool,

    pub fn init() SmartProtocol {
        return .{
            .want_refs = true,
            .have_refs = true,
            .done = false,
        };
    }

    pub fn negotiate(self: *SmartProtocol, have: []const []const u8, want: []const []const u8) !SmartNegotiationResult {
        _ = self;
        _ = have;
        _ = want;
        return SmartNegotiationResult{
            .common_refs = &.{},
            .ready = false,
        };
    }
};

pub const SmartNegotiationResult = struct {
    common_refs: []const []const u8,
    ready: bool,
};

pub const ProtocolExtension = struct {
    name: []const u8,
    supported: bool,
};

pub const MultiAckMode = enum {
    none,
    multi_ack,
    multi_ack_detailed,
};

test "ProtocolType enum values" {
    try std.testing.expect(@intFromEnum(ProtocolType.ssh) == 0);
    try std.testing.expect(@intFromEnum(ProtocolType.https) == 1);
}

test "HTTPProtocol init" {
    const proto = HTTPProtocol.init("https://github.com/user/repo.git");
    try std.testing.expect(proto.follow_redirects == true);
    try std.testing.expect(proto.ssl_verify == true);
}

test "SmartProtocol init" {
    const proto = SmartProtocol.init();
    try std.testing.expect(proto.want_refs == true);
    try std.testing.expect(proto.have_refs == true);
    try std.testing.expect(proto.done == false);
}

test "parseProtocolUrl with https" {
    const opts = try parseProtocolUrl("https://github.com/user/repo.git");
    try std.testing.expect(opts.protocol == .https);
    try std.testing.expectEqualStrings("github.com/user/repo.git", opts.path);
}

test "parseProtocolUrl with ssh" {
    const opts = try parseProtocolUrl("ssh://git@github.com:22/user/repo.git");
    try std.testing.expect(opts.protocol == .ssh);
    try std.testing.expectEqualStrings("git", opts.user.?);
    try std.testing.expectEqualStrings("github.com", opts.host.?);
    try std.testing.expectEqualStrings("/user/repo.git", opts.path);
}

test "parseProtocolUrl with git protocol" {
    const opts = try parseProtocolUrl("git://github.com/user/repo.git");
    try std.testing.expect(opts.protocol == .git);
    try std.testing.expectEqualStrings("github.com", opts.host.?);
    try std.testing.expectEqualStrings("/user/repo.git", opts.path);
}

test "parseCapabilities" {
    const caps = parseCapabilities("sideband-64k multi_ack_detailed atomic agent=hoz/1.0");
    try std.testing.expect(caps.sideband == true);
    try std.testing.expect(caps.sideband_64k == true);
    try std.testing.expect(caps.multi_ack_detailed == true);
    try std.testing.expect(caps.atomic == true);
    try std.testing.expectEqualStrings("hoz/1.0", caps.agent);
}

test "parseCapabilities with ref_in_want" {
    const caps = parseCapabilities("ref_in_want sideband-64k");
    try std.testing.expect(caps.ref_in_want == true);
    try std.testing.expect(caps.sideband_64k == true);
}
