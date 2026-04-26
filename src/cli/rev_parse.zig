//! Git Rev-Parse - Parse revision identifiers and object names
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");

pub const RevParseOptions = struct {
    show_type: bool = false,
    verify: bool = false,
    quiet: bool = false,
    short: ?u32 = null,
    abbrev_ref: bool = false,
    symbolic: bool = false,
    show_prefix: bool = false,
    git_dir_only: bool = false,
    git_common_dir: bool = false,
    is_inside_git_dir: bool = false,
    is_inside_work_tree: bool = false,
    resolve_git_dir: bool = false,
    resolve_git_file: bool = false,
    show_cdup: bool = false,
    show_toplevel: bool = false,
    show_superproject_shell: bool = false,
    shared_index_path: bool = false,
    show_object_format: bool = false,
    default: ?[]const u8 = null,
};

pub const RevParse = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: RevParseOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) RevParse {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *RevParse, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.options.is_inside_work_tree) {
            const cwd = Io.Dir.cwd();
            _ = cwd.openDir(self.io, ".git", .{}) catch {
                try self.output.writer.print("false\n", .{});
                return;
            };
            try self.output.writer.print("true\n", .{});
            return;
        }

        if (self.options.is_inside_git_dir) {
            try self.output.writer.print("false\n", .{});
            return;
        }

        if (self.options.show_toplevel) {
            try self.output.writer.print(".\n", .{});
            return;
        }

        if (self.options.show_cdup) {
            try self.output.writer.print("\n", .{});
            return;
        }

        if (self.options.git_dir_only) {
            try self.output.writer.print(".git\n", .{});
            return;
        }

        if (self.options.git_common_dir) {
            try self.output.writer.print(".git\n", .{});
            return;
        }

        if (self.options.show_object_format) {
            try self.output.writer.print("sha1\n", .{});
            return;
        }

        if (args.len == 0) {
            const default = self.options.default orelse "HEAD";
            const oid = self.resolve(default) catch {
                if (!self.options.quiet) {
                    try self.output.errorMessage("{s}: no such ref", .{default});
                }
                return;
            };
            try self.printResult(oid, default);
            return;
        }

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;

            const oid = self.resolve(arg) catch {
                if (!self.options.quiet) {
                    try self.output.errorMessage("{s}: no such ref or revision", .{arg});
                }
                continue;
            };

            try self.printResult(oid, arg);
        }
    }

    fn printResult(self: *RevParse, oid: oid_mod.OID, input: []const u8) !void {
        if (self.options.symbolic) {
            const name = self.toSymbolicName(input);
            try self.output.writer.print("{s}\n", .{name});
            return;
        }

        if (self.options.abbrev_ref) {
            const short = self.toAbbrevRef(input);
            try self.output.writer.print("{s}\n", .{short});
            return;
        }

        if (self.options.short) |len| {
            const hex = oid.toHex();
            try self.output.writer.print("{s}\n", .{hex[0..@min(hex.len, len)]});
            return;
        }

        const hex = oid.toHex();
        try self.output.writer.print("{s}\n", .{hex});

        if (self.options.show_type) {
            const obj_type = self.getObjectType(oid);
            try self.output.writer.print("{s}\n", .{obj_type});
        }
    }

    fn parseArgs(self: *RevParse, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--show-t")) {
                self.options.show_type = true;
            } else if (std.mem.eql(u8, arg, "--verify")) {
                self.options.verify = true;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
                self.options.quiet = true;
            } else if (std.mem.startsWith(u8, arg, "--short=")) {
                self.options.short = std.fmt.parseInt(u32, arg["--short=".len..], 10) catch 7;
            } else if (std.mem.eql(u8, arg, "--abbrev-ref")) {
                self.options.abbrev_ref = true;
            } else if (std.mem.eql(u8, arg, "--symbolic")) {
                self.options.symbolic = true;
            } else if (std.mem.eql(u8, arg, "--show-prefix")) {
                self.options.show_prefix = true;
            } else if (std.mem.eql(u8, arg, "--git-dir") or std.mem.eql(u8, arg, "--git-common-dir")) {
                self.options.git_dir_only = true;
            } else if (std.mem.eql(u8, arg, "--is-inside-git-dir")) {
                self.options.is_inside_git_dir = true;
            } else if (std.mem.eql(u8, arg, "--is-inside-work-tree")) {
                self.options.is_inside_work_tree = true;
            } else if (std.mem.eql(u8, arg, "--resolve-git-dir")) {
                self.options.resolve_git_dir = true;
            } else if (std.mem.eql(u8, arg, "--resolve-git-file")) {
                self.options.resolve_git_file = true;
            } else if (std.mem.eql(u8, arg, "--cdup") or std.mem.eql(u8, arg, "--show-cdup")) {
                self.options.show_cdup = true;
            } else if (std.mem.eql(u8, arg, "--show-toplevel")) {
                self.options.show_toplevel = true;
            } else if (std.mem.eql(u8, arg, "--show-superproject-working-tree") or std.mem.eql(u8, arg, "--show-superproject-shell")) {
                self.options.show_superproject_shell = true;
            } else if (std.mem.eql(u8, arg, "--shared-index-path")) {
                self.options.shared_index_path = true;
            } else if (std.mem.eql(u8, arg, "--show-object-format")) {
                self.options.show_object_format = true;
            } else if (std.mem.startsWith(u8, arg, "--default=")) {
                self.options.default = arg["--default=".len..];
            } else if (!std.mem.startsWith(u8, arg, "-")) {}
        }
    }

    fn resolve(self: *RevParse, spec: []const u8) !oid_mod.OID {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch
            return error.NotARepo;
        defer git_dir.close(self.io);

        if (std.mem.eql(u8, spec, "HEAD") or std.mem.eql(u8, spec, "@")) {
            return self.resolveHead(&git_dir);
        }

        if (std.mem.eql(u8, spec, "FETCH_HEAD")) {
            return self.readRefFile(&git_dir, "FETCH_HEAD");
        }

        if (std.mem.eql(u8, spec, "MERGE_HEAD")) {
            return self.readRefFile(&git_dir, "MERGE_HEAD");
        }

        if (std.mem.startsWith(u8, spec, "refs/") or
            std.mem.startsWith(u8, spec, "heads/") or
            std.mem.startsWith(u8, spec, "tags/"))
        {
            var buf: [256]u8 = undefined;
            const ref_path = if (std.mem.startsWith(u8, spec, "refs/"))
                spec
            else
                std.fmt.bufPrint(&buf, "refs/{s}", .{spec}) catch return error.InvalidSpec;
            return self.readRefFile(&git_dir, ref_path);
        }

        if (spec.len >= 7 and spec.len <= 40) {
            for (spec) |c| {
                if (!std.ascii.isHex(c)) return error.InvalidOid;
            }
            var hex_buf: [40]u8 = undefined;
            @memset(hex_buf[0..(40 - spec.len)], '0');
            for (spec, 0..) |c, j| {
                hex_buf[(40 - spec.len) + j] = c;
            }
            return oid_mod.OID.fromHex(&hex_buf) catch unreachable;
        }

        return error.UnknownRevision;
    }

    fn resolveHead(self: *RevParse, git_dir: *const Io.Dir) !oid_mod.OID {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch
            return error.NoHead;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            return self.readRefFile(git_dir, trimmed[5..]);
        }
        return oid_mod.OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
    }

    fn readRefFile(self: *RevParse, git_dir: *const Io.Dir, path: []const u8) !oid_mod.OID {
        const content = git_dir.readFileAlloc(self.io, path, self.allocator, .limited(256)) catch
            return error.RefNotFound;
        defer self.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \n\r");
        return oid_mod.OID.fromHex(trimmed[0..40]) catch error.InvalidOid;
    }

    fn toSymbolicName(_: *RevParse, input: []const u8) []const u8 {
        if (std.mem.eql(u8, input, "HEAD")) return "HEAD";
        if (std.mem.startsWith(u8, input, "refs/heads/"))
            return input["refs/heads/".len..];
        if (std.mem.startsWith(u8, input, "refs/tags/"))
            return input["refs/tags/".len..];
        if (std.mem.startsWith(u8, input, "refs/remotes/"))
            return input["refs/remotes/".len..];
        return input;
    }

    fn toAbbrevRef(_: *RevParse, input: []const u8) []const u8 {
        if (std.mem.startsWith(u8, input, "refs/heads/"))
            return input["refs/heads/".len..];
        if (std.mem.startsWith(u8, input, "refs/tags/"))
            return input["refs/tags/".len..];
        if (std.mem.startsWith(u8, input, "refs/remotes/"))
            return input["refs/remotes/".len..];
        if (std.mem.startsWith(u8, input, "refs/"))
            return input["refs/".len..];
        return input;
    }

    fn getObjectType(_: *RevParse, oid: oid_mod.OID) []const u8 {
        _ = oid;
        return "commit";
    }
};
