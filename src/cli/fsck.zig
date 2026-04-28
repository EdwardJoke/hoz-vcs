const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const FsckEngine = @import("../perf/fsck.zig").Fsck;

pub const FsckOptions = struct {
    full: bool = false,
    fast: bool = false,
    strict: bool = false,
    verbose: bool = false,
    no_reflogs: bool = false,
    no_dangling: bool = false,
    lost_found: bool = false,
    cache: bool = false,
};

pub const Fsck = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: FsckOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Fsck {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Fsck, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var fsck = try FsckEngine.init(self.allocator);
        defer fsck.deinit();

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch null;
        if (head_content) |hc| {
            defer self.allocator.free(hc);
            const trimmed = std.mem.trim(u8, hc, " \n\r");

            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_path = trimmed[5..];
                const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch null;
                if (ref_content) |rc| {
                    defer self.allocator.free(rc);
                    const ref_trimmed = std.mem.trim(u8, rc, " \n\r");
                    try fsck.checkObject("HEAD", ref_trimmed, "commit");
                } else {
                    try fsck.checkObject("HEAD", "", "commit");
                }
            } else {
                try fsck.checkObject("HEAD", trimmed, "commit");
            }
        }

        const refs_heads = git_dir.openDir(self.io, "refs/heads", .{}) catch null;
        if (refs_heads) |rh| {
            defer rh.close(self.io);
            var walker = rh.walk(self.allocator) catch null;
            if (walker) |*w| {
                defer w.deinit();
                while (w.next(self.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    const ref_name = std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{entry.path}) catch continue;
                    defer self.allocator.free(ref_name);
                    const ref_content = rh.readFileAlloc(self.io, entry.path, self.allocator, .limited(256)) catch continue;
                    defer self.allocator.free(ref_content);
                    const target = std.mem.trim(u8, ref_content, " \n\r");
                    try fsck.checkRef(ref_name, target);
                }
            }
        }

        const refs_tags = git_dir.openDir(self.io, "refs/tags", .{}) catch null;
        if (refs_tags) |rt| {
            defer rt.close(self.io);
            var walker = rt.walk(self.allocator) catch null;
            if (walker) |*w| {
                defer w.deinit();
                while (w.next(self.io) catch null) |entry| {
                    if (entry.kind != .file) continue;
                    const ref_name = std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{entry.path}) catch continue;
                    defer self.allocator.free(ref_name);
                    const ref_content = rt.readFileAlloc(self.io, entry.path, self.allocator, .limited(256)) catch continue;
                    defer self.allocator.free(ref_content);
                    const target = std.mem.trim(u8, ref_content, " \n\r");
                    try fsck.checkRef(ref_name, target);
                }
            }
        }

        if (fsck.hasErrors()) {
            try self.output.errorMessage("fsck: {d} error(s) found", .{fsck.getErrorCount()});
            if (self.options.verbose or self.options.full) {
                for (fsck.errors.items) |err| {
                    try self.output.writer.print("  error: {s}: {s}\n", .{ @tagName(err.error_type), err.message });
                }
            }
        } else {
            try self.output.successMessage("fsck: no errors found", .{});
        }

        if (fsck.getWarningCount() > 0 and (self.options.verbose or self.options.full)) {
            try self.output.infoMessage("fsck: {d} warning(s)", .{fsck.getWarningCount()});
            for (fsck.warnings.items) |warn| {
                try self.output.writer.print("  warning: {s}: {s}\n", .{ @tagName(warn.error_type), warn.message });
            }
        }

        if (self.options.lost_found) {
            try self.findDanglingObjects(&git_dir, &fsck);
        }
    }

    fn parseArgs(self: *Fsck, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--full") or std.mem.eql(u8, arg, "-f")) {
                self.options.full = true;
            } else if (std.mem.eql(u8, arg, "--fast")) {
                self.options.fast = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                self.options.strict = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                self.options.verbose = true;
            } else if (std.mem.eql(u8, arg, "--no-reflogs")) {
                self.options.no_reflogs = true;
            } else if (std.mem.eql(u8, arg, "--no-dangling")) {
                self.options.no_dangling = true;
            } else if (std.mem.eql(u8, arg, "--lost-found")) {
                self.options.lost_found = true;
            } else if (std.mem.eql(u8, arg, "--cache")) {
                self.options.cache = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                _ = self.options.lost_found;
            }
        }
    }

    fn findDanglingObjects(self: *Fsck, git_dir: *const Io.Dir, fsck: *FsckEngine) !void {
        var reachable = std.array_hash_map.String(void).empty;
        defer {
            var it = reachable.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            reachable.deinit(self.allocator);
        }

        try self.collectReachableOids(git_dir, &reachable);

        var all_objects = std.ArrayList([]const u8).empty;
        defer {
            for (all_objects.items) |oid| self.allocator.free(oid);
            all_objects.deinit(self.allocator);
        }

        const objects_dir = git_dir.openDir(self.io, "objects", .{}) catch return;
        defer objects_dir.close(self.io);

        var dir_iter = objects_dir.iterate();
        while (dir_iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory or entry.name.len != 2) continue;
            if (!std.ascii.isHex(entry.name[0]) or !std.ascii.isHex(entry.name[1])) continue;

            const sub_dir = objects_dir.openDir(self.io, entry.name, .{}) catch continue;
            defer sub_dir.close(self.io);

            var sub_iter = sub_dir.iterate();
            while (sub_iter.next(self.io) catch null) |obj_entry| {
                if (obj_entry.kind != .file or obj_entry.name.len < 38) continue;
                const oid = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ entry.name, obj_entry.name }) catch continue;
                try all_objects.append(self.allocator, oid);
            }
        }

        var dangling_count: u32 = 0;
        for (all_objects.items) |oid| {
            if (oid.len < 40) continue;
            if (reachable.contains(oid[0..40])) continue;

            dangling_count += 1;
            try self.output.writer.print("dangling {s} {s}\n", .{ "object", oid[0..@min(oid.len, 12)] });

            if (self.options.lost_found) {
                try self.saveDanglingObject(git_dir, oid);
            }
        }

        if (dangling_count > 0) {
            try self.output.infoMessage("fsck: {d} dangling object(s) found", .{dangling_count});
        } else {
            try self.output.infoMessage("fsck: no dangling objects", .{});
        }

        _ = fsck;
    }

    fn collectReachableOids(self: *Fsck, git_dir: *const Io.Dir, reachable: *std.array_hash_map.String(void)) !void {
        const ref_dirs = &[_][]const u8{ "refs/heads", "refs/tags", "refs/remotes" };

        for (ref_dirs) |ref_dir_path| {
            const ref_dir = git_dir.openDir(self.io, ref_dir_path, .{}) catch continue;
            defer ref_dir.close(self.io);

            var walker = ref_dir.walk(self.allocator) catch continue;
            defer walker.deinit();

            while (walker.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                const ref_content = ref_dir.readFileAlloc(self.io, entry.path, self.allocator, .limited(256)) catch continue;
                defer self.allocator.free(ref_content);
                const target = std.mem.trim(u8, ref_content, " \n\r");
                if (target.len >= 40) {
                    const oid_copy = try self.allocator.dupe(u8, target[0..40]);
                    reachable.put(self.allocator, oid_copy, {}) catch {
                        self.allocator.free(oid_copy);
                    };
                }
            }
        }

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_content = git_dir.readFileAlloc(self.io, trimmed[5..], self.allocator, .limited(256)) catch return;
            defer self.allocator.free(ref_content);
            const target = std.mem.trim(u8, ref_content, " \n\r");
            if (target.len >= 40) {
                const oid_copy = try self.allocator.dupe(u8, target[0..40]);
                reachable.put(self.allocator, oid_copy, {}) catch {
                    self.allocator.free(oid_copy);
                };
            }
        } else if (trimmed.len >= 40) {
            const oid_copy = try self.allocator.dupe(u8, trimmed[0..40]);
            reachable.put(self.allocator, oid_copy, {}) catch {
                self.allocator.free(oid_copy);
            };
        }
    }

    fn saveDanglingObject(self: *Fsck, git_dir: *const Io.Dir, oid: []const u8) !void {
        if (oid.len < 40) return;

        const obj_path = std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ oid[0..2], oid[2..40] }) catch return;
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return;
        defer self.allocator.free(compressed);

        const decompressed = @import("../compress/zlib.zig").Zlib.decompress(compressed, self.allocator) catch return;
        defer self.allocator.free(decompressed);

        const null_idx = std.mem.indexOfScalar(u8, decompressed, '\x00') orelse return;
        const header = decompressed[0..null_idx];

        var obj_type: []const u8 = "other";
        if (std.mem.startsWith(u8, header, "commit")) {
            obj_type = "commit";
        } else if (std.mem.startsWith(u8, header, "tree")) {
            obj_type = "tree";
        } else if (std.mem.startsWith(u8, header, "blob")) {
            obj_type = "blob";
        } else if (std.mem.startsWith(u8, header, "tag")) {
            obj_type = "tag";
        }

        const lost_found_dir = std.fmt.allocPrint(self.allocator, "lost-found/{s}", .{obj_type}) catch return;
        defer self.allocator.free(lost_found_dir);

        git_dir.createDirPath(self.io, lost_found_dir) catch {};

        const filename = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ lost_found_dir, oid[0..40] }) catch return;
        defer self.allocator.free(filename);

        const data = decompressed[null_idx + 1 ..];
        git_dir.writeFile(self.io, .{ .sub_path = filename, .data = data }) catch {};

        try self.output.infoMessage("Saved dangling {s} to .git/{s}", .{ obj_type, filename });
    }
};
