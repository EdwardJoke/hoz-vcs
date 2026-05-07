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
                    try set.put(self.allocator, to_oid, {});
                }
            }
        }
    }

    fn collectUpstreamOids(self: *Cherry, git_dir: *const Io.Dir, base_oid: []const u8, set: *std.array_hash_map.String(void)) !void {
        try set.put(self.allocator, base_oid, {});

        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ base_oid[0..2], base_oid[2..] });
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(16 * 1024 * 1024)) catch return;
        defer self.allocator.free(compressed);

        const decompressed = @import("../compress/zlib.zig").Zlib.decompress(compressed, self.allocator) catch return;
        defer self.allocator.free(decompressed);

        var lines = std.mem.tokenizeAny(u8, decompressed, "\n");
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "parent ")) continue;
            const parent_oid = line["parent ".len..][0..40];
            if (parent_oid.len == 40) {
                _ = set.put(self.allocator, parent_oid, {}) catch {};
                self.collectUpstreamOids(git_dir, parent_oid, set) catch |err| {
                    self.output.warningMessage("Failed to collect upstream OIDs from {s}: {}", .{ parent_oid, err }) catch {};
                    return;
                };
            }
        }
    }

    fn compareCommits(self: *Cherry, git_dir: *const Io.Dir, head_oid: []const u8, upstream_set: *std.array_hash_map.String(void), entries: *std.ArrayList(CherryEntry)) !void {
        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return;
        defer self.allocator.free(head_content);

        const head_trimmed = std.mem.trim(u8, head_content, " \t\r\n");
        const branch_name = if (std.mem.startsWith(u8, head_trimmed, "ref: refs/heads/"))
            head_trimmed["ref: refs/heads/".len..std.mem.indexOfScalar(u8, head_trimmed, '\n').?]
        else
            "master";

        const log_path = try std.fmt.allocPrint(self.allocator, "logs/refs/heads/{s}", .{branch_name});
        const log_data = git_dir.readFileAlloc(self.io, log_path, self.allocator, .limited(4 * 1024 * 1024)) catch return;
        defer self.allocator.free(log_data);

        var found_head = false;
        var lines = std.mem.tokenizeAny(u8, log_data, "\n\r");
        while (lines.next()) |line| {
            if (line.len < 48 or line[0] != ' ') continue;
            const oid = line[1..41];
            if (std.mem.eql(u8, oid, head_oid)) found_head = true;
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
                self.options.abbrev = std.fmt.parseInt(u32, arg["--abbrev=".len..], 10) catch continue;
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
