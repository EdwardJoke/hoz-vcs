const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const RerereOptions = struct {
    diff: bool = false,
    rerere_autoupdate: bool = false,
    no_rerere_autoupdate: bool = false,
    clear_empty: bool = false,
    forget: bool = false,
    status: bool = false,
};

pub const RerereStatus = struct {
    path: []const u8,
    state: State,

    pub const State = enum {
        resolved,
        pending,
        conflict_original,
        updated,
        not_found,
    };
};

pub const Rerere = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: RerereOptions,
    rerere_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Rerere {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .rerere_dir = ".git/rr-cache",
        };
    }

    pub fn run(self: *Rerere, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("rerere: not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        if (self.options.forget) {
            if (args.len == 0) {
                try self.output.errorMessage("rerere forget: need <path> argument", .{});
                return;
            }
            try self.runForget(&git_dir, args[args.len - 1]);
        } else if (self.options.status) {
            try self.runStatus(&git_dir);
        } else if (self.options.clear_empty) {
            try self.runClearEmpty(&git_dir);
        } else if (self.options.diff) {
            try self.runDiff(&git_dir);
        } else {
            try self.runScan(&git_dir);
        }
    }

    fn runScan(self: *Rerere, git_dir: *const Io.Dir) !void {
        const rr_dir = git_dir.openDir(self.io, self.rerere_dir, .{}) catch {
            try self.output.infoMessage("rerere: no recorded resolutions (rr-cache directory does not exist)", .{});
            return;
        };
        defer rr_dir.close(self.io);

        var walker = rr_dir.walk(self.allocator) catch return;
        defer walker.deinit();

        var count: usize = 0;
        while (true) {
            const entry_opt = walker.next(self.io) catch break;
            const entry = entry_opt orelse break;
            if (entry.kind == .directory) {
                const hash = std.fs.path.basename(entry.path);
                if (hash.len >= 6 and self.hasPreimage(&rr_dir, hash)) {
                    count += 1;
                }
            }
        }

        try self.output.infoMessage("rerere: found {d} recorded resolution(s)", .{count});

        if (self.options.rerere_autoupdate) {
            try self.output.infoMessage("rerere: autoupdate mode enabled — will auto-record resolutions on next conflict resolve", .{});
        }
    }

    fn runStatus(self: *Rerere, git_dir: *const Io.Dir) !void {
        var statuses = std.ArrayList(RerereStatus).initCapacity(self.allocator, 16) catch |err| return err;
        defer statuses.deinit(self.allocator);

        const rr_dir = git_dir.openDir(self.io, self.rerere_dir, .{}) catch {
            try self.output.infoMessage("rerere: no recorded resolutions", .{});
            return;
        };
        defer rr_dir.close(self.io);

        var walker = rr_dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (true) {
            const entry_opt = walker.next(self.io) catch break;
            const entry = entry_opt orelse break;
            if (entry.kind == .directory) {
                const hash = std.fs.path.basename(entry.path);
                const state = self.resolveState(&rr_dir, hash);
                const owned_path = try self.allocator.dupe(u8, hash);
                try statuses.append(self.allocator, .{ .path = owned_path, .state = state });
            }
        }

        for (statuses.items) |st| {
            const state_str = switch (st.state) {
                .resolved => "resolved",
                .pending => "pending (conflict exists)",
                .conflict_original => "conflict (original)",
                .updated => "updated since last resolution",
                .not_found => "preimage missing",
            };
            try self.output.writer.print("{s}  {s}\n", .{ state_str, st.path });
            self.allocator.free(st.path);
        }
    }

    fn runForget(self: *Rerere, git_dir: *const Io.Dir, path: []const u8) !void {
        const rr_dir = git_dir.openDir(self.io, self.rerere_dir, .{}) catch {
            try self.output.infoMessage("rerere forget: nothing to forget (no rr-cache)", .{});
            return;
        };
        defer rr_dir.close(self.io);

        var hash_buf: [64]u8 = undefined;
        const hash = try self.pathToHash(path, &hash_buf);
        const preimage_path = try std.fmt.allocPrint(self.allocator, "{s}/preimage", .{hash});
        defer self.allocator.free(preimage_path);
        const postimage_path = try std.fmt.allocPrint(self.allocator, "{s}/postimage", .{hash});
        defer self.allocator.free(postimage_path);

        _ = rr_dir.deleteFile(self.io, preimage_path) catch {};
        _ = rr_dir.deleteFile(self.io, postimage_path) catch {};

        try self.output.successMessage("rerere forgot: {s}", .{path});
    }

    fn runClearEmpty(self: *Rerere, git_dir: *const Io.Dir) !void {
        const rr_dir = git_dir.openDir(self.io, self.rerere_dir, .{}) catch {
            try self.output.infoMessage("rerere clear-empty: nothing to clear", .{});
            return;
        };
        defer rr_dir.close(self.io);

        var cleared: usize = 0;
        var walker = rr_dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (true) {
            const entry_opt = walker.next(self.io) catch break;
            const entry = entry_opt orelse break;
            if (entry.kind == .directory) {
                const dir_path = entry.path;
                const pi_path = try std.fmt.allocPrint(self.allocator, "{s}/preimage", .{dir_path});
                defer self.allocator.free(pi_path);
                const pimg_path = try std.fmt.allocPrint(self.allocator, "{s}/postimage", .{dir_path});
                defer self.allocator.free(pimg_path);
                const has_preimage = if (rr_dir.openFile(self.io, pi_path, .{})) |_| true else |_| false;
                const has_postimage = if (rr_dir.openFile(self.io, pimg_path, .{})) |_| true else |_| false;

                if (!has_preimage and !has_postimage) {
                    _ = rr_dir.deleteDir(self.io, dir_path) catch {};
                    cleared += 1;
                }
            }
        }

        try self.output.infoMessage("rerere cleared {d} empty resolution directories", .{cleared});
    }

    fn runDiff(self: *Rerere, git_dir: *const Io.Dir) !void {
        const rr_dir = git_dir.openDir(self.io, self.rerere_dir, .{}) catch {
            try self.output.infoMessage("rerere diff: no recorded resolutions", .{});
            return;
        };
        defer rr_dir.close(self.io);

        var walker = rr_dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (true) {
            const entry_opt = walker.next(self.io) catch break;
            const entry = entry_opt orelse break;
            if (entry.kind == .file and std.mem.endsWith(u8, entry.path, "postimage")) {
                const content = rr_dir.readFileAlloc(self.io, entry.path, self.allocator, .limited(64 * 1024)) catch continue;
                defer self.allocator.free(content);

                const dir = std.fs.path.dirname(entry.path) orelse "";
                try self.output.writer.print("--- {s}/preimage\n+++ {s}/postimage\n", .{ dir, dir });
                try self.output.writer.writeAll(content);
                try self.output.writer.writeAll("\n");
            }
        }
    }

    fn hasPreimage(self: *Rerere, rr_dir: *const Io.Dir, hash: []const u8) bool {
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/preimage", .{ self.rerere_dir, hash }) catch return false;
        const file = rr_dir.openFile(self.io, path, .{}) catch |err| {
            if (err == error.FileNotFound or err == error.NotFound)
                return false;
            return false;
        };
        file.close(self.io);
        return true;
    }

    fn resolveState(self: *Rerere, rr_dir: *const Io.Dir, hash: []const u8) RerereStatus.State {
        const preimage_ok = self.hasPreimage(rr_dir, hash);
        if (!preimage_ok) return .not_found;

        var post_buf: [256]u8 = undefined;
        const postimage_path = std.fmt.bufPrint(&post_buf, "{s}/postimage", .{hash}) catch return .pending;
        const post_file = rr_dir.openFile(self.io, postimage_path, .{}) catch |err| {
            if (err == error.FileNotFound or err == error.NotFound)
                return .pending;
            return .pending;
        };
        post_file.close(self.io);
        return .resolved;
    }

    fn pathToHash(_: *Rerere, path: []const u8, out: []u8) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path);
        const digest = hasher.final();
        const hex = std.fmt.hex(digest);
        if (out.len < hex.len) return error.BufferTooSmall;
        @memcpy(out[0..hex.len], &hex);
        return out[0..hex.len];
    }

    fn parseArgs(self: *Rerere, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "diff")) {
                self.options.diff = true;
            } else if (std.mem.eql(u8, arg, "clear-empty")) {
                self.options.clear_empty = true;
            } else if (std.mem.eql(u8, arg, "forget")) {
                self.options.forget = true;
            } else if (std.mem.eql(u8, arg, "status") or std.mem.eql(u8, arg, "-s")) {
                self.options.status = true;
            } else if (std.mem.eql(u8, arg, "--no-rerere-autoupdate")) {
                self.options.no_rerere_autoupdate = true;
            } else if (std.mem.eql(u8, arg, "--rerere-autoupdate")) {
                self.options.rerere_autoupdate = true;
            }
        }
    }
};
