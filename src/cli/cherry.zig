const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const CherryOptions = struct {
    verbose: bool = false,
    abbrev: u32 = 12,
    upstream: ?[]const u8 = null,
    heads: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *CherryOptions, alloc: std.mem.Allocator) void {
        for (self.heads.items) |h| alloc.free(h);
        self.heads.deinit(alloc);
    }
};

pub const CherryEntry = struct {
    status: Status,
    commit_oid: []const u8,
    subject: []const u8,

    pub const Status = enum {
        plus,
        minus,
        equal,
    };
};

pub const Cherry = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: CherryOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Cherry {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *Cherry, args: []const []const u8) !void {
        defer self.options.deinit(self.allocator);
        self.parseArgs(args);

        const upstream = self.options.upstream orelse "origin/master";
        var entries = std.ArrayList(CherryEntry).initCapacity(self.allocator, 64) catch |err| return err;
        defer {
            for (entries.items) |e| {
                self.allocator.free(e.commit_oid);
                self.allocator.free(e.subject);
            }
            entries.deinit(self.allocator);
        }

        try self.findPatches(upstream, &entries);

        if (entries.items.len == 0) {
            try self.output.infoMessage("cherry: no commits to compare", .{});
            return;
        }

        for (entries.items) |entry| {
            const sign: u8 = switch (entry.status) {
                .plus => '+',
                .minus => '-',
                .equal => '=',
            };
            var oid_display = entry.commit_oid;
            if (oid_display.len > self.options.abbrev) oid_display = oid_display[0..self.options.abbrev];

            if (self.options.verbose) {
                try self.output.writer.print(" {c} {s} {s}\n", .{ sign, oid_display, entry.subject });
            } else {
                try self.output.writer.print("{c} {s}\n", .{ sign, oid_display });
            }
        }
    }

    fn findPatches(self: *Cherry, upstream: []const u8, entries: *std.ArrayList(CherryEntry)) !void {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return;
        defer git_dir.close(self.io);

        var upstream_set = std.array_hash_map.String(void).empty;
        defer upstream_set.deinit(self.allocator);

        const upstream_ref = try std.fmt.allocPrint(self.allocator, "refs/remotes/{s}", .{upstream});
        defer self.allocator.free(upstream_ref);

        const upstream_head = git_dir.readFileAlloc(self.io, upstream_ref, self.allocator, .limited(128)) catch {
            try self.loadUpstreamFromLog(&git_dir, upstream, &upstream_set);
            return;
        };
        defer self.allocator.free(upstream_head);

        const upstream_oid = std.mem.trim(u8, upstream_head, " \t\r\n");
        try self.collectUpstreamOids(&git_dir, upstream_oid, &upstream_set);

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(128)) catch return;
        defer self.allocator.free(head_content);

        const head_oid = std.mem.trim(u8, head_content, " \t\r\n");
        try self.compareCommits(&git_dir, head_oid, &upstream_set, entries);
    }

    fn loadUpstreamFromLog(self: *Cherry, git_dir: *const Io.Dir, upstream: []const u8, set: *std.array_hash_map.String(void)) !void {
        const log_path = try std.fmt.allocPrint(self.allocator, "logs/refs/remotes/{s}", .{upstream});
        defer self.allocator.free(log_path);

        const log_data = git_dir.readFileAlloc(self.io, log_path, self.allocator, .limited(4 * 1024 * 1024)) catch return;
        defer self.allocator.free(log_data);

        var lines = std.mem.tokenizeAny(u8, log_data, "\n\r");
        while (lines.next()) |line| {
            if (line.len >= 48) {
                const to_oid = line[41..81];
                if (to_oid.len == 40 and !std.mem.eql(u8, to_oid, "0000000000000000000000000000000000000000")) {
                    _ = set.put(self.allocator, to_oid, {}) catch continue;
                }
            }
        }
    }

    fn collectUpstreamOids(self: *Cherry, git_dir: *const Io.Dir, base_oid: []const u8, set: *std.array_hash_map.String(void)) !void {
        _ = set.put(self.allocator, base_oid, {}) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ base_oid[0..2], base_oid[2..] });
        defer self.allocator.free(obj_path);

        _ = git_dir.openFile(self.io, obj_path, .{}) catch return;
        _ = self.allocator;
    }

    fn compareCommits(self: *Cherry, git_dir: *const Io.Dir, head_oid: []const u8, upstream_set: *std.array_hash_map.String(void), entries: *std.ArrayList(CherryEntry)) !void {
        _ = head_oid;
        const log_path = "logs/refs/heads/master";
        const log_data = git_dir.readFileAlloc(self.io, log_path, self.allocator, .limited(4 * 1024 * 1024)) catch return;
        defer self.allocator.free(log_data);

        var lines = std.mem.tokenizeAny(u8, log_data, "\n\r");
        while (lines.next()) |line| {
            if (line.len < 48 or line[0] != ' ') continue;
            const oid = line[1..41];
            if (upstream_set.contains(oid)) {
                const subject = extractSubject(line[42..]);
                const owned_oid = try self.allocator.dupe(u8, oid);
                const owned_subject = try self.allocator.dupe(u8, subject);
                try entries.append(self.allocator, .{ .status = .equal, .commit_oid = owned_oid, .subject = owned_subject });
            } else {
                const subject = extractSubject(line[42..]);
                const owned_oid = try self.allocator.dupe(u8, oid);
                const owned_subject = try self.allocator.dupe(u8, subject);
                try entries.append(self.allocator, .{ .status = .plus, .commit_oid = owned_oid, .subject = owned_subject });
            }
        }
    }

    fn extractSubject(rest: []const u8) []const u8 {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var start: usize = 0;
        while (start < nl and (rest[start] == ' ' or rest[start] == '\t')) : (start += 1) {}
        return rest[start..nl];
    }

    fn parseArgs(self: *Cherry, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
                self.options.verbose = true;
            } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
                _ = std.fmt.parseInt(u32, arg["--abbrev=".len..], 10) catch continue;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                if (self.options.upstream == null) {
                    self.options.upstream = arg;
                } else {
                    self.options.heads.append(self.allocator, arg) catch {};
                }
            }
        }
    }
};
