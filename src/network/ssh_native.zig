//! Native SSH Transport via libssh2
const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("libssh2.h");
    @cInclude("sys/socket.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("netinet/in.h");
});

pub const NativeSshError = error{
    InitFailed,
    SessionInitFailed,
    HandshakeFailed,
    AuthFailed,
    ChannelOpenFailed,
    ExecFailed,
    SocketError,
    HostKeyMismatch,
    Timeout,
    Disconnected,
    UnknownHostKey,
    AgentInitFailed,
    NoAuthMethodsAvailable,
    PublicKeyAuthFailed,
    PasswordAuthFailed,
    KeyboardInteractiveFailed,
    ReadFailed,
    WriteFailed,
    ScpFailed,
    SftpFailed,
    ResolveFailed,
};

pub const SshAuthMethod = enum {
    none,
    password,
    publickey,
    agent,
    keyboard_interactive,
};

pub const NativeSshOptions = struct {
    host: []const u8,
    port: u16 = 22,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
    passphrase: ?[]const u8 = null,
    known_hosts_path: ?[]const u8 = null,
    strict_host_key_checking: bool = true,
    connect_timeout: u32 = 10,
    auth_timeout: u32 = 30,
};

pub const NativeSshSession = struct {
    allocator: std.mem.Allocator,
    io: Io,
    opts: NativeSshOptions,
    session: ?*c.LIBSSH2_SESSION,
    sock: c_int,
    connected: bool,
    authenticated: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, opts: NativeSshOptions) NativeSshSession {
        return .{
            .allocator = allocator,
            .io = io,
            .opts = opts,
            .session = null,
            .sock = -1,
            .connected = false,
            .authenticated = false,
        };
    }

    pub fn deinit(self: *NativeSshSession) void {
        self.disconnect();
    }

    pub fn connect(self: *NativeSshSession) !void {
        if (self.connected) return;

        var rc = c.libssh2_init(0);
        if (rc != 0) return NativeSshError.InitFailed;

        const host_c = try self.allocator.dupeZ(u8, self.opts.host);
        defer self.allocator.free(host_c);

        const hints: c.struct_addrinfo = .{
            .ai_family = c.AF_UNSPEC,
            .ai_socktype = c.SOCK_STREAM,
            .ai_protocol = c.IPPROTO_TCP,
            .ai_flags = c.AI_ADDRCONFIG,
            .ai_addrlen = 0,
            .ai_addr = null,
            .ai_canonname = null,
            .ai_next = null,
        };

        var servinfo: ?*c.struct_addrinfo = null;
        rc = c.getaddrinfo(host_c, null, &hints, &servinfo);
        if (rc != 0 or servinfo == null) return NativeSshError.ResolveFailed;
        defer c.freeaddrinfo(servinfo);

        var target_addr: c.struct_sockaddr_storage = undefined;
        var addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
        var found = false;

        var p = servinfo;
        while (p != null) : (p = p.?.ai_next) {
            const ai = p.?;
            if (ai.ai_family == c.AF_INET or ai.ai_family == c.AF_INET6) {
                const src_len: c.socklen_t = if (ai.ai_family == c.AF_INET)
                    @sizeOf(c.struct_sockaddr_in)
                else
                    @sizeOf(c.struct_sockaddr_in6);
                @memcpy(@as([*]u8, @ptrCast(&target_addr))[0..src_len], @as([*]const u8, @constCast(ai.ai_addr))[0..src_len]);
                addr_len = src_len;

                if (ai.ai_family == c.AF_INET) {
                    var ipv4_ptr: *c.struct_sockaddr_in = @ptrCast(&target_addr);
                    ipv4_ptr.sin_port = c.htons(self.opts.port);
                } else {
                    var ipv6_ptr: *c.struct_sockaddr_in6 = @ptrCast(&target_addr);
                    ipv6_ptr.sin6_port = c.htons(self.opts.port);
                }
                found = true;
                break;
            }
        }

        if (!found) return NativeSshError.ResolveFailed;

        self.sock = c.socket(target_addr.ss_family, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (self.sock < 0) return NativeSshError.SocketError;

        const tv = c.timeval{
            .tv_sec = @as(c.time_t, @intCast(self.opts.connect_timeout)),
            .tv_usec = 0,
        };
        _ = c.setsockopt(self.sock, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.timeval));
        _ = c.setsockopt(self.sock, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.timeval));

        rc = c.connect(self.sock, @ptrCast(&target_addr), addr_len);
        if (rc != 0) {
            _ = c.close(self.sock);
            self.sock = -1;
            return NativeSshError.SocketError;
        }

        self.session = c.libssh2_session_init(null);
        if (self.session == null) {
            _ = c.close(self.sock);
            self.sock = -1;
            return NativeSshError.SessionInitFailed;
        }

        c.libssh2_session_set_blocking(self.session.?, 1);

        rc = c.libssh2_handshake(self.session.?, self.sock);
        if (rc != 0) {
            c.libssh2_session_free(self.session.?);
            self.session = null;
            _ = c.close(self.sock);
            self.sock = -1;
            return NativeSshError.HandshakeFailed;
        }

        if (self.opts.strict_host_key_checking) {
            try self.verifyHostKey();
        }

        self.connected = true;
    }

    fn verifyHostKey(self: *NativeSshSession) !void {
        const fingerprint = c.libssh2_hostkey_hash(self.session.?, c.LIBSSH2_HOSTKEY_HASH_SHA256);
        if (fingerprint == null) return NativeSshError.HostKeyMismatch;

        var knownhosts = c.libssh2_knownhost_init(self.session.?);
        if (knownhosts == null) return;

        defer c.libssh2_knownhost_free(knownhosts);

        if (self.opts.known_hosts_path) |path| {
            const path_c = try self.allocator.dupeZ(u8, path);
            defer self.allocator.free(path_c);
            _ = c.libssh2_readfile(knownhosts, path_c, null);
        } else {
            const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch "";
            defer if (home.len > 0) self.allocator.free(home);
            const default_path = try std.fmt.allocPrint(self.allocator, "{s}/.ssh/known_hosts", .{home});
            defer self.allocator.free(default_path);
            const default_c = try self.allocator.dupeZ(u8, default_path);
            defer self.allocator.free(default_c);
            _ = c.libssh2_knownhost_readfile(knownhosts, default_c, c.LIBSSH2_KNOWNHOST_FILE_OPENSSH);
        }

        const host_c = try self.allocator.dupeZ(u8, self.opts.host);
        defer self.allocator.free(host_c);

        var key: ?*c.libssh2_knownhost = null;
        var typ: c.int = 0;
        const check = c.libssh2_checkhost_knownhost(knownhosts, host_c, self.opts.port, &typ, &key);

        if (check == c.LIBSSH2_KNOWNHOST_CHECK_MISMATCH) {
            return NativeSshError.HostKeyMismatch;
        } else if (check == c.LIBSSH2_KNOWNHOST_CHECK_NOTFOUND) {
            if (self.opts.strict_host_key_checking) {
                return NativeSshError.UnknownHostKey;
            }
        }
    }

    pub fn authenticate(self: *NativeSshSession) !void {
        if (!self.connected) try self.connect();
        if (self.authenticated) return;

        const username = self.opts.username orelse try self.getDefaultUsername();

        const auth_methods = c.libssh2_userauth_list(self.session.?, username.ptr, @as(c.uint, @intCast(username.len)));
        if (auth_methods == null) {
            const rc = c.libssh2_userauth_authenticated(self.session.?);
            if (rc != 0) return NativeSshError.NoAuthMethodsAvailable;
            self.authenticated = true;
            return;
        }

        const methods_str = auth_methods[0..std.mem.len(u8, auth_methods)];

        if (self.opts.key_path != null and std.mem.indexOf(u8, methods_str, "publickey") != null) {
            if (self.authenticatePublicKey(username)) {
                self.authenticated = true;
                return;
            }
        }

        if (std.mem.indexOf(u8, methods_str, "agent") != null) {
            if (self.authenticateAgent(username)) {
                self.authenticated = true;
                return;
            }
        }

        if (self.opts.password != null and std.mem.indexOf(u8, methods_str, "password") != null) {
            if (self.authenticatePassword(username)) {
                self.authenticated = true;
                return;
            }
        }

        if (std.mem.indexOf(u8, methods_str, "keyboard-interactive") != null) {
            if (self.authenticateKeyboardInteractive(username)) {
                self.authenticated = true;
                return;
            }
        }

        return NativeSshError.AuthFailed;
    }

    fn authenticatePublicKey(self: *NativeSshSession, username: [*:0]const u8) bool {
        const key_path_c = self.opts.key_path orelse return false;
        const key_path_z = self.allocator.dupeZ(u8, key_path_c) catch return false;
        defer self.allocator.free(key_path_z);

        const pubkey_path = std.fmt.allocPrint(self.allocator, "{s}.pub", .{key_path_c}) catch return false;
        defer self.allocator.free(pubkey_path);
        const pubkey_path_z = self.allocator.dupeZ(u8, pubkey_path) catch return false;
        defer self.allocator.free(pubkey_path_z);

        const passphrase_c = if (self.opts.passphrase) |p|
            self.allocator.dupeZ(u8, p) catch null
        else
            null;
        defer if (passphrase_c) |p| self.allocator.free(p);

        const rc = c.libssh2_userauth_publickey_fromfile(
            self.session.?,
            username,
            pubkey_path_z,
            key_path_z,
            if (passphrase_c) |p| p else null,
        );
        return rc == 0;
    }

    fn authenticateAgent(self: *NativeSshSession, username: [*:0]const u8) bool {
        const agent = c.libssh2_agent_init(self.session.?) orelse return false;
        defer c.libssh2_agent_free(agent);

        if (c.libssh2_agent_connect(agent) != 0) return false;
        defer _ = c.libssh2_agent_disconnect(agent);

        if (c.libssh2_agent_list_id(agent) != 0) return false;

        var prev: ?*c.libssh2_agent_identity = null;
        while (true) {
            const identity = c.libssh2_agent_get_identity(agent, prev) orelse break;
            prev = identity;

            const rc = c.libssh2_userauth_agent(self.session.?, username, agent, identity);
            if (rc == 0) return true;
        }

        return false;
    }

    fn authenticatePassword(self: *NativeSshSession, username: [*:0]const u8) bool {
        const password = self.opts.password orelse return false;
        const password_c = self.allocator.dupeZ(u8, password) catch return false;
        defer self.allocator.free(password_c);

        const rc = c.libssh2_userauth_password(self.session.?, username, password_c);
        return rc == 0;
    }

    fn authenticateKeyboardInteractive(self: *NativeSshSession, username: [*:0]const u8) bool {
        const rc = c.libssh2_userauth_keyboard_interactive(
            self.session.?,
            username,
            struct {
                fn kbdCallback(
                    name: [*c]const u8,
                    name_len: c_int,
                    instruction: [*c]const u8,
                    instruction_len: c_int,
                    num_prompts: c.int,
                    prompts: [*c][*c]c.LIBSSH2_USERAUTH_KBDINT_PROMPT,
                    responses: [*c][*c]c.LIBSSH2_USERAUTH_KBDINT_RESPONSE,
                    abstract: ?*anyopaque,
                ) callconv(.C) c_int {
                    _ = name;
                    _ = name_len;
                    _ = instruction;
                    _ = instruction_len;
                    _ = abstract;
                    var i: c.int = 0;
                    while (i < num_prompts) : (i += 1) {
                        responses[i] = prompts[i].response;
                    }
                    return 0;
                }.kbdCallback,
            },
        );
        return rc == 0;
    }

    fn getDefaultUsername(self: *NativeSshSession) ![*:0]u8 {
        if (self.opts.username) |u| {
            return self.allocator.dupeZ(u8, u);
        }
        const user = std.process.getEnvVarOwned(self.allocator, "USER") catch "";
        if (user.len > 0) {
            return self.allocator.dupeZ(u8, user);
        }
        const login = std.process.getEnvVarOwned(self.allocator, "LOGNAME") catch "";
        if (login.len > 0) {
            return self.allocator.dupeZ(u8, login);
        }
        const pw = c.getpwuid(c.getuid());
        if (pw != null and pw.?.pw_name != null) {
            const name = pw.?.pw_name;
            const len = std.mem.len(u8, name);
            const result = self.allocator.allocSentinel(u8, len + 1, 0) catch return error.AuthFailed;
            @memcpy(result[0..len], name[0..len]);
            return result;
        }
        return self.allocator.dupeZ(u8, "git");
    }

    pub fn execCommand(self: *NativeSshSession, command: []const u8) ![]u8 {
        if (!self.authenticated) try self.authenticate();

        const cmd_c = try self.allocator.dupeZ(u8, command);
        defer self.allocator.free(cmd_c);

        const channel = c.libssh2_channel_open_session(self.session.?);
        if (channel == null) return NativeSshError.ChannelOpenFailed;
        defer _ = c.libssh2_channel_close(channel);
        defer c.libssh2_channel_free(channel);

        var rc = c.libssh2_channel_process_startup(channel, null, 0, cmd_c, @as(c.uint, @intCast(std.mem.len(u8, cmd_c))));
        if (rc != 0) return NativeSshError.ExecFailed;

        var exitcode: c_int = undefined;

        var output = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch |err| return err;
        defer output.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.libssh2_channel_read(channel, &buf, buf.len);
            if (n == c.LIBSSH2_ERROR_EAGAIN) continue;
            if (n < 0) return NativeSshError.ReadFailed;
            if (n == 0) break;
            output.appendSlice(self.allocator, buf[0..@as(usize, @intCast(n))]) catch {};
        }

        while (true) {
            const n = c.libssh2_channel_read_stderr(channel, &buf, buf.len);
            if (n == c.LIBSSH2_ERROR_EAGAIN) continue;
            if (n <= 0) break;
        }

        _ = c.libssh2_channel_get_exit_status(channel, &exitcode);
        if (exitcode != 0) return NativeSshError.ExecFailed;

        return output.toOwnedSlice(self.allocator);
    }

    pub fn execCommandWithInput(self: *NativeSshSession, command: []const u8, stdin_data: []const u8) ![]u8 {
        if (!self.authenticated) try self.authenticate();

        const cmd_c = try self.allocator.dupeZ(u8, command);
        defer self.allocator.free(cmd_c);

        const channel = c.libssh2_channel_open_session(self.session.?);
        if (channel == null) return NativeSshError.ChannelOpenFailed;
        defer _ = c.libssh2_channel_close(channel);
        defer c.libssh2_channel_free(channel);

        var rc = c.libssh2_channel_process_startup(channel, null, 0, cmd_c, @as(c.uint, @intCast(std.mem.len(u8, cmd_c))));
        if (rc != 0) return NativeSshError.ExecFailed;

        if (stdin_data.len > 0) {
            var offset: usize = 0;
            while (offset < stdin_data.len) {
                const to_write = @min(stdin_data.len - offset, 4096);
                const written = c.libssh2_channel_write(channel, @constCast(&stdin_data[offset]), @as(c.uint, @intCast(to_write)));
                if (written == c.LIBSSH2_ERROR_EAGAIN) continue;
                if (written < 0) return NativeSshError.WriteFailed;
                offset += @as(usize, @intCast(written));
            }
            _ = c.libssh2_channel_send_eof(channel);
        }

        var exitcode: c_int = undefined;

        var output = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch |err| return err;
        defer output.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.libssh2_channel_read(channel, &buf, buf.len);
            if (n == c.LIBSSH2_ERROR_EAGAIN) continue;
            if (n < 0) return NativeSshError.ReadFailed;
            if (n == 0) break;
            output.appendSlice(self.allocator, buf[0..@as(usize, @intCast(n))]) catch {};
        }

        while (true) {
            const n = c.libssh2_channel_read_stderr(channel, &buf, buf.len);
            if (n == c.LIBSSH2_ERROR_EAGAIN) continue;
            if (n <= 0) break;
        }

        _ = c.libssh2_channel_get_exit_status(channel, &exitcode);
        if (exitcode != 0) return NativeSshError.ExecFailed;

        return output.toOwnedSlice(self.allocator);
    }

    pub fn disconnect(self: *NativeSshSession) void {
        if (self.session) |sess| {
            c.libssh2_session_disconnect(sess, "Normal disconnect");
            c.libssh2_session_free(sess);
            self.session = null;
        }
        if (self.sock >= 0) {
            _ = c.close(self.sock);
            self.sock = -1;
        }
        c.libssh2_exit();
        self.connected = false;
        self.authenticated = false;
    }

    pub fn getFingerprint(self: *NativeSshSession) ?[]const u8 {
        if (self.session == null) return null;
        const fp = c.libssh2_hostkey_hash(self.session.?, c.LIBSSH2_HOSTKEY_HASH_SHA256);
        if (fp == null) return null;
        return fp[0..32];
    }
};

pub const NativeSshTransport = struct {
    allocator: std.mem.Allocator,
    io: Io,
    session: NativeSshTransport,
    host: []const u8,
    port: u16,
    username: ?[]const u8,
    key_path: ?[]const u8,
    password: ?[]const u8,
    connected: bool,

    pub fn init(allocator: std.mem.Allocator, io: Io, host: []const u8) NativeSshTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .session = undefined,
            .host = host,
            .port = 22,
            .username = null,
            .key_path = null,
            .password = null,
            .connected = false,
        };
    }

    pub fn setUsername(self: *NativeSshTransport, username: []const u8) void {
        self.username = username;
    }

    pub fn setPort(self: *NativeSshTransport, port: u16) void {
        self.port = port;
    }

    pub fn setKeyPath(self: *NativeSshTransport, path: []const u8) void {
        self.key_path = path;
    }

    pub fn setPassword(self: *NativeSshTransport, password: []const u8) void {
        self.password = password;
    }

    pub fn connect(self: *NativeSshTransport) !void {
        if (self.connected) return;

        self.session = NativeSshSession.init(self.allocator, self.io, .{
            .host = self.host,
            .port = self.port,
            .username = self.username,
            .password = self.password,
            .key_path = self.key_path,
            .strict_host_key_checking = true,
        });

        try self.session.connect();
        try self.session.authenticate();
        self.connected = true;
    }

    pub fn disconnect(self: *NativeSshTransport) void {
        if (!self.connected) return;
        self.session.deinit();
        self.connected = false;
    }

    pub fn fetchRefs(self: *NativeSshTransport, path: []const u8) ![]const u8 {
        if (!self.connected) try self.connect();

        const remote_cmd = try std.fmt.allocPrint(self.allocator, "git-upload-pack '{s}'", .{path});
        defer self.allocator.free(remote_cmd);

        return self.session.execCommand(remote_cmd);
    }

    pub fn fetchPack(self: *NativeSshTransport, path: []const u8, wants: []const []const u8, haves: []const []const u8) ![]u8 {
        if (!self.connected) try self.connect();

        const remote_cmd = try std.fmt.allocPrint(self.allocator, "git-upload-pack '{s}'", .{path});
        defer self.allocator.free(remote_cmd);

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

        return self.session.execCommandWithInput(remote_cmd, request_data.items);
    }
};
