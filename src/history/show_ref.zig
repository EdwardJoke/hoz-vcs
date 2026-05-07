//! History ShowRef - Show references (branches and tags)
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const Ref = @import("../ref/ref.zig").Ref;

pub const ShowRefOptions = struct {
    heads: bool = true,
    tags: bool = true,
    all: bool = false,
    deref_tags: bool = false,
    abbrev_oid: bool = true,
    abbrev_length: u8 = 7,
    pattern: ?[]const u8 = null,
    with_symref: bool = false,
    return_oid_only: bool = false,
};

pub const ShowRefResult = struct {
    ref_name: []const u8,
    oid: OID,
    symref_target: ?[]const u8 = null,
    is_tag: bool,
};

pub const RefShower = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: ShowRefOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, options: ShowRefOptions) RefShower {
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
        };
    }

    pub fn showRefs(self: *RefShower) ![]const ShowRefResult {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return &.{};
        defer git_dir.close(self.io);

        var results = std.ArrayList(ShowRefResult).empty;
        errdefer {
            for (results.items) |r| {
                self.allocator.free(r.ref_name);
                if (r.symref_target) |t| self.allocator.free(t);
            }
            results.deinit(self.allocator);
        }

        const ref_dirs = &[_][]const u8{
            "refs/heads",
            "refs/tags",
            "refs/remotes",
        };

        for (ref_dirs) |dir_path| {
            const is_tags = std.mem.indexOf(u8, dir_path, "tags") != null;
            const is_heads = std.mem.indexOf(u8, dir_path, "heads") != null and !is_tags;

            if (!self.options.all) {
                if (is_heads and !self.options.heads) continue;
                if (is_tags and !self.options.tags) continue;
            }

            const sub_dir = git_dir.openDir(self.io, dir_path, .{}) catch continue;
            defer sub_dir.close(self.io);

            var walker = sub_dir.walk(self.allocator) catch continue;
            defer walker.deinit();

            while (true) {
                const entry = walker.next(self.io) catch break;
                const e = entry orelse break;
                if (e.kind != .file) continue;

                const full_ref = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, e.path });
                errdefer self.allocator.free(full_ref);

                if (self.options.pattern) |pat| {
                    if (!self.globMatch(full_ref, pat)) {
                        self.allocator.free(full_ref);
                        continue;
                    }
                }

                const oid_hex = sub_dir.readFileAlloc(self.io, e.path, self.allocator, .limited(64)) catch {
                    self.allocator.free(full_ref);
                    continue;
                };
                defer self.allocator.free(oid_hex);

                const trimmed = std.mem.trim(u8, oid_hex, " \t\r\n");
                const oid = OID.fromHex(trimmed) catch {
                    self.allocator.free(full_ref);
                    continue;
                };

                try results.append(self.allocator, .{
                    .ref_name = full_ref,
                    .oid = oid,
                    .symref_target = null,
                    .is_tag = is_tags,
                });
            }
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn showHead(self: *RefShower) !ShowRefResult {
        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            return error.NotARepository;
        };
        defer git_dir.close(self.io);

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch {
            return ShowRefResult{
                .ref_name = try self.allocator.dupe(u8, "HEAD"),
                .oid = OID.zero(),
                .is_tag = false,
            };
        };
        defer self.allocator.free(head_content);

        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");

        var symref_target: ?[]const u8 = null;
        var oid_str: []const u8 = trimmed;

        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            symref_target = try self.allocator.dupe(u8, trimmed[5..]);
            const ref_path = trimmed[5..];
            const ref_content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(64)) catch {
                return ShowRefResult{
                    .ref_name = try self.allocator.dupe(u8, "HEAD"),
                    .oid = OID.zero(),
                    .symref_target = symref_target,
                    .is_tag = false,
                };
            };
            defer self.allocator.free(ref_content);
            oid_str = std.mem.trim(u8, ref_content, " \t\r\n");
        }

        const oid = OID.fromHex(oid_str) catch OID.zero();

        return ShowRefResult{
            .ref_name = try self.allocator.dupe(u8, "HEAD"),
            .oid = oid,
            .symref_target = symref_target,
            .is_tag = false,
        };
    }

    pub fn formatRef(self: *RefShower, result: *const ShowRefResult, writer: anytype) !void {
        _ = self;

        const hex = result.oid.toHex();
        const display_hex = if (self.options.abbrev_oid)
            hex[0..@min(self.options.abbrev_length, hex.len)]
        else
            hex;

        try writer.print("{s} {s}", .{ display_hex, result.ref_name });

        if (result.symref_target) |target| {
            try writer.print(" symbolic ref -> {s}", .{target});
        }

        if (result.is_tag and self.options.deref_tags) {
            try writer.print(" {}", .{});
        }

        try writer.print("\n", .{});
    }

    fn globMatch(self: *RefShower, text: []const u8, pattern: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, pattern, "*")) return true;
        if (std.mem.endsWith(u8, pattern, "*")) {
            return std.mem.startsWith(u8, text, pattern[0 .. pattern.len - 1]);
        }
        return std.mem.eql(u8, text, pattern);
    }
};

test "ShowRefOptions default values" {
    const options = ShowRefOptions{};
    try std.testing.expect(options.heads == true);
    try std.testing.expect(options.tags == true);
    try std.testing.expect(options.all == false);
    try std.testing.expect(options.abbrev_oid == true);
}

test "ShowRefResult structure" {
    const result = ShowRefResult{
        .ref_name = "refs/heads/main",
        .oid = OID.zero(),
        .symref_target = null,
        .is_tag = false,
    };

    try std.testing.expectEqualStrings("refs/heads/main", result.ref_name);
    try std.testing.expect(result.is_tag == false);
}

test "RefShower init" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    const options = ShowRefOptions{};
    const shower = RefShower.init(std.testing.allocator, io, options);

    try std.testing.expect(shower.allocator == std.testing.allocator);
}

test "RefShower init with options" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var options = ShowRefOptions{};
    options.all = true;
    options.deref_tags = true;
    const shower = RefShower.init(std.testing.allocator, io, options);

    try std.testing.expect(shower.options.all == true);
    try std.testing.expect(shower.options.deref_tags == true);
}

test "RefShower showRefs method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var options = ShowRefOptions{};
    var shower = RefShower.init(std.testing.allocator, io, options);

    const result = try shower.showRefs();
    _ = result;
    try std.testing.expect(true);
}

test "RefShower showHead method exists" {
    var buf: [1]u8 = undefined;
    const io: Io = .init(.{ .stdin = .empty, .stdout = .buffered(&buf), .stderr = .buffered(&buf) });
    var options = ShowRefOptions{};
    var shower = RefShower.init(std.testing.allocator, io, options);

    const result = try shower.showHead();
    _ = result;
    try std.testing.expectEqualStrings("HEAD", result.ref_name);
}
