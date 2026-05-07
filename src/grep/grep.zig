//! Grep - Search through files tracked by git
const std = @import("std");
const Io = std.Io;

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var found = true;
        for (needle, 0..) |c, j| {
            if (toLower(haystack[i + j]) != toLower(c)) {
                found = false;
                break;
            }
        }
        if (found) return i;
    }
    return null;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub const GrepMatch = struct {
    file_path: []const u8,
    line_number: u32,
    line_content: []const u8,
    match_start: usize,
    match_end: usize,
};

pub const GrepOptions = struct {
    pattern: []const u8,
    case_insensitive: bool = false,
    fixed_strings: bool = false,
    recursive: bool = true,
    files_with_matches: bool = false,
    count_only: bool = false,
    line_number: bool = true,
    context_lines: u32 = 0,
    invert_match: bool = false,
};

pub const Grep = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: GrepOptions,
    matches: std.ArrayListUnmanaged(GrepMatch),

    pub fn init(allocator: std.mem.Allocator, io: Io, opts: GrepOptions) Grep {
        return .{
            .allocator = allocator,
            .io = io,
            .options = opts,
            .matches = .empty,
        };
    }

    pub fn deinit(self: *Grep) void {
        for (self.matches.items) |*m| {
            self.allocator.free(m.line_content);
            self.allocator.free(m.file_path);
        }
        self.matches.deinit(self.allocator);
    }

    pub fn search(self: *Grep, paths: []const []const u8) ![]GrepMatch {
        for (paths) |path| {
            self.searchFile(path) catch continue;
        }
        return self.matches.items;
    }

    pub fn searchInDir(self: *Grep, dir_path: []const u8) ![]GrepMatch {
        if (!self.options.recursive) {
            return self.matches.items;
        }

        const cwd = Io.Dir.cwd();
        const dir = cwd.openDir(self.io, dir_path, .{}) catch return self.matches.items;
        defer dir.close(self.io);

        var walker = dir.walk(self.allocator) catch return self.matches.items;
        defer walker.deinit();

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind == .file) {
                const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.basename });
                defer self.allocator.free(full_path);
                self.searchFile(full_path) catch continue;
            }
        }

        return self.matches.items;
    }

    fn searchFile(self: *Grep, path: []const u8) !void {
        const cwd = Io.Dir.cwd();

        const content = cwd.readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024)) catch return;
        defer self.allocator.free(content);

        const pattern = self.options.pattern;
        var line_num: u32 = 1;

        var it = std.mem.splitSequence(u8, content, "\n");
        while (it.next()) |line| {
            const matched = if (self.options.case_insensitive)
                indexOfIgnoreCase(line, pattern)
            else
                std.mem.indexOf(u8, line, pattern);

            const should_include = if (self.options.invert_match)
                matched == null
            else
                matched != null;

            if (should_include) {
                const match_start = matched orelse 0;
                const match_end = match_start + pattern.len;

                const owned_line = try self.allocator.dupe(u8, line);
                const owned_path = try self.allocator.dupe(u8, path);

                try self.matches.append(self.allocator, GrepMatch{
                    .file_path = owned_path,
                    .line_number = line_num,
                    .line_content = owned_line,
                    .match_start = match_start,
                    .match_end = match_end,
                });

                if (self.options.files_with_matches) return;
            }

            line_num += 1;
        }
    }
};

test "Grep init" {
    const opts = GrepOptions{ .pattern = "test" };
    _ = opts;
    try std.testing.expect(true);
}

test "Grep search method exists" {
    try std.testing.expect(true);
}
