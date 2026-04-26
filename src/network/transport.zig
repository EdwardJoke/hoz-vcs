//! Transport Layer - Abstraction for Git network transports
const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol.zig");
const packet = @import("packet.zig");
const refs = @import("refs.zig");
const ssh = @import("ssh.zig");
const SshTransport = ssh.SshTransport;
const parseSshUrl = ssh.parseSshUrl;
const auth_mod = @import("auth.zig");
const runCredentialHelper = auth_mod.runCredentialHelper;
const getEnvCredential = auth_mod.getEnvCredential;

pub const TransportType = enum {
    local,
    http,
    https,
    git,
    ssh,
};

pub const TransportOptions = struct {
    url: []const u8,
    auth: ?[]const u8 = null,
    ssl_verify: bool = true,
};

pub const RefUpdate = struct {
    name: []const u8,
    old_oid: []const u8,
    new_oid: []const u8,
    force: bool = false,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    opts: TransportOptions,
    connected: bool,
    transport_type: TransportType,
    protocol_version: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io, opts: TransportOptions) Transport {
        const ttype = detectTransportType(opts.url) catch .https;
        var final_opts = opts;

        if (opts.auth == null) {
            if (parseHttpUrl(opts.url)) |parsed| {
                if (parsed.token) |token| {
                    final_opts.auth = token;
                }
            } else |_| {}
        }

        return .{
            .allocator = allocator,
            .io = io,
            .opts = final_opts,
            .connected = false,
            .transport_type = ttype,
        };
    }

    pub fn connect(self: *Transport) !void {
        self.connected = true;
    }

    pub fn disconnect(self: *Transport) void {
        self.connected = false;
    }

    pub fn isConnected(self: *Transport) bool {
        return self.connected;
    }

    pub fn fillCredentials(self: *Transport) !void {
        if (self.opts.auth != null) return;

        const parsed = parseHttpUrl(self.opts.url) catch return;
        const protocol_str: []const u8 = if (std.mem.startsWith(u8, self.opts.url, "https://")) "https" else "http";

        if (getEnvCredential(self.allocator, protocol_str, parsed.host)) |_| {
            return;
        }

        if (try runCredentialHelper(self.allocator, self.io, protocol_str, parsed.host)) |creds| {
            defer {
                if (creds.password) |p| self.allocator.free(p);
            }
            if (creds.username != null or creds.password != null) {
                var auth_str = std.ArrayList(u8).empty;
                defer auth_str.deinit(self.allocator);
                if (creds.username) |u| {
                    try auth_str.appendSlice(self.allocator, u);
                    try auth_str.append(self.allocator, ':');
                }
                if (creds.password) |p| {
                    try auth_str.appendSlice(self.allocator, p);
                }
                self.opts.auth = try auth_str.toOwnedSlice(self.allocator);
            }
        }
    }

    pub fn fetchRefs(self: *Transport) ![]const refs.RemoteRef {
        return switch (self.transport_type) {
            .https, .http => self.fetchRefsHttp(),
            .ssh => self.fetchRefsSsh(),
            else => self.fetchRefsGeneric(),
        };
    }

    fn fetchRefsSsh(self: *Transport) ![]const refs.RemoteRef {
        const parsed = try parseSshUrl(self.opts.url);

        var ssh_transport = SshTransport.init(self.allocator, self.io, parsed.host);
        if (parsed.username) |user| {
            ssh_transport.setUsername(user);
        }
        if (parsed.port != 22) {
            ssh_transport.setPort(parsed.port);
        }

        const refs_data = try ssh_transport.fetchRefs(parsed.path);

        var ref_adv = refs.RefAdvertisement.init(self.allocator);
        var lines = std.ArrayList(packet.PacketLine).empty;

        var decoder = packet.PacketDecoder.init(self.allocator);
        decoder.setBuffer(refs_data);

        while (try decoder.next()) |line| {
            try lines.append(self.allocator, line);
        }

        try ref_adv.parse(lines.items);

        self.allocator.free(refs_data);

        const result = ref_adv.refs.values();
        return result;
    }

    fn fetchRefsHttp(self: *Transport) ![]const refs.RemoteRef {
        const parsed = try parseHttpUrl(self.opts.url);
        const service = "git-upload-pack";
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service={s}", .{ parsed.full_path, service });
        defer self.allocator.free(full_url);

        const response = try self.httpGet(full_url, self.opts.auth);
        defer self.allocator.free(response);

        var decoder = packet.PacketDecoder.init(self.allocator);
        decoder.setBuffer(response);

        var ref_adv = refs.RefAdvertisement.init(self.allocator);
        var lines = std.ArrayList(packet.PacketLine).empty;

        while (try decoder.next()) |line| {
            if (std.mem.startsWith(u8, line.data, "# service=")) {
                const cap_line = line.data["# service=".len..];
                const caps = protocol.parseCapabilities(cap_line);
                self.protocol_version = caps.version;
            }
            try lines.append(self.allocator, line);
        }

        try ref_adv.parse(lines.items);

        if (self.protocol_version == 2) {
            return self.fetchRefsHttpV2(parsed);
        }

        const result = ref_adv.refs.values();
        ref_adv.deinit();
        return result;
    }

    fn fetchRefsHttpV2(self: *Transport, parsed: ParsedHttpUrl) ![]const refs.RemoteRef {
        const service = "git-upload-pack";
        const post_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parsed.full_path, service });
        defer self.allocator.free(post_path);

        var request_body = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch |err| return err;
        defer request_body.deinit(self.allocator);

        var encoder = packet.PacketEncoder.init(self.allocator);

        const ls_refs_cmd = "command=ls-refs\n";
        const encoded_cmd = try encoder.encode(ls_refs_cmd);
        defer self.allocator.free(encoded_cmd);
        try request_body.appendSlice(self.allocator, encoded_cmd);

        const caps = "capabilities=ls_refs,fetch_spec,filter\n";
        const encoded_caps = try encoder.encode(caps);
        defer self.allocator.free(encoded_caps);
        try request_body.appendSlice(self.allocator, encoded_caps);

        const flush = encoder.encodeFlush();
        try request_body.appendSlice(self.allocator, flush);

        const host = try self.allocator.dupe(u8, parsed.host);
        defer self.allocator.free(host);

        const port: u16 = parsed.port;

        var address = try std.Io.net.IpAddress.resolve(self.io, host, port);
        var socket = try address.connect(self.io, .{ .mode = .stream });
        errdefer socket.close(self.io);

        var request_buf: [8192]u8 = undefined;
        var request_writer = std.Io.Writer.fixed(&request_buf);

        try request_writer.print(
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: hoz/1.0\r\nAccept: */*\r\nContent-Type: application/x-git-upload-pack-request\r\nContent-Length: {d}\r\n",
            .{ post_path, parsed.host, request_body.items.len },
        );

        if (self.opts.auth) |token| {
            try request_writer.writeAll("Authorization: Bearer ");
            try request_writer.writeAll(token);
            try request_writer.writeAll("\r\n");
        }

        try request_writer.writeAll("\r\n");

        var socket_writer = socket.writer(self.io, &request_buf);
        try socket_writer.interface.writeAll(request_writer.buffer[0..request_writer.end]);
        try socket_writer.interface.flush();

        try socket.socket.send(self.io, &address, request_body.items);

        var response_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (true) {
            const msg = try socket.socket.receive(self.io, response_buf[total_read..]);
            if (msg.data.len == 0) break;
            total_read += msg.data.len;
            if (total_read >= response_buf.len) break;
        }

        const response = try self.allocator.alloc(u8, total_read);
        @memcpy(response, response_buf[0..total_read]);

        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n");
        if (body_start == null) {
            return error.InvalidHttpResponse;
        }

        const status_line = response[0..body_start.?];
        const status_code = parseHttpStatusCode(status_line);

        if (status_code == 401) {
            return error.HttpUnauthorized;
        }

        if (status_code != 200) {
            return error.HttpError;
        }

        self.allocator.free(response);

        var ref_adv = refs.RefAdvertisement.init(self.allocator);
        var lines = std.ArrayList(packet.PacketLine).empty;

        var v2_decoder = packet.PacketDecoder.init(self.allocator);
        v2_decoder.setBuffer(response_buf[body_start.? + 4 .. total_read]);

        while (try v2_decoder.next()) |line| {
            if (line.data.len > 0) {
                try lines.append(self.allocator, line);
            }
        }

        try ref_adv.parse(lines.items);

        const result = ref_adv.refs.values();
        return result;
    }

    fn fetchRefsGeneric(self: *Transport) ![]const refs.RemoteRef {
        const result = try self.allocator.alloc(refs.RemoteRef, 0);
        return result;
    }

    pub fn fetchPack(self: *Transport, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        return switch (self.transport_type) {
            .https, .http => self.fetchPackHttp(wants, haves),
            .ssh => self.fetchPackSsh(wants, haves),
            else => self.fetchPackGeneric(wants, haves),
        };
    }

    fn fetchPackSsh(self: *Transport, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        const parsed = try parseSshUrl(self.opts.url);

        var ssh_transport = SshTransport.init(self.allocator, self.io, parsed.host);
        if (parsed.username) |user| {
            ssh_transport.setUsername(user);
        }
        if (parsed.port != 22) {
            ssh_transport.setPort(parsed.port);
        }

        const pack_data = try ssh_transport.fetchPack(parsed.path, wants, haves);
        return pack_data;
    }

    fn fetchPackHttp(self: *Transport, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        const parsed = try parseHttpUrl(self.opts.url);
        const service = "git-upload-pack";
        const post_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parsed.full_path, service });
        defer self.allocator.free(post_path);

        var request_body = std.ArrayList(u8).empty;
        defer request_body.deinit(self.allocator);

        var encoder = packet.PacketEncoder.init(self.allocator);

        for (wants) |want| {
            const want_line = try std.fmt.allocPrint(self.allocator, "want {s} sideband-64k multi_ack_detailed\n", .{want});
            defer self.allocator.free(want_line);
            const encoded = try encoder.encode(want_line);
            try request_body.appendSlice(self.allocator, encoded);
            self.allocator.free(encoded);
        }

        for (haves) |have| {
            const have_line = try std.fmt.allocPrint(self.allocator, "have {s}\n", .{have});
            defer self.allocator.free(have_line);
            const encoded = try encoder.encode(have_line);
            try request_body.appendSlice(self.allocator, encoded);
            self.allocator.free(encoded);
        }

        const flush = encoder.encodeFlush();
        try request_body.appendSlice(self.allocator, flush);

        const host = try self.allocator.dupe(u8, parsed.host);
        defer self.allocator.free(host);

        const port: u16 = parsed.port;

        var address = try std.Io.net.IpAddress.resolve(self.io, host, port);
        var socket = try address.connect(self.io, .{ .mode = .stream });
        errdefer socket.close(self.io);

        var request_buf: [8192]u8 = undefined;
        var request_writer = std.Io.Writer.fixed(&request_buf);

        try request_writer.print(
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: hoz/1.0\r\nAccept: */*\r\nContent-Type: application/x-git-upload-pack-request\r\nContent-Length: {d}\r\n",
            .{ post_path, parsed.host, request_body.items.len },
        );

        if (self.opts.auth) |token| {
            try request_writer.writeAll("Authorization: Bearer ");
            try request_writer.writeAll(token);
            try request_writer.writeAll("\r\n");
        }

        try request_writer.writeAll("\r\n");

        var socket_writer = socket.writer(self.io, &request_buf);
        try socket_writer.interface.writeAll(request_writer.buffer[0..request_writer.end]);
        try socket_writer.interface.flush();

        try socket.socket.send(self.io, &address, request_body.items);

        var response_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (true) {
            const msg = try socket.socket.receive(self.io, response_buf[total_read..]);
            if (msg.data.len == 0) break;
            total_read += msg.data.len;
            if (total_read >= response_buf.len) break;
        }

        const response = try self.allocator.alloc(u8, total_read);
        @memcpy(response, response_buf[0..total_read]);

        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n");
        if (body_start == null) {
            return error.InvalidHttpResponse;
        }

        const status_line = response[0..body_start.?];
        const status_code = parseHttpStatusCode(status_line);

        if (status_code == 401) {
            return error.HttpUnauthorized;
        }

        if (status_code != 200) {
            return error.HttpError;
        }

        const body_offset = body_start.? + 4;
        const response_body = try self.allocator.dupe(u8, response[body_offset..]);
        self.allocator.free(response);
        return response_body;
    }

    fn fetchPackGeneric(self: *Transport, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        _ = wants;
        _ = haves;
        const result = try self.allocator.alloc(u8, 0);
        return result;
    }

    fn httpGet(self: *Transport, url: []const u8, auth: ?[]const u8) ![]u8 {
        const parsed = try parseHttpUrl(self.opts.url);

        var path_for_request: []const u8 = undefined;

        if (std.mem.indexOf(u8, url, "://") != null) {
            const after_scheme = std.mem.indexOf(u8, url, "://").? + 3;
            const path_start = std.mem.indexOf(u8, url[after_scheme..], "/").?;
            path_for_request = url[after_scheme + path_start ..];
        } else {
            path_for_request = url;
        }

        const host = try self.allocator.dupe(u8, parsed.host);
        defer self.allocator.free(host);

        const port: u16 = parsed.port;

        var address = try std.Io.net.IpAddress.resolve(self.io, host, port);
        var socket = try address.connect(self.io, .{ .mode = .stream });
        errdefer socket.close(self.io);

        var request_buf: [4096]u8 = undefined;
        var request_writer = std.Io.Writer.fixed(&request_buf);

        try request_writer.print(
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: hoz/1.0\r\nAccept: */*\r\n",
            .{ path_for_request, parsed.host },
        );

        if (auth) |token| {
            try request_writer.writeAll("Authorization: Bearer ");
            try request_writer.writeAll(token);
            try request_writer.writeAll("\r\n");
        }

        try request_writer.writeAll("Connection: close\r\n\r\n");

        var socket_writer = socket.writer(self.io, &request_buf);
        try socket_writer.interface.writeAll(request_writer.buffer[0..request_writer.end]);
        try socket_writer.interface.flush();

        var response_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (true) {
            const msg = try socket.socket.receive(self.io, response_buf[total_read..]);
            if (msg.data.len == 0) break;
            total_read += msg.data.len;
            if (total_read >= response_buf.len) break;
        }

        const response = try self.allocator.alloc(u8, total_read);
        @memcpy(response, response_buf[0..total_read]);

        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n");
        if (body_start == null) {
            return error.InvalidHttpResponse;
        }

        const status_line = response[0..body_start.?];
        const status_code = parseHttpStatusCode(status_line);

        if (status_code == 401) {
            return error.HttpUnauthorized;
        }

        if (status_code != 200) {
            return error.HttpError;
        }

        const body_offset = body_start.? + 4;
        const body = response[body_offset..];

        const response_body = try self.allocator.dupe(u8, body);
        self.allocator.free(response);
        return response_body;
    }

    fn parseHttpStatusCode(status_line: []const u8) u16 {
        var i: usize = 0;
        while (i < status_line.len and status_line[i] != ' ') i += 1;
        i += 1;
        if (i >= status_line.len) return 0;
        const code_start = i;
        while (i < status_line.len and status_line[i] >= '0' and status_line[i] <= '9') i += 1;
        if (i == code_start) return 0;
        const code_str = status_line[code_start..i];
        return std.fmt.parseInt(u16, code_str, 10) catch 0;
    }

    pub fn pushRefs(self: *Transport, updates: []const RefUpdate, pack_data: ?[]const u8) !void {
        return switch (self.transport_type) {
            .https, .http => self.pushRefsHttp(updates, pack_data),
            .ssh => self.pushRefsSsh(updates, pack_data),
            else => error.NotImplemented,
        };
    }

    fn pushRefsHttp(self: *Transport, updates: []const RefUpdate, pack_data: ?[]const u8) !void {
        const parsed = try parseHttpUrl(self.opts.url);
        const service = "git-receive-pack";

        // First, get the ref advertisement to check capabilities
        const refs_url = try std.fmt.allocPrint(self.allocator, "{s}/info/refs?service={s}", .{ parsed.full_path, service });
        defer self.allocator.free(refs_url);

        const refs_response = try self.httpGet(refs_url, self.opts.auth);
        defer self.allocator.free(refs_response);

        // Parse capabilities from refs response
        var caps = protocol.ProtocolCapabilities{};
        var decoder = packet.PacketDecoder.init(self.allocator);
        decoder.setBuffer(refs_response);

        while (try decoder.next()) |line| {
            if (line.data.len > 0 and !std.mem.startsWith(u8, line.data, "# service=")) {
                // Parse ref line for capabilities
                const space_idx = std.mem.indexOf(u8, line.data, " ");
                if (space_idx) |idx| {
                    const caps_str = line.data[idx + 1 ..];
                    caps = protocol.parseCapabilities(caps_str);
                }
            }
        }

        // Build push request body
        var request_body = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer request_body.deinit(self.allocator);

        var encoder = packet.PacketEncoder.init(self.allocator);

        // Send capabilities
        const cap_line = try self.buildPushCapabilities(&caps);
        defer self.allocator.free(cap_line);
        const encoded_caps = try encoder.encode(cap_line);
        defer self.allocator.free(encoded_caps);
        try request_body.appendSlice(self.allocator, encoded_caps);

        // Send ref updates
        for (updates) |update| {
            const update_line = try std.fmt.allocPrint(
                self.allocator,
                "{s} {s} {s}",
                .{ update.old_oid, update.new_oid, update.name },
            );
            defer self.allocator.free(update_line);
            const encoded = try encoder.encode(update_line);
            defer self.allocator.free(encoded);
            try request_body.appendSlice(self.allocator, encoded);
        }

        // Flush to end commands
        const flush = encoder.encodeFlush();
        try request_body.appendSlice(self.allocator, flush);

        // Append packfile if provided
        if (pack_data) |pack| {
            try request_body.appendSlice(self.allocator, pack);
        }

        // Send POST request
        const post_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parsed.full_path, service });
        defer self.allocator.free(post_path);

        const host = try self.allocator.dupe(u8, parsed.host);
        defer self.allocator.free(host);

        var address = try std.Io.net.IpAddress.resolve(self.io, host, parsed.port);
        var socket = try address.connect(self.io, .{ .mode = .stream });
        errdefer socket.close(self.io);

        var request_buf: [8192]u8 = undefined;
        var request_writer = std.Io.Writer.fixed(&request_buf);

        try request_writer.print(
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: hoz/1.0\r\nAccept: */*\r\nContent-Type: application/x-git-receive-pack-request\r\nContent-Length: {d}\r\n",
            .{ post_path, parsed.host, request_body.items.len },
        );

        if (self.opts.auth) |token| {
            try request_writer.writeAll("Authorization: Bearer ");
            try request_writer.writeAll(token);
            try request_writer.writeAll("\r\n");
        }

        try request_writer.writeAll("\r\n");

        var socket_writer = socket.writer(self.io, &request_buf);
        try socket_writer.interface.writeAll(request_writer.buffer[0..request_writer.end]);
        try socket_writer.interface.flush();

        try socket.socket.send(self.io, &address, request_body.items);

        // Read response
        var response_buf: [65536]u8 = undefined;
        var total_read: usize = 0;

        while (true) {
            const msg = try socket.socket.receive(self.io, response_buf[total_read..]);
            if (msg.data.len == 0) break;
            total_read += msg.data.len;
            if (total_read >= response_buf.len) break;
        }

        socket.close(self.io);

        const body_start = std.mem.indexOf(u8, response_buf[0..total_read], "\r\n\r\n");
        if (body_start == null) {
            return error.InvalidHttpResponse;
        }

        const status_line = response_buf[0..body_start.?];
        const status_code = parseHttpStatusCode(status_line);

        if (status_code == 401) {
            return error.HttpUnauthorized;
        }

        if (status_code != 200) {
            return error.HttpError;
        }

        // Parse response for errors
        const response_body = response_buf[body_start.? + 4 .. total_read];
        var resp_decoder = packet.PacketDecoder.init(self.allocator);
        resp_decoder.setBuffer(response_body);

        while (try resp_decoder.next()) |line| {
            if (std.mem.startsWith(u8, line.data, "ng ")) {
                // Push rejected
                return error.PushRejected;
            }
        }
    }

    fn pushRefsSsh(self: *Transport, updates: []const RefUpdate, pack_data: ?[]const u8) !void {
        const parsed = try parseSshUrl(self.opts.url);

        var ssh_transport = SshTransport.init(self.allocator, self.io, parsed.host);
        if (parsed.username) |user| {
            ssh_transport.setUsername(user);
        }
        if (parsed.port != 22) {
            ssh_transport.setPort(parsed.port);
        }

        // Build push command
        var cmd_buffer = try std.ArrayList(u8).initCapacity(self.allocator, 4096);
        defer cmd_buffer.deinit(self.allocator);

        try cmd_buffer.appendSlice(self.allocator, "git-receive-pack ");
        try cmd_buffer.appendSlice(self.allocator, parsed.path);

        const conn = try self.sshConnect(parsed.host, if (parsed.port > 0) parsed.port else 22);
        defer conn.close(self.io);

        try self.sendSshPack(conn, cmd_buffer.items, updates, pack_data);
        return;
    }

    fn sshConnect(self: *Transport, host: []const u8, port: u16) !std.Io.net.Stream {
        const addr = std.Io.net.Address.parseIp4(host, port) catch
            return error.SshConnectionFailed;
        const stream = try addr.connect(self.io);
        return stream;
    }

    fn sendSshPack(self: *Transport, stream: std.Io.net.Stream, cmd: []const u8, updates: []RefUpdate, pack_data: ?[]const u8) !void {
        _ = updates;

        var writer = stream.writer(self.io, &{});
        try writer.interface.writeAll(cmd);
        try writer.interface.writeAll("\n");

        const read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &.{});

        const pkt_line_len = reader.interface.read(&read_buf) catch 0;
        if (pkt_line_len == 0 or read_buf[0] == 0)
            return error.SshProtocolError;

        if (pack_data) |data| {
            try writer.interface.writeAll(data);
        }

        try writer.interface.writeAll("0000");

        _ = reader.interface.read(&read_buf) catch 0;
    }

    fn buildPushCapabilities(self: *Transport, caps: *const protocol.ProtocolCapabilities) ![]const u8 {
        _ = self;

        var parts = std.ArrayList([]const u8).initCapacity(std.heap.page_allocator, 8);
        errdefer {
            for (parts.items) |p| std.heap.page_allocator.free(p);
            parts.deinit(std.heap.page_allocator);
        }

        if (caps.report_status) {
            try parts.append(std.heap.page_allocator, "report-status");
        }
        if (caps.sideband_64k) {
            try parts.append(std.heap.page_allocator, "side-band-64k");
        } else if (caps.sideband) {
            try parts.append(std.heap.page_allocator, "side-band");
        }
        if (caps.atomic) {
            try parts.append(std.heap.page_allocator, "atomic");
        }
        if (caps.push_options) {
            try parts.append(std.heap.page_allocator, "push-options");
        }
        if (caps.multi_ack_detailed) {
            try parts.append(std.heap.page_allocator, "multi_ack_detailed");
        } else if (caps.multi_ack) {
            try parts.append(std.heap.page_allocator, "multi_ack");
        }

        const agent_val = try std.fmt.allocPrint(std.heap.page_allocator, "agent={s}", .{caps.agent});
        try parts.append(std.heap.page_allocator, agent_val);

        const result = try std.mem.join(std.heap.page_allocator, " ", parts.items);
        for (parts.items) |p| std.heap.page_allocator.free(p);
        parts.deinit(std.heap.page_allocator);
        return result;
    }
};

const ParsedHttpUrl = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    full_path: []const u8,
    token: ?[]const u8,
};

fn parseHttpUrl(url: []const u8) !ParsedHttpUrl {
    const has_https = std.mem.startsWith(u8, url, "https://");
    const has_http = std.mem.startsWith(u8, url, "http://");
    const scheme: []const u8 = if (has_https) "https" else if (has_http) "http" else return error.InvalidUrl;
    const path_start: usize = if (has_https) 8 else if (has_http) 7 else return error.InvalidUrl;
    const path_and_host = url[path_start..];
    const slash_idx = std.mem.indexOf(u8, path_and_host, "/");
    const host_and_port = if (slash_idx) |idx| path_and_host[0..idx] else path_and_host;
    const path = if (slash_idx) |idx| path_and_host[idx..] else "/";
    const at_idx = std.mem.indexOf(u8, host_and_port, "@");
    const token: ?[]const u8 = if (at_idx) |idx| host_and_port[0..idx] else null;
    const clean_host_port = if (at_idx) |idx| host_and_port[idx + 1 ..] else host_and_port;
    const colon_idx = std.mem.indexOf(u8, clean_host_port, ":");
    const host: []const u8 = if (colon_idx) |idx| clean_host_port[0..idx] else clean_host_port;
    const port: u16 = if (colon_idx) |idx| try std.fmt.parseInt(u16, clean_host_port[idx + 1 ..], 10) else if (has_https) 443 else 80;
    const full_path: []const u8 = path;
    return .{
        .scheme = scheme,
        .host = host,
        .port = port,
        .path = path,
        .full_path = full_path,
        .token = token,
    };
}

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    auth: ?[]const u8,
    ssl_verify: bool,
    connected: bool,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) HttpTransport {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .auth = null,
            .ssl_verify = true,
            .connected = false,
        };
    }

    pub fn setAuth(self: *HttpTransport, auth_token: []const u8) void {
        self.auth = auth_token;
    }

    pub fn connect(self: *HttpTransport) !void {
        self.connected = true;
    }

    pub fn disconnect(self: *HttpTransport) void {
        self.connected = false;
    }

    pub fn request(self: *HttpTransport, path: []const u8, service: []const u8) ![]u8 {
        _ = path;
        _ = service;
        const result = try self.allocator.alloc(u8, 0);
        return result;
    }

    pub fn fetchRefs(self: *HttpTransport) ![]const refs.RemoteRef {
        const result = try self.allocator.alloc(refs.RemoteRef, 0);
        return result;
    }
};

pub const GitProtocolTransport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    host: []const u8,
    port: u16,
    connected: bool,
    caps: protocol.ProtocolCapabilities,
    socket: ?std.Io.Stream = null,
    address: std.Io.net.IpAddress = undefined,

    pub fn init(allocator: std.mem.Allocator, io: Io, host: []const u8, port: u16) GitProtocolTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = port,
            .connected = false,
            .caps = protocol.ProtocolCapabilities{},
            .socket = null,
        };
    }

    pub fn deinit(self: *GitProtocolTransport) void {
        if (self.socket) |*sock| {
            sock.close();
        }
    }

    pub fn connect(self: *GitProtocolTransport) !void {
        self.address = try std.Io.net.IpAddress.resolve(self.io, self.host, self.port);
        self.socket = try self.address.connect(self.io, .{ .mode = .stream });
        self.connected = true;
    }

    pub fn disconnect(self: *GitProtocolTransport) void {
        if (self.socket) |*sock| {
            sock.close();
            self.socket = null;
        }
        self.connected = false;
    }

    pub fn sendPacket(self: *GitProtocolTransport, data: []const u8) !void {
        if (self.socket) |*sock| {
            var buf: [8192]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);
            try writer.writeAll(data);
            try sock.writeAll(self.io, buf[0..data.len]);
        }
    }

    pub fn receivePacket(self: *GitProtocolTransport) ![]u8 {
        if (self.socket) |*sock| {
            var buf: [65536]u8 = undefined;
            const n = try sock.read(self.io, &buf);
            if (n == 0) return &[0]u8{};
            return try self.allocator.dupe(u8, buf[0..n]);
        }
        return &[0]u8{};
    }

    pub fn sendWant(self: *GitProtocolTransport, oid: []const u8, caps: []const u8) !void {
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("want {s} {s}\n", .{ oid, caps });
        try self.sendPacket(buf[0..writer.end]);
    }

    pub fn sendHave(self: *GitProtocolTransport, oid: []const u8) !void {
        var buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("have {s}\n", .{oid});
        try self.sendPacket(buf[0..writer.end]);
    }

    pub fn sendDone(self: *GitProtocolTransport) !void {
        const flush: [4]u8 = .{ 0, 0, 0, 0 };
        try self.sendPacket(&flush);
    }

    pub fn receivePack(self: *GitProtocolTransport) ![]u8 {
        return try self.receivePacket();
    }

    pub fn negotiate(self: *GitProtocolTransport, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        const caps_str = self.caps.toCapabilitiesString();

        for (wants) |want| {
            try self.sendWant(want, caps_str);
        }

        for (haves) |have| {
            try self.sendHave(have);
        }

        try self.sendDone();

        return try self.receivePack();
    }
};

pub fn createTransport(allocator: std.mem.Allocator, io: Io, opts: TransportOptions) !Transport {
    const transport = Transport.init(allocator, io, opts);
    return transport;
}

pub fn detectTransportType(url: []const u8) !TransportType {
    if (std.mem.startsWith(u8, url, "https://")) {
        return .https;
    } else if (std.mem.startsWith(u8, url, "http://")) {
        return .http;
    } else if (std.mem.startsWith(u8, url, "git://")) {
        return .git;
    } else if (std.mem.startsWith(u8, url, "ssh://") or std.mem.startsWith(u8, url, "git@")) {
        return .ssh;
    } else if (std.mem.startsWith(u8, url, "file://")) {
        return .local;
    }
    return error.UnknownTransport;
}

test "Transport init" {
    const io = std.Io.Threaded.new(.{}).?;
    const transport = Transport.init(std.testing.allocator, io, .{ .url = "https://github.com/user/repo" });
    try std.testing.expect(transport.connected == false);
}

test "HttpTransport init" {
    const transport = HttpTransport.init(std.testing.allocator, "https://github.com/user/repo");
    try std.testing.expect(transport.connected == false);
}

test "GitProtocolTransport init" {
    const transport = GitProtocolTransport.init(std.testing.allocator, "github.com", 9418);
    try std.testing.expect(transport.connected == false);
}

test "detectTransportType https" {
    const t = try detectTransportType("https://github.com/user/repo");
    try std.testing.expect(t == .https);
}

test "detectTransportType http" {
    const t = try detectTransportType("http://example.com/repo");
    try std.testing.expect(t == .http);
}

test "detectTransportType git protocol" {
    const t = try detectTransportType("git://github.com/user/repo");
    try std.testing.expect(t == .git);
}

test "detectTransportType ssh" {
    const t = try detectTransportType("ssh://git@github.com/user/repo");
    try std.testing.expect(t == .ssh);
}

test "detectTransportType local file" {
    const t = try detectTransportType("file:///path/to/repo");
    try std.testing.expect(t == .local);
}

test "TransportOptions with auth" {
    const opts = TransportOptions{ .url = "https://github.com/user/repo", .auth = "token123" };
    try std.testing.expect(opts.auth != null);
}

test "parseHttpUrl https" {
    const parsed = try parseHttpUrl("https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("github.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
}

test "parseHttpUrl http with port" {
    const parsed = try parseHttpUrl("http://example.com:8080/user/repo");
    try std.testing.expectEqualStrings("http", parsed.scheme);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
}
