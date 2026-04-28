const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const SubmoduleOptions = struct {
    init: bool = false,
    update: bool = false,
    deinit: bool = false,
    recursive: bool = false,
    remote: bool = false,
    force: bool = false,
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    depth: ?u32 = null,
};

pub const SubmoduleEntry = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,
    oid: []const u8,
    initialized: bool,
};

pub const Submodule = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: SubmoduleOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Submodule {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Submodule, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        if (self.options.init) {
            try self.initSubmodules(&git_dir);
        } else if (self.options.update) {
            try self.updateSubmodules(&git_dir);
        } else if (self.options.deinit) {
            try self.deinitSubmodules(&git_dir);
        } else {
            try self.listSubmodules(&git_dir);
        }
    }

    fn listSubmodules(self: *Submodule, git_dir: *const Io.Dir) !void {
        _ = git_dir;
        var modules = try self.parseGitmodules();
        defer {
            for (modules.items) |m| {
                self.allocator.free(m.name);
                self.allocator.free(m.path);
                self.allocator.free(m.url);
                self.allocator.free(m.oid);
            }
            modules.deinit(self.allocator);
        }

        if (modules.items.len == 0) {
            try self.output.infoMessage("No submodules found", .{});
            return;
        }

        for (modules.items) |m| {
            const status_prefix: []const u8 = if (m.initialized) " " else "-";
            try self.output.writer.print("{s} {s} ({s})\n", .{ status_prefix, m.path, m.url });
        }
    }

    fn initSubmodules(self: *Submodule, git_dir: *const Io.Dir) !void {
        var modules = try self.parseGitmodules();
        defer {
            for (modules.items) |m| {
                self.allocator.free(m.name);
                self.allocator.free(m.path);
                self.allocator.free(m.url);
                self.allocator.free(m.oid);
            }
            modules.deinit(self.allocator);
        }

        for (modules.items) |m| {
            if (self.options.path) |p| {
                if (!std.mem.eql(u8, p, m.path) and !std.mem.eql(u8, p, m.name)) continue;
            }

            const config_path = "config";
            const config_content = git_dir.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch {
                try self.output.errorMessage("Failed to read git config", .{});
                continue;
            };
            defer self.allocator.free(config_content);

            const section_header = try std.fmt.allocPrint(self.allocator, "[submodule \"{s}\"]", .{m.name});
            defer self.allocator.free(section_header);

            if (std.mem.indexOf(u8, config_content, section_header) != null) {
                try self.output.infoMessage("Submodule '{s}' already initialized", .{m.name});
                continue;
            }

            const sub_path = try std.fmt.allocPrint(self.allocator, "modules/{s}/HEAD", .{m.name});
            defer self.allocator.free(sub_path);

            const modules_dir = git_dir.openDir(self.io, "modules", .{}) catch null;
            if (modules_dir) |md| {
                defer md.close(self.io);
                const sub_dir = md.openDir(self.io, m.name, .{}) catch null;
                if (sub_dir) |sd| {
                    defer sd.close(self.io);
                    const head_content = sd.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch "";
                    defer if (head_content.len > 0) self.allocator.free(head_content);
                    if (head_content.len > 0) {
                        try self.output.successMessage("Submodule '{s}' path registered at '{s}'", .{ m.name, m.path });
                        continue;
                    }
                }
            }

            try self.output.successMessage("Submodule '{s}' ({s}) registered for path '{s}'", .{ m.name, m.url, m.path });
        }
    }

    fn updateSubmodules(self: *Submodule, git_dir: *const Io.Dir) !void {
        var modules = try self.parseGitmodules();
        defer {
            for (modules.items) |m| {
                self.allocator.free(m.name);
                self.allocator.free(m.path);
                self.allocator.free(m.url);
                self.allocator.free(m.oid);
            }
            modules.deinit(self.allocator);
        }

        for (modules.items) |m| {
            if (self.options.path) |p| {
                if (!std.mem.eql(u8, p, m.path) and !std.mem.eql(u8, p, m.name)) continue;
            }

            const sub_path = try std.fmt.allocPrint(self.allocator, "modules/{s}", .{m.name});
            defer self.allocator.free(sub_path);

            const modules_dir = git_dir.openDir(self.io, "modules", .{}) catch null;
            if (modules_dir) |md| {
                defer md.close(self.io);
                const sub_dir = md.openDir(self.io, m.name, .{}) catch null;
                if (sub_dir) |sd| {
                    defer sd.close(self.io);
                    const head_content = sd.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch "";
                    defer if (head_content.len > 0) self.allocator.free(head_content);
                    const trimmed = if (head_content.len > 0) std.mem.trim(u8, head_content, " \n\r") else "";

                    if (trimmed.len > 0) {
                        try self.output.successMessage("Submodule '{s}' checked out at {s}", .{ m.name, trimmed[0..@min(trimmed.len, 12)] });
                    } else {
                        try self.cloneAndCheckout(sd, m);
                    }
                    continue;
                }
            }

            try self.output.infoMessage("Submodule '{s}' not initialized, run 'git submodule init' first", .{m.name});
        }
    }

    fn cloneAndCheckout(self: *Submodule, sub_dir: Io.Dir, m: SubmoduleEntry) !void {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, m.path) catch {};

        var clone_argv = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer clone_argv.deinit(self.allocator);
        try clone_argv.appendSlice(self.allocator, &.{ "git", "clone", "--no-checkout", m.url, m.path });
        _ = std.process.spawn(self.io, .{ .argv = clone_argv.items }) catch {
            try self.output.errorMessage("Failed to clone submodule '{s}' from {s}", .{ m.name, m.url });
            return;
        };

        if (m.oid.len >= 7) {
            var checkout_argv = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
            defer checkout_argv.deinit(self.allocator);
            try checkout_argv.appendSlice(self.allocator, &.{ "git", "-C", m.path, "checkout", m.oid[0..@min(m.oid.len, 40)] });
            _ = std.process.spawn(self.io, .{ .argv = checkout_argv.items }) catch {
                try self.output.infoMessage("Submodule '{s}' cloned but checkout of {s} failed", .{ m.name, m.oid[0..@min(m.oid.len, 12)] });
                return;
            };

            sub_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = m.oid }) catch {};
            try self.output.successMessage("Submodule '{s}' checked out at {s}", .{ m.name, m.oid[0..@min(m.oid.len, 12)] });
        }
    }

    fn deinitSubmodules(self: *Submodule, git_dir: *const Io.Dir) !void {
        var modules = try self.parseGitmodules();
        defer {
            for (modules.items) |m| {
                self.allocator.free(m.name);
                self.allocator.free(m.path);
                self.allocator.free(m.url);
                self.allocator.free(m.oid);
            }
            modules.deinit(self.allocator);
        }

        for (modules.items) |m| {
            if (self.options.path) |p| {
                if (!std.mem.eql(u8, p, m.path) and !std.mem.eql(u8, p, m.name)) continue;
            }

            const sub_path = try std.fmt.allocPrint(self.allocator, "modules/{s}", .{m.name});
            defer self.allocator.free(sub_path);

            if (self.options.force) {
                const cwd = Io.Dir.cwd();
                cwd.deleteFile(self.io, m.path) catch {};
            }

            try self.output.successMessage("Submodule '{s}' ({s}) deinitialized", .{ m.name, m.path });
        }

        _ = git_dir;
    }

    fn parseGitmodules(self: *Submodule) !std.ArrayList(SubmoduleEntry) {
        var result = std.ArrayList(SubmoduleEntry).empty;

        const cwd = Io.Dir.cwd();
        const content = cwd.readFileAlloc(self.io, ".gitmodules", self.allocator, .limited(1024 * 1024)) catch {
            return result;
        };
        defer self.allocator.free(content);

        var current_name: ?[]const u8 = null;
        var current_path: ?[]const u8 = null;
        var current_url: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.startsWith(u8, trimmed, "[submodule")) {
                if (current_name) |name| {
                    const path = current_path orelse name;
                    const url = current_url orelse "";
                    const oid = try self.resolveSubmoduleOid(path);
                    const is_init = oid.len > 0;
                    try result.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, name),
                        .path = try self.allocator.dupe(u8, path),
                        .url = try self.allocator.dupe(u8, url),
                        .oid = oid,
                        .initialized = is_init,
                    });
                    self.allocator.free(name);
                    if (current_path) |p| self.allocator.free(p);
                    if (current_url) |u| self.allocator.free(u);
                }

                const name_start = std.mem.indexOfScalar(u8, trimmed, '"') orelse trimmed.len;
                const name_end = if (name_start < trimmed.len)
                    std.mem.indexOfScalar(u8, trimmed[name_start + 1 ..], '"') orelse trimmed.len - name_start - 1
                else
                    0;

                if (name_start < trimmed.len and name_end > 0) {
                    current_name = try self.allocator.dupe(u8, trimmed[name_start + 1 ..][0..name_end]);
                } else {
                    current_name = null;
                }
                current_path = null;
                current_url = null;
            } else if (std.mem.startsWith(u8, trimmed, "path = ")) {
                current_path = try self.allocator.dupe(u8, trimmed[7..]);
            } else if (std.mem.startsWith(u8, trimmed, "url = ")) {
                current_url = try self.allocator.dupe(u8, trimmed[6..]);
            }
        }

        if (current_name) |name| {
            const path = current_path orelse name;
            const url = current_url orelse "";
            const oid = try self.resolveSubmoduleOid(path);
            const is_init = oid.len > 0;
            try result.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .path = try self.allocator.dupe(u8, path),
                .url = try self.allocator.dupe(u8, url),
                .oid = oid,
                .initialized = is_init,
            });
            self.allocator.free(name);
            if (current_path) |p| self.allocator.free(p);
            if (current_url) |u| self.allocator.free(u);
        }

        return result;
    }

    fn resolveSubmoduleOid(self: *Submodule, path: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();
        const sub_git = try std.fmt.allocPrint(self.allocator, "{s}/.git/HEAD", .{path});
        defer self.allocator.free(sub_git);

        const head = cwd.readFileAlloc(self.io, sub_git, self.allocator, .limited(256)) catch {
            return try self.allocator.dupe(u8, "");
        };
        defer self.allocator.free(head);

        const trimmed = std.mem.trim(u8, head, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            const full_ref = try std.fmt.allocPrint(self.allocator, "{s}/.git/{s}", .{ path, ref_path });
            defer self.allocator.free(full_ref);
            const ref_content = cwd.readFileAlloc(self.io, full_ref, self.allocator, .limited(256)) catch {
                return try self.allocator.dupe(u8, "");
            };
            defer self.allocator.free(ref_content);
            const ref_trimmed = std.mem.trim(u8, ref_content, " \n\r");
            if (ref_trimmed.len >= 40) {
                return try self.allocator.dupe(u8, ref_trimmed[0..40]);
            }
            return try self.allocator.dupe(u8, ref_trimmed);
        }

        if (trimmed.len >= 40) {
            return try self.allocator.dupe(u8, trimmed[0..40]);
        }
        return try self.allocator.dupe(u8, trimmed);
    }

    fn parseArgs(self: *Submodule, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "init")) {
                self.options.init = true;
            } else if (std.mem.eql(u8, arg, "update")) {
                self.options.update = true;
            } else if (std.mem.eql(u8, arg, "deinit")) {
                self.options.deinit = true;
            } else if (std.mem.eql(u8, arg, "--recursive")) {
                self.options.recursive = true;
            } else if (std.mem.eql(u8, arg, "--remote")) {
                self.options.remote = true;
            } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                self.options.force = true;
            } else if (std.mem.startsWith(u8, arg, "--path=")) {
                self.options.path = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--name=")) {
                self.options.name = arg[7..];
            } else if (std.mem.startsWith(u8, arg, "--branch=")) {
                self.options.branch = arg[9..];
            } else if (std.mem.startsWith(u8, arg, "--depth=")) {
                self.options.depth = std.fmt.parseInt(u32, arg[8..], 10) catch null;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.options.path == null) {
                    self.options.path = arg;
                }
            }
        }
    }
};
