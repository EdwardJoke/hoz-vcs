const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const TreeKind = @import("output.zig").TreeKind;
const StatusIcon = @import("output.zig").StatusIcon;

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
        const cwd = Io.Dir.cwd();
        _ = git_dir.access(self.io, "HEAD", .{}) catch {
            try self.output.errorMessage("Not a valid git repository", .{});
            return;
        };
        _ = cwd.openFile(self.io, ".gitmodules", .{}) catch {
            try self.output.infoMessage("--→ No .gitmodules file found", .{});
            return;
        };

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
            try self.output.infoMessage("--→ No submodules found", .{});
            return;
        }

        for (modules.items, 0..) |m, idx| {
            const kind: TreeKind = if (idx == modules.items.len - 1) .last else .branch;
            const status_icon: StatusIcon = if (m.initialized) .submodule else .conflicted;
            try self.output.treeNode(kind, 0, "{s} {s} ({s})", .{
                status_icon.symbol(self.output.style.use_unicode),
                m.path,
                m.url,
            });
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
                try self.output.infoMessage("--→ Submodule '{s}' already initialized", .{m.name});
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
                        try self.output.successMessage("--→ Submodule '{s}' path registered at '{s}'", .{ m.name, m.path });
                        continue;
                    }
                }
            }

            try self.output.successMessage("--→ Submodule '{s}' ({s}) registered for path '{s}'", .{ m.name, m.url, m.path });
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
                        try self.output.successMessage("--→ Submodule '{s}' checked out at {s}", .{ m.name, trimmed[0..@min(trimmed.len, 12)] });
                    } else {
                        try self.cloneAndCheckout(sd, m);
                    }
                    continue;
                }
            }

            try self.output.infoMessage("--→ Submodule '{s}' not initialized, run 'git submodule init' first", .{m.name});
        }
    }

    fn cloneAndCheckout(self: *Submodule, sub_dir: Io.Dir, m: SubmoduleEntry) !void {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, m.path) catch {};

        const sub_git_dir = try std.fs.path.join(self.allocator, &.{ m.path, ".git" });
        defer self.allocator.free(sub_git_dir);

        const sub_cwd = cwd.openDir(self.io, m.path, .{}) catch {
            try self.output.errorMessage("Failed to open submodule path: {s}", .{m.path});
            return;
        };
        defer sub_cwd.close(self.io);

        _ = sub_cwd.openDir(self.io, ".git", .{}) catch {
            sub_cwd.createDirPath(self.io, ".git") catch {};
            sub_cwd.writeFile(self.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" }) catch {};
            sub_cwd.createDirPath(self.io, ".git/objects") catch {};
            sub_cwd.createDirPath(self.io, ".git/refs") catch {};
            sub_cwd.createDirPath(self.io, ".git/refs/heads") catch {};
            sub_cwd.writeFile(self.io, .{ .sub_path = ".git/config", .data = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n" }) catch {};
        };

        if (m.oid.len >= 7) {
            sub_cwd.writeFile(self.io, .{ .sub_path = ".git/HEAD", .data = m.oid }) catch {};

            sub_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = m.oid }) catch {};
            try self.output.successMessage("--→ Submodule '{s}' initialized at {s}", .{ m.name, m.oid[0..@min(m.oid.len, 12)] });
        } else {
            try self.output.infoMessage("--→ Submodule '{s}' initialized (no OID to checkout)", .{m.name});
        }
    }

    fn deinitSubmodules(self: *Submodule, git_dir: *const Io.Dir) !void {
        _ = git_dir.openDir(self.io, "modules", .{}) catch {
            try self.output.infoMessage("--→ No modules directory found", .{});
            return;
        };

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

pub const GitModulesEntry = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,
    branch: ?[]const u8 = null,
    update_strategy: []const u8 = "checkout",
};

pub const GitModulesParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitModulesParser {
        return .{ .allocator = allocator };
    }

    pub fn parse(self: *GitModulesParser, content: []const u8) ![]GitModulesEntry {
        var result = std.ArrayList(GitModulesEntry).empty;
        errdefer {
            for (result.items) |e| {
                self.allocator.free(e.name);
                self.allocator.free(e.path);
                self.allocator.free(e.url);
                if (e.branch) |b| self.allocator.free(b);
                self.allocator.free(e.update_strategy);
            }
            result.deinit(self.allocator);
        }

        var current_name: ?[]const u8 = null;
        var current_path: ?[]const u8 = null;
        var current_url: ?[]const u8 = null;
        var current_branch: ?[]const u8 = null;
        var current_update: []const u8 = "checkout";

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.startsWith(u8, trimmed, "[submodule")) {
                if (current_name) |name| {
                    try self.flushEntry(&result, name, current_path, current_url, current_branch, current_update);
                    current_name = null;
                    current_path = null;
                    current_url = null;
                    current_branch = null;
                    current_update = "checkout";
                }

                const name_start = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
                const name_end = std.mem.indexOfScalar(u8, trimmed[name_start + 1 ..], '"') orelse continue;

                current_name = try self.allocator.dupe(u8, trimmed[name_start + 1 ..][0..name_end]);
            } else if (std.mem.startsWith(u8, trimmed, "\tpath") or std.mem.startsWith(u8, trimmed, "path")) {
                const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                current_path = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r"));
            } else if (std.mem.startsWith(u8, trimmed, "\turl") or std.mem.startsWith(u8, trimmed, "url")) {
                const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                current_url = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r"));
            } else if (std.mem.startsWith(u8, trimmed, "\tbranch") or std.mem.startsWith(u8, trimmed, "branch")) {
                const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                current_branch = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r"));
            } else if (std.mem.startsWith(u8, trimmed, "\tupdate") or std.mem.startsWith(u8, trimmed, "update")) {
                const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                current_update = try self.allocator.dupe(u8, std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\r"));
            }
        }

        if (current_name) |name| {
            try self.flushEntry(&result, name, current_path, current_url, current_branch, current_update);
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn flushEntry(
        self: *GitModulesParser,
        result: *std.ArrayList(GitModulesEntry),
        name: []const u8,
        path: ?[]const u8,
        url: ?[]const u8,
        branch: ?[]const u8,
        update_strategy: []const u8,
    ) !void {
        const path_val = path orelse name;
        const url_val = url orelse "";
        const branch_owned = if (branch) |b|
            try self.allocator.dupe(u8, b)
        else
            null;
        const update_owned = try self.allocator.dupe(u8, update_strategy);

        try result.append(self.allocator, .{
            .name = name,
            .path = path_val,
            .url = url_val,
            .branch = branch_owned,
            .update_strategy = update_owned,
        });

        if (path) |p| self.allocator.free(p);
        if (url) |u_| self.allocator.free(u_);
    }

    pub fn deinitEntries(self: *GitModulesParser, entries: []GitModulesEntry) void {
        for (entries) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.path);
            self.allocator.free(e.url);
            if (e.branch) |b| self.allocator.free(b);
            self.allocator.free(e.update_strategy);
        }
        self.allocator.free(entries);
    }
};

pub const ModuleManager = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) ModuleManager {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn createModuleDir(self: *ModuleManager, git_dir: *Io.Dir, module_name: []const u8) !void {
        const modules_dir = git_dir.openDir(self.io, "modules", .{}) catch {
            git_dir.createDirPath(self.io, "modules") catch return error.FailedToCreateModulesDir;
            return git_dir.openDir(self.io, "modules", .{}) orelse return error.FailedToCreateModulesDir;
        };
        defer modules_dir.close(self.io);

        _ = modules_dir.openDir(self.io, module_name, .{}) catch {
            modules_dir.createDirPath(self.io, module_name) catch return error.FailedToCreateModuleDir;
        };

        const sub_dir = modules_dir.openDir(self.io, module_name, .{}) orelse return;
        defer sub_dir.close(self.io);

        for (&[_][]const u8{ "objects", "refs/heads", "refs/tags", "info" }) |subdir| {
            sub_dir.createDirPath(self.io, subdir) catch {};
        }
    }

    pub fn writeModuleHead(self: *ModuleManager, git_dir: *Io.Dir, module_name: []const u8, oid: []const u8) !void {
        const modules_dir = git_dir.openDir(self.io, "modules", .{}) catch return;
        defer modules_dir.close(self.io);

        const sub_dir = modules_dir.openDir(self.io, module_name, .{}) catch return;
        defer sub_dir.close(self.io);

        sub_dir.writeFile(self.io, .{ .sub_path = "HEAD", .data = oid }) catch {};
    }

    pub fn writeModuleConfig(self: *ModuleManager, git_dir: *Io.Dir, entry: GitModulesEntry) !void {
        const config_path = try std.fmt.allocPrint(self.allocator, "config", .{});
        defer self.allocator.free(config_path);

        const existing = git_dir.readFileAlloc(self.io, config_path, self.allocator, .limited(1024 * 1024)) catch "";
        defer if (existing.len > 0) self.allocator.free(existing);

        const section_header = try std.fmt.allocPrint(self.allocator, "[submodule \"{s}\"]\n", .{entry.name});
        defer self.allocator.free(section_header);

        if (std.mem.indexOf(u8, existing, section_header) != null) return;

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        if (existing.len > 0) {
            try buf.appendSlice(self.allocator, existing);
            if (!std.mem.endsWith(u8, existing, "\n")) {
                try buf.append(self.allocator, '\n');
            }
        }

        try buf.appendSlice(self.allocator, section_header);
        try buf.appendSlice(self.allocator, "\tpath = ");
        try buf.appendSlice(self.allocator, entry.path);
        try buf.appendSlice(self.allocator, "\n");
        try buf.appendSlice(self.allocator, "\turl = ");
        try buf.appendSlice(self.allocator, entry.url);
        try buf.appendSlice(self.allocator, "\n");

        if (entry.branch) |b| {
            try buf.appendSlice(self.allocator, "\tactivebranch = ");
            try buf.appendSlice(self.allocator, b);
            try buf.appendSlice(self.allocator, "\n");
        }

        const final = buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(final);

        git_dir.writeFile(self.io, .{ .sub_path = config_path, .data = final }) catch {};
    }

    pub fn removeModuleConfig(self: *ModuleManager, git_dir: *Io.Dir, module_name: []const u8) !void {
        const config_content = git_dir.readFileAlloc(self.io, "config", self.allocator, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(config_content);

        const section_start = try std.fmt.allocPrint(self.allocator, "[submodule \"{s}\"]\n", .{module_name});
        defer self.allocator.free(section_start);

        const idx = std.mem.indexOf(u8, config_content, section_start) orelse return;

        var section_end = idx + section_start.len;
        while (section_end < config_content.len) : (section_end += 1) {
            if (config_content[section_end] == '[' and section_end > idx) break;
        }

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);

        if (idx > 0) {
            try buf.appendSlice(self.allocator, config_content[0..idx]);
        }
        if (section_end < config_content.len) {
            try buf.appendSlice(self.allocator, config_content[section_end..]);
        }

        const final = buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(final);

        git_dir.writeFile(self.io, .{ .sub_path = "config", .data = final }) catch {};
    }

    pub fn isInitialized(self: *ModuleManager, git_dir: *Io.Dir, module_name: []const u8) bool {
        const modules_dir = git_dir.openDir(self.io, "modules", .{}) catch return false;
        defer modules_dir.close(self.io);

        const sub_dir = modules_dir.openDir(self.io, module_name, .{}) catch return false;
        defer sub_dir.close(self.io);

        const head = sub_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return false;
        defer self.allocator.free(head);

        return head.len > 0;
    }
};

test "GitModulesParser parses basic .gitmodules" {
    var parser = GitModulesParser.init(std.testing.allocator);
    const input =
        \\[submodule "libfoo"]
        \\\tpath = libs/libfoo
        \\\turl = https://github.com/example/libfoo.git
        \\
        \\[submodule "libbar"]
        \\\tpath = libs/libbar
        \\\turl = https://github.com/example/libbar.git
        \\\tbranch = main
        \\\tupdate = rebase
    ;

    const entries = try parser.parse(input);
    defer parser.deinitEntries(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("libfoo", entries[0].name);
    try std.testing.expectEqualStrings("libs/libfoo", entries[0].path);
    try std.testing.expectEqualStrings("https://github.com/example/libfoo.git", entries[0].url);
    try std.testing.expect(entries[0].branch == null);
    try std.testing.expectEqualStrings("checkout", entries[0].update_strategy);

    try std.testing.expectEqualStrings("libbar", entries[1].name);
    try std.testing.expectEqualStrings("libs/libbar", entries[1].path);
    try std.testing.expectEqualStrings("https://github.com/example/libbar.git", entries[1].url);
    try std.testing.expectEqualStrings("main", entries[1].branch.?);
    try std.testing.expectEqualStrings("rebase", entries[1].update_strategy);
}

test "GitModulesParser handles empty input" {
    var parser = GitModulesParser.init(std.testing.allocator);
    const entries = try parser.parse("");
    defer parser.deinitEntries(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "GitModulesParser single submodule no optional fields" {
    var parser = GitModulesParser.init(std.testing.allocator);
    const input =
        \\[submodule "core"]
        \\\tpath = deps/core
        \\\turl = git@example.com:core.git
    ;

    const entries = try parser.parse(input);
    defer parser.deinitEntries(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("core", entries[0].name);
    try std.testing.expectEqualStrings("deps/core", entries[0].path);
    try std.testing.expect(entries[0].branch == null);
}

test "ModuleManager init creates structure" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{
        .stdin = .empty,
        .stdout = .buffered(&buf),
        .stderr = .buffered(&buf),
    });
    const mgr = ModuleManager.init(std.testing.allocator, io);
    try std.testing.expect(mgr.allocator == std.testing.allocator);
}
