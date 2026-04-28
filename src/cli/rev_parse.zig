const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const RevParseOptions = struct {
    verify: bool = false,
    quiet: bool = false,
    short: ?u8 = null,
    abbrev_ref: bool = false,
    abbrev_ref_strict: bool = false,
    show_toplevel: bool = false,
    show_prefix: bool = false,
    git_dir: bool = false,
    git_common_dir: bool = false,
    resolve_git_dir: bool = false,
    is_inside_work_tree: bool = false,
    is_inside_git_dir: bool = false,
    is_bare_repository: bool = false,
    is_shallow_repository: bool = false,
    symbolic_full_name: bool = false,
    exclude_patterns: bool = false,
    default: ?[]const u8 = null,
    flags: []const []const u8 = &.{},
};

pub const RevParse = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: RevParseOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) RevParse {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *RevParse, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.options.show_toplevel) {
            try self.showTopLevel();
            return;
        }
        if (self.options.show_prefix) {
            try self.showPrefix();
            return;
        }
        if (self.options.git_dir) {
            try self.showGitDir();
            return;
        }
        if (self.options.is_inside_work_tree) {
            try self.output.writer.print("{s}\n", .{if (self.insideWorkTree()) "true" else "false"});
            return;
        }
        if (self.options.is_inside_git_dir) {
            try self.output.writer.print("{s}\n", .{if (self.insideGitDir()) "true" else "false"});
            return;
        }
        if (self.options.is_bare_repository) {
            try self.output.writer.print("{s}\n", .{if (self.isBareRepo()) "true" else "false"});
            return;
        }
        if (self.options.is_shallow_repository) {
            try self.checkShallowRepo();
            return;
        }

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            const resolved = try self.resolveRef(arg);
            if (resolved.len > 0) {
                if (self.options.symbolic_full_name) {
                    const sym = try self.resolveSymbolicName(arg);
                    try self.output.writer.print("{s}\n", .{sym});
                } else if (self.options.abbrev_ref or self.options.abbrev_ref_strict) {
                    const abbrev = try self.abbrevRef(resolved);
                    try self.output.writer.print("{s}\n", .{abbrev});
                } else if (self.options.short) |len| {
                    try self.output.writer.print("{s}\n", .{resolved[0..@min(len, resolved.len)]});
                } else {
                    try self.output.writer.print("{s}\n", .{resolved});
                }
            }
        }

        if (args.len == 0) {
            if (self.options.default) |def| {
                const resolved = try self.resolveRef(def);
                if (resolved.len > 0) {
                    try self.output.writer.print("{s}\n", .{resolved});
                }
            }
        }
    }

    fn resolveRef(self: *RevParse, refspec: []const u8) ![]const u8 {
        const cwd = Io.Dir.cwd();

        if (std.mem.eql(u8, refspec, "HEAD")) {
            const head_content = cwd.readFileAlloc(self.io, ".git/HEAD", self.allocator, .limited(256)) catch return "";
            defer self.allocator.free(head_content);

            const trimmed = std.mem.trim(u8, head_content, " \n\r");

            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                const full_path = try std.fmt.allocPrint(self.allocator, ".git/{s}", .{ref_path});
                defer self.allocator.free(full_path);

                const content = cwd.readFileAlloc(self.io, full_path, self.allocator, .limited(256)) catch return "";
                defer self.allocator.free(content);
                return try self.allocator.dupe(u8, std.mem.trim(u8, content, " \n\r"));
            }

            if (trimmed.len >= 40) {
                return try self.allocator.dupe(u8, trimmed[0..40]);
            }
            return "";
        }

        if (std.ascii.isHex(refspec[0]) and refspec.len >= 4) {
            var result = std.ArrayList([]const u8).empty;

            const objects_dir = cwd.openDir(self.io, ".git/objects", .{}) catch return "";
            defer objects_dir.close(self.io);

            const prefix = refspec[0..2];
            const suffix = refspec[2..];

            const sub_dir = objects_dir.openDir(self.io, prefix, .{}) catch return "";
            defer sub_dir.close(self.io);

            var iter = sub_dir.iterate();
            while (iter.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.startsWith(u8, entry.name, suffix)) {
                    const oid = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, entry.name });
                    result.append(self.allocator, oid) catch break;
                }
            }

            if (result.items.len == 1) {
                const val = result.items[0];
                return val;
            }
            if (result.items.len > 1) {
                for (result.items) |oid| self.allocator.free(oid);
                result.deinit(self.allocator);
                return try self.allocator.dupe(u8, "ambiguous");
            }
            return "";
        }

        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/{s}", .{refspec});
        defer self.allocator.free(ref_path);

        const content = cwd.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch {
            const packed_refs = cwd.readFileAlloc(self.io, ".git/packed-refs", self.allocator, .limited(64 * 1024)) catch return "";
            defer self.allocator.free(packed_refs);

            var lines = std.mem.splitScalar(u8, packed_refs, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len < 42) continue;
                if (std.mem.eql(u8, trimmed[41..], refspec)) {
                    return try self.allocator.dupe(u8, trimmed[0..40]);
                }
            }
            return "";
        };
        defer self.allocator.free(content);

        const trimmed = std.mem.trim(u8, content, " \n\r");
        if (trimmed.len >= 40) {
            return try self.allocator.dupe(u8, trimmed[0..40]);
        }
        return try self.allocator.dupe(u8, trimmed);
    }

    fn resolveSymbolicName(self: *RevParse, refspec: []const u8) ![]const u8 {
        if (std.mem.eql(u8, refspec, "HEAD")) {
            const head_content = Io.Dir.cwd().readFileAlloc(self.io, ".git/HEAD", self.allocator, .limited(256)) catch return try self.allocator.dupe(u8, "HEAD");
            defer self.allocator.free(head_content);
            const trimmed = std.mem.trim(u8, head_content, " \n\r");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                return try self.allocator.dupe(u8, trimmed[5..]);
            }
            return try self.allocator.dupe(u8, "HEAD");
        }

        if (std.mem.indexOf(u8, refspec, "/") != null) {
            return try self.allocator.dupe(u8, refspec);
        }

        const candidates = &[_][]const u8{
            "refs/heads/",
            "refs/tags/",
            "refs/remotes/",
        };

        for (candidates) |prefix| {
            const full = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, refspec });
            defer self.allocator.free(full);
            const path = try std.fmt.allocPrint(self.allocator, ".git/{s}", .{full});
            defer self.allocator.free(path);

            if (Io.Dir.cwd().openFile(self.io, path, .{})) |file| {
                file.close(self.io);
                return try self.allocator.dupe(u8, full);
            } else |_| {}
        }

        return try self.allocator.dupe(u8, refspec);
    }

    fn abbrevRef(self: *RevParse, oid: []const u8) ![]const u8 {
        const sym = try self.resolveSymbolicName(oid);
        defer self.allocator.free(sym);

        if (std.mem.startsWith(u8, sym, "refs/heads/")) {
            return try self.allocator.dupe(u8, sym[11..]);
        }
        if (std.mem.startsWith(u8, sym, "refs/remotes/")) {
            return try self.allocator.dupe(u8, sym[13..]);
        }
        if (std.mem.startsWith(u8, sym, "refs/tags/")) {
            return try self.allocator.dupe(u8, sym[10..]);
        }
        return try self.allocator.dupe(u8, sym);
    }

    fn showTopLevel(self: *RevParse) !void {
        const cwd = Io.Dir.cwd();
        var buf: [4096]u8 = undefined;
        const len = std.process.currentPath(self.io, &buf) catch return;
        const current = buf[0..len];

        var i: usize = current.len;
        while (i > 0) : (i -= 1) {
            const test_path = current[0..i];
            const git_check = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{test_path});
            defer self.allocator.free(git_check);

            if (cwd.openDir(self.io, git_check, .{})) |dir| {
                dir.close(self.io);
                try self.output.writer.print("{s}\n", .{test_path});
                return;
            } else |_| {}
        }

        if (!self.options.quiet) {
            try self.output.errorMessage("Not a git repository", .{});
        }
    }

    fn showPrefix(self: *RevParse) !void {
        var buf: [4096]u8 = undefined;
        const len = std.process.currentPath(self.io, &buf) catch return;
        const current = buf[0..len];

        var toplevel_buf: [4096]u8 = undefined;
        const toplevel = self.findGitRoot(&toplevel_buf) orelse {
            if (!self.options.quiet) {
                try self.output.errorMessage("Not a git repository", .{});
            }
            return;
        };

        if (current.len > toplevel.len + 1) {
            try self.output.writer.print("{s}\n", .{current[toplevel.len + 1 ..]});
        }
    }

    fn showGitDir(self: *RevParse) !void {
        const cwd = Io.Dir.cwd();
        const git_link = cwd.readFileAlloc(self.io, ".git", self.allocator, .limited(512)) catch {
            try self.output.writer.print(".git\n", .{});
            return;
        };
        defer self.allocator.free(git_link);
        const trimmed = std.mem.trim(u8, git_link, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
            try self.output.writer.print("{s}\n", .{trimmed[8..]});
        } else {
            try self.output.writer.print(".git\n", .{});
        }
    }

    fn checkShallowRepo(self: *RevParse) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.infoMessage("not a shallow repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        if (git_dir.openFile(self.io, "shallow", .{})) |f| {
            f.close(self.io);
            try self.output.infoMessage("shallow repository", .{});
        } else |_| {
            try self.output.infoMessage("not a shallow repository", .{});
        }
    }

    fn insideWorkTree(self: *RevParse) bool {
        var buf: [4096]u8 = undefined;
        return self.findGitRoot(&buf) != null;
    }

    fn insideGitDir(self: *RevParse) bool {
        if (Io.Dir.cwd().openDir(self.io, ".git", .{})) |dir| {
            dir.close(self.io);
            return true;
        } else |_| return false;
    }

    fn isBareRepo(self: *RevParse) bool {
        const cwd = Io.Dir.cwd();
        _ = cwd.openFile(self.io, "HEAD", .{}) catch return false;

        const content = cwd.readFileAlloc(self.io, "config", self.allocator, .limited(4096)) catch return true;
        defer self.allocator.free(content);

        return std.mem.indexOf(u8, content, "bare") != null;
    }

    fn findGitRoot(self: *RevParse, out_buf: []u8) ?[]const u8 {
        var buf: [4096]u8 = undefined;
        const path_len = std.process.currentPath(self.io, &buf) catch return null;
        const current = buf[0..path_len];

        var i: usize = current.len;
        while (i > 0) : (i -= 1) {
            const test_path = current[0..i];
            const git_check = std.fmt.allocPrint(self.allocator, "{s}/.git", .{test_path}) catch continue;
            defer self.allocator.free(git_check);

            if (Io.Dir.cwd().openDir(self.io, git_check, .{})) |dir| {
                dir.close(self.io);
                const len = @min(test_path.len, out_buf.len);
                @memcpy(out_buf[0..len], test_path);
                return out_buf[0..len];
            } else |_| {}
        }
        return null;
    }

    fn parseArgs(self: *RevParse, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--verify")) self.options.verify = true;
            if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) self.options.quiet = true;
            if (std.mem.eql(u8, arg, "--show-toplevel")) self.options.show_toplevel = true;
            if (std.mem.eql(u8, arg, "--show-prefix")) self.options.show_prefix = true;
            if (std.mem.eql(u8, arg, "--show-cdup") or std.mem.eql(u8, arg, "--cd")) self.options.show_prefix = true;
            if (std.mem.eql(u8, arg, "--git-dir") or std.mem.eql(u8, arg, "--git-common-dir")) self.options.git_dir = true;
            if (std.mem.eql(u8, arg, "--is-inside-work-tree")) self.options.is_inside_work_tree = true;
            if (std.mem.eql(u8, arg, "--is-inside-git-dir")) self.options.is_inside_git_dir = true;
            if (std.mem.eql(u8, arg, "--is-bare-repository")) self.options.is_bare_repository = true;
            if (std.mem.eql(u8, arg, "--is-shallow-repository")) self.options.is_shallow_repository = true;
            if (std.mem.eql(u8, arg, "--symbolic-full-name")) self.options.symbolic_full_name = true;
            if (std.mem.eql(u8, arg, "--abbrev-ref")) self.options.abbrev_ref = true;
            if (std.mem.eql(u8, arg, "--abbrev-ref=strict")) self.options.abbrev_ref_strict = true;
            if (std.mem.startsWith(u8, arg, "--short=")) self.options.short = std.fmt.parseInt(u8, arg[8..], 10) catch null;
            if (std.mem.startsWith(u8, arg, "--default=")) self.options.default = arg[10..];
        }
    }
};
