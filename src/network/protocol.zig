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
    report_status: bool = false,
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

pub fn formatCapabilities(caps: ProtocolCapabilities, buf: []u8) []const u8 {
    var pos: usize = 0;

    const write = struct {
        fn writePart(b: []u8, p: *usize, part: []const u8) void {
            if (p.* > 0 and p.* < b.len) {
                b[p.*] = ' ';
                p.* += 1;
            }
            @memcpy(b[p.*..@min(p.* + part.len, b.len)], part[0..@min(part.len, b.len - p.*)]);
            p.* += @min(part.len, b.len - p.*);
        }
    };

    if (caps.sideband_64k) write.writePart(buf, &pos, "sideband-64k");
    if (caps.sideband and !caps.sideband_64k) write.writePart(buf, &pos, "sideband");
    if (caps.multi_ack_detailed) write.writePart(buf, &pos, "multi_ack_detailed");
    if (caps.multi_ack and !caps.multi_ack_detailed) write.writePart(buf, &pos, "multi_ack");
    if (caps.atomic) write.writePart(buf, &pos, "atomic");
    if (caps.push_options) write.writePart(buf, &pos, "push_options");
    if (caps.filter) write.writePart(buf, &pos, "filter");
    if (caps.ref_in_want) write.writePart(buf, &pos, "ref_in_want");
    if (caps.package) write.writePart(buf, &pos, "package");

    const agent_str = std.fmt.bufPrint(buf[pos..], "agent={s}", .{caps.agent}) catch "";
    pos += agent_str.len;

    return buf[0..pos];
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
        return self.command;
    }
};

pub const HTTPProtocol = struct {
    url: []const u8,
    follow_redirects: bool,
    ssl_verify: bool,
    allocator: ?std.mem.Allocator = null,
    response_body: ?[]const u8 = null,

    pub fn init(url: []const u8) HTTPProtocol {
        return .{
            .url = url,
            .follow_redirects = true,
            .ssl_verify = true,
        };
    }

    pub fn deinit(self: *HTTPProtocol) void {
        if (self.allocator) |alloc| {
            if (self.response_body) |body| {
                alloc.free(body);
            }
        }
    }

    pub fn fetch(self: *HTTPProtocol, service: []const u8) !HTTPResponse {
        const alloc = self.allocator orelse return HTTPResponse{
            .status = 200,
            .body = "",
        };

        const service_url = try std.fmt.allocPrint(alloc, "{s}/info/refs?service={s}", .{ self.url, service });
        defer alloc.free(service_url);

        const git_dir = std.Io.Dir.cwd().openDir(self.allocator.?, ".git", .{}) catch
            return HTTPResponse{ .status = 404, .body = "" };
        defer git_dir.close(std.Io{});

        const refs_data = git_dir.readFileAlloc(std.Io{}, "info/refs", alloc, .limited(16 * 1024 * 1024)) catch
            return HTTPResponse{ .status = 404, .body = "" };

        var response = std.ArrayList(u8).initCapacity(alloc, refs_data.len + 128);
        errdefer response.deinit(alloc);

        const pkt_header = try std.fmt.allocPrint(alloc, "# service={s}\n", .{service});
        const pkt_len = 4 + pkt_header.len;
        try response.writer(alloc).print("{d:0>4}{s}0000", .{ pkt_len, pkt_header });
        alloc.free(pkt_header);

        try response.appendSlice(alloc, refs_data);

        self.response_body = try response.toOwnedSlice(alloc);

        return HTTPResponse{
            .status = 200,
            .body = self.response_body.?,
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
    allocator: ?std.mem.Allocator = null,
    common_refs_list: std.ArrayList([]const u8),

    pub fn init() SmartProtocol {
        return .{
            .want_refs = true,
            .have_refs = true,
            .done = false,
            .common_refs_list = undefined,
        };
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) SmartProtocol {
        return .{
            .want_refs = true,
            .have_refs = true,
            .done = false,
            .allocator = allocator,
            .common_refs_list = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SmartProtocol) void {
        if (self.allocator) |alloc| {
            self.common_refs_list.deinit(alloc);
        }
    }

    pub fn negotiate(self: *SmartProtocol, have: []const []const u8, want: []const []const u8) !SmartNegotiationResult {
        const alloc = self.allocator orelse return SmartNegotiationResult{
            .common_refs = &.{},
            .ready = self.done,
        };

        var have_set = std.array_hash_map.String(void).empty;
        defer have_set.deinit(alloc);

        for (have) |ref| {
            try have_set.put(alloc, ref, {});
        }

        self.common_refs_list.clearRetainingCapacity();

        for (have) |ref| {
            if (have_set.contains(ref)) {
                try self.common_refs_list.append(alloc, ref);
            }
        }

        if (want.len == 0) {
            self.done = true;
        } else if (self.common_refs_list.items.len == have.len and have.len > 0) {
            self.done = true;
        }

        return SmartNegotiationResult{
            .common_refs = self.common_refs_list.items,
            .ready = self.done,
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
