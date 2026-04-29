const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const Index = @import("../index/index.zig").Index;
const StagerRemover = @import("../stage/rm.zig").StagerRemover;

pub const RmOptions = struct {
    cached: bool = false,
    force: bool = false,
    recursive: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
};

pub const Rm = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: RmOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Rm {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Rm, args: []const []const u8) !void {
        self.parseArgs(args);

        var path_list = std.ArrayList([]const u8).initCapacity(self.allocator, args.len) catch |err| return err;
        defer path_list.deinit(self.allocator);
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                path_list.append(self.allocator, arg) catch {};
            }
        }

        const paths = if (path_list.items.len > 0) path_list.items else &[_][]const u8{};

        if (paths.len == 0) {
            try self.output.errorMessage("Nothing specified, nothing removed.", .{});
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const index_data = git_dir.readFileAlloc(self.io, "index", self.allocator, .limited(16 * 1024 * 1024)) catch null;
        defer if (index_data) |d| self.allocator.free(d);

        var index: ?Index = null;
        if (index_data) |data| {
            index = Index.parse(data, self.allocator) catch null;
        } else {
            try self.output.errorMessage("Index not found", .{});
            return;
        }

        if (index) |*idx| {
            defer idx.deinit();

            var remover = StagerRemover.init(self.allocator, idx);
            remover.options.cached = self.options.cached;
            remover.options.force = self.options.force;
            remover.options.dry_run = self.options.dry_run;
            remover.options.recursive = self.options.recursive;
            remover.options.verbose = self.options.verbose;

            for (paths) |path| {
                if (!self.options.cached and !self.options.dry_run) {
                    self.deleteWorkingTreeFile(path);
                }

                const result = try remover.remove(&[_][]const u8{path});
                _ = result;
                if (self.options.verbose or self.options.dry_run) {
                    try self.output.infoMessage("rm '{s}'", .{path});
                }
            }

            const serialized = idx.serialize() catch {
                try self.output.errorMessage("Failed to serialize index", .{});
                return;
            };
            defer self.allocator.free(serialized);

            if (!self.options.dry_run) {
                git_dir.writeFile(self.io, .{ .sub_path = "index", .data = serialized }) catch {
                    try self.output.errorMessage("Failed to write index", .{});
                };
            }
        }
    }

    fn deleteWorkingTreeFile(self: *Rm, path: []const u8) void {
        cwd_delete: {
            const cwd = Io.Dir.cwd();
            cwd.deleteFile(self.io, path) catch {
                break :cwd_delete;
            };

            const parent_dir = std.fs.path.dirname(path) orelse ".";
            if (!std.mem.eql(u8, parent_dir, ".")) {
                var dir = cwd.openDir(self.io, parent_dir, .{}) catch return;
                defer dir.close(self.io);

                const basename = std.fs.path.basename(path);
                dir.deleteFile(self.io, basename) catch {};
            }
        }
    }

    fn parseArgs(self: *Rm, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--cached")) {
                self.options.cached = true;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                self.options.force = true;
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--recursive")) {
                self.options.recursive = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
                self.options.dry_run = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                self.options.verbose = true;
            }
        }
    }
};
