//! Git Instaweb - Launch web browser for gitweb interface
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const InstawebOptions = struct {
    port: u16 = 1234,
    browser: ?[]const u8 = null,
    restart: bool = false,
    stop: bool = false,
    httpd: []const u8 = "lighttpd",
    local: bool = false,
};

pub const Instaweb = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: InstawebOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Instaweb {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Instaweb, args: []const []const u8) !void {
        if (builtin.os.tag == .windows) {
            try self.output.errorMessage("Instaweb is not supported on Windows", .{});
            return;
        }
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository (or any of the parent directories): .git", .{});
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        if (self.options.stop) {
            try self.stopServer(&git_dir);
        } else if (self.options.restart) {
            try self.stopServer(&git_dir);
            try self.startServer(&git_dir);
        } else {
            try self.startServer(&git_dir);
        }
    }

    fn parseArgs(self: *Instaweb, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if ((std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) and i + 1 < args.len) {
                i += 1;
                self.options.port = std.fmt.parseInt(u16, args[i], 10) catch 1234;
            } else if ((std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--browser")) and i + 1 < args.len) {
                i += 1;
                self.options.browser = args[i];
            } else if (std.mem.eql(u8, arg, "--restart")) {
                self.options.restart = true;
            } else if (std.mem.eql(u8, arg, "--stop") or std.mem.eql(u8, arg, "-s")) {
                self.options.stop = true;
            } else if (std.mem.eql(u8, arg, "--httpd") and i + 1 < args.len) {
                i += 1;
                self.options.httpd = args[i];
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
                self.options.local = true;
            }
        }
    }

    fn startServer(self: *Instaweb, git_dir: *const Io.Dir) !void {
        switch (builtin.os.tag) {
            .windows => return,
            else => {
                const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.options.port});
                defer self.allocator.free(port_str);

                const pid_file_path = try std.fs.path.join(self.allocator, &.{ ".git", ".pid" });
                defer self.allocator.free(pid_file_path);

                const existing_pid = git_dir.readFileAlloc(self.io, pid_file_path, self.allocator, .limited(32)) catch null;
                if (existing_pid) |pid| {
                    defer self.allocator.free(pid);
                    const trimmed = std.mem.trim(u8, pid, " \n\r");
                    if (trimmed.len > 0) {
                        const parsed_pid = std.fmt.parseInt(i32, trimmed, 10) catch 0;
                        if (parsed_pid > 0) {
                            _ = std.posix.kill(parsed_pid, @enumFromInt(@as(c_uint, 0))) catch {};
                        }
                        try self.output.infoMessage("Instaweb already running on port {s} (PID: {s})", .{ port_str, trimmed });
                        try self.launchBrowser(port_str);
                        return;
                    }
                }

                try self.output.section("Starting Git Web Interface");
                try self.output.item("HTTP Server", self.options.httpd);
                try self.output.item("Port", port_str);
                try self.output.item("Root", ".");

                const bind_addr = if (self.options.local) "127.0.0.1" else "0.0.0.0";

                try self.generateGitwebConfig(git_dir, port_str, bind_addr);

                const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{s}/", .{ bind_addr, port_str });
                defer self.allocator.free(url);

                const server_argv = try self.buildHttpdCommand(port_str, bind_addr);

                const child = std.process.spawn(self.io, .{
                    .argv = server_argv,
                    .stdin = .close,
                    .stdout = .close,
                    .stderr = .close,
                }) catch {
                    try self.output.errorMessage("Failed to start HTTP server: {s}", .{self.options.httpd});
                    return;
                };

                const child_pid: i32 = child.id orelse 0;
                const pid_str = try std.fmt.allocPrint(self.allocator, "{d}", .{child_pid});

                git_dir.writeFile(self.io, .{ .sub_path = pid_file_path, .data = pid_str }) catch {
                    try self.output.errorMessage("Failed to write PID file", .{});
                };
                self.allocator.free(pid_str);

                try self.output.successMessage("Git web interface available at: {s}", .{url});

                try self.launchBrowser(port_str);
            },
        }
    }

    fn stopServer(self: *Instaweb, git_dir: *const Io.Dir) !void {
        switch (builtin.os.tag) {
            .windows => {
                try self.output.errorMessage("Instaweb is not supported on Windows", .{});
                return;
            },
            else => {
                const pid_file_path = try std.fs.path.join(self.allocator, &.{ ".git", ".pid" });
                defer self.allocator.free(pid_file_path);

                const pid_content = git_dir.readFileAlloc(self.io, pid_file_path, self.allocator, .limited(32)) catch {
                    try self.output.infoMessage("Instaweb not running", .{});
                    return;
                };
                defer self.allocator.free(pid_content);

                const trimmed = std.mem.trim(u8, pid_content, " \n\r");
                if (trimmed.len == 0) {
                    try self.output.infoMessage("Instaweb not running", .{});
                    return;
                }

                const pid = std.fmt.parseInt(i32, trimmed, 10) catch {
                    try self.output.errorMessage("Invalid PID in pid file", .{});
                    return;
                };

                _ = std.posix.kill(pid, .TERM) catch {
                    _ = std.posix.kill(pid, .KILL) catch {
                        try self.output.errorMessage("Failed to kill process (PID: {d})", .{pid});
                        return;
                    };
                };

                git_dir.deleteFile(self.io, pid_file_path) catch {};

                try self.output.successMessage("Stopped instaweb server (PID: {d})", .{pid});
            },
        }
    }

    fn generateGitwebConfig(self: *Instaweb, git_dir: *const Io.Dir, port: []const u8, bind_addr: []const u8) !void {
        const config_path = try std.fs.path.join(self.allocator, &.{ ".git", "gitweb.conf" });
        defer self.allocator.free(config_path);

        var config_content = try std.ArrayList(u8).initCapacity(self.allocator, 512);
        defer config_content.deinit(self.allocator);

        try config_content.appendSlice(self.allocator, "# Gitweb configuration for hoz instaweb\n");
        try config_content.appendSlice(self.allocator, "$projectroot = '.';\n");
        try config_content.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "$my_uri = \"http://{s}:{s}\";\n", .{ bind_addr, port }));
        try config_content.appendSlice(self.allocator, "@stylesheets = ('static/gitweb.css');\n");
        try config_content.appendSlice(self.allocator, "$logo = 'static/git-logo.png';\n");
        try config_content.appendSlice(self.allocator, "$favicon = 'static/git-favicon.png';\n");
        try config_content.appendSlice(self.allocator, "$feature{'blame'}{'default'} = [1];\n");
        try config_content.appendSlice(self.allocator, "$feature{'pickaxe'}{'default'} = [1];\n");
        try config_content.appendSlice(self.allocator, "$feature{'snapshot'}{'default'} = ['zip', 'tgz'];\n");
        try config_content.appendSlice(self.allocator, "$prevent_xss = true;\n");

        git_dir.writeFile(self.io, .{ .sub_path = "gitweb.conf", .data = config_content.items }) catch {
            try self.output.errorMessage("Failed to write gitweb configuration", .{});
            return;
        };
    }

    fn launchBrowser(self: *Instaweb, port: []const u8) !void {
        const browser_cmd = self.options.browser orelse detectBrowser();

        const bind_addr = if (self.options.local) "127.0.0.1" else "localhost";
        const url = try std.fmt.allocPrint(self.allocator, "http://{s}:{s}/", .{ bind_addr, port });
        defer self.allocator.free(url);

        try self.output.infoMessage("Launching browser: {s}", .{browser_cmd});

        const browser_child = std.process.spawn(self.io, .{
            .argv = &.{ browser_cmd, url },
            .stdin = .close,
            .stdout = .close,
            .stderr = .close,
        }) catch {
            try self.output.infoMessage("Could not launch browser '{s}'. Open manually: {s}", .{ browser_cmd, url });
            return;
        };

        _ = browser_child;

        try self.output.infoMessage("Opening URL: {s}", .{url});
    }

    fn buildHttpdCommand(self: *Instaweb, port: []const u8, bind_addr: []const u8) ![]const []const u8 {
        const httpd = self.options.httpd;

        if (std.mem.eql(u8, httpd, "lighttpd") or std.mem.eql(u8, httpd, "apache2") or std.mem.eql(u8, httpd, "httpd")) {
            const conf_path = try std.fs.path.join(self.allocator, &.{ ".git", "gitweb.conf" });
            return &[_][]const u8{ httpd, "-D", "-f", conf_path };
        }

        if (std.mem.eql(u8, httpd, "python") or std.mem.eql(u8, httpd, "python3")) {
            return &[_][]const u8{ "python3", "-m", "http.server", port, "--bind", bind_addr };
        }

        if (std.mem.eql(u8, httpd, "busybox")) {
            return &[_][]const u8{ "busybox", "httpd", "-f", "-p", port };
        }

        return &[_][]const u8{ "python3", "-m", "http.server", port, "--bind", bind_addr };
    }

    fn detectBrowser() []const u8 {
        const browser_env = std.c.getenv("BROWSER");
        if (browser_env != null) {
            const ptr = @constCast(browser_env.?);
            const len = std.mem.len(ptr);
            return ptr[0..len];
        }

        const display = std.c.getenv("DISPLAY");
        if (display == null) {
            return "lynx";
        }

        return "open";
    }
};
