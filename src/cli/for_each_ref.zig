const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const ForEachRefOptions = struct {
    sort: SortMode = .refname,
    format: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    python: bool = false,
    perl: bool = false,
    tcl: bool = false,
    count: bool = false,
    merge: bool = false,
    upstream: bool = false,
    contains: ?[]const u8 = null,
    no_contains: ?[]const u8 = null,
    points_at: ?[]const u8 = null,
    pattern: ?[]const u8 = null,

    pub const SortMode = enum {
        refname,
        version_refname,
        objectname,
    };
};

pub const RefEntry = struct {
    name: []const u8,
    oid: []const u8,
};

pub const ForEachRef = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: ForEachRefOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) ForEachRef {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *ForEachRef, args: []const []const u8) !void {
        self.parseArgs(args);

        var refs = try self.collectRefs();
        defer {
            for (refs.items) |r| {
                self.allocator.free(r.name);
                self.allocator.free(r.oid);
            }
            refs.deinit(self.allocator);
        }

        if (self.options.pattern) |pattern| {
            try self.filterByPattern(&refs, pattern);
        }

        if (self.options.contains) |substr| {
            try self.filterContains(&refs, substr, true);
        }
        if (self.options.no_contains) |substr| {
            try self.filterContains(&refs, substr, false);
        }

        switch (self.options.sort) {
            .refname => try self.sortByName(&refs),
            .version_refname => try self.sortByVersionName(&refs),
            .objectname => try self.sortByOid(&refs),
        }

        if (self.options.count) {
            try self.output.writer.print("{d}\n", .{refs.items.len});
            return;
        }

        if (self.options.format) |fmt| {
            for (refs.items) |ref| {
                const formatted = try self.formatRef(fmt, ref);
                defer self.allocator.free(formatted);
                try self.output.writer.print("{s}\n", .{formatted});
            }
        } else if (self.options.shell) |shell_fmt| {
            for (refs.items) |ref| {
                const formatted = try self.formatShell(shell_fmt, ref);
                defer self.allocator.free(formatted);
                try self.output.writer.print("{s}\n", .{formatted});
            }
        } else {
            for (refs.items) |ref| {
                try self.output.writer.print("{s} {s}\n", .{ ref.oid[0..@min(ref.oid.len, 40)], ref.name });
            }
        }
    }

    fn collectRefs(self: *ForEachRef) !std.ArrayList(RefEntry) {
        var result = std.ArrayList(RefEntry).empty;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return result;
        defer git_dir.close(self.io);

        const ref_dirs = &[_][]const u8{
            "refs/heads",
            "refs/tags",
            "refs/remotes",
            "refs/stash",
        };

        for (ref_dirs) |dir_path| {
            const dir = git_dir.openDir(self.io, dir_path, .{}) catch continue;
            defer dir.close(self.io);

            var walker = dir.walk(self.allocator) catch continue;
            defer walker.deinit();

            while (walker.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;

                const full_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.path });
                defer self.allocator.free(full_name);

                const content = dir.readFileAlloc(self.io, entry.path, self.allocator, .limited(256)) catch continue;
                defer self.allocator.free(content);

                const oid_trimmed = std.mem.trim(u8, content, " \n\r");
                const oid_copy = try self.allocator.dupe(u8, oid_trimmed);
                const name_copy = try self.allocator.dupe(u8, full_name);

                try result.append(self.allocator, .{ .name = name_copy, .oid = oid_copy });
            }
        }

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch return result;
        defer self.allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \n\r");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_path = trimmed[5..];
            const oid = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return result;
            defer self.allocator.free(oid);
            const oid_trimmed = std.mem.trim(u8, oid, " \n\r");

            if (oid_trimmed.len >= 4) {
                const oid_copy = try self.allocator.dupe(u8, oid_trimmed[0..@min(oid_trimmed.len, 40)]);
                const name_copy = try self.allocator.dupe(u8, ref_path);
                try result.append(self.allocator, .{ .name = name_copy, .oid = oid_copy });
            }
        } else if (trimmed.len >= 4) {
            const oid_copy = try self.allocator.dupe(u8, trimmed[0..@min(trimmed.len, 40)]);
            const name_copy = try self.allocator.dupe(u8, "HEAD");
            try result.append(self.allocator, .{ .name = name_copy, .oid = oid_copy });
        }

        return result;
    }

    fn filterByPattern(self: *ForEachRef, refs: *std.ArrayList(RefEntry), pattern: []const u8) !void {
        var i: usize = 0;
        while (i < refs.items.len) {
            const matches = self.globMatch(pattern, refs.items[i].name);
            if (!matches) {
                self.allocator.free(refs.items[i].name);
                self.allocator.free(refs.items[i].oid);
                _ = refs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn filterContains(self: *ForEachRef, refs: *std.ArrayList(RefEntry), substr: []const u8, include: bool) !void {
        var i: usize = 0;
        while (i < refs.items.len) {
            const has_substring = std.mem.indexOf(u8, refs.items[i].name, substr) != null or
                std.mem.indexOf(u8, refs.items[i].oid, substr) != null;
            if (has_substring != include) {
                self.allocator.free(refs.items[i].name);
                self.allocator.free(refs.items[i].oid);
                _ = refs.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn sortByName(_: *ForEachRef, refs: *std.ArrayList(RefEntry)) !void {
        const items = refs.items;
        std.mem.sortUnstable(RefEntry, items, {}, struct {
            fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    }

    fn sortByVersionName(_: *ForEachRef, refs: *std.ArrayList(RefEntry)) !void {
        const items = refs.items;
        std.mem.sortUnstable(RefEntry, items, {}, struct {
            fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
                const a_ver = extractVersion(a.name);
                const b_ver = extractVersion(b.name);
                if (std.mem.eql(u8, a_ver, b_ver)) return std.mem.order(u8, a.name, b.name) == .lt;
                return std.mem.order(u8, a_ver, b_ver) == .lt;
            }
        }.lessThan);
    }

    fn sortByOid(_: *ForEachRef, refs: *std.ArrayList(RefEntry)) !void {
        const items = refs.items;
        std.mem.sortUnstable(RefEntry, items, {}, struct {
            fn lessThan(_: void, a: RefEntry, b: RefEntry) bool {
                return std.mem.order(u8, a.oid, b.oid) == .lt;
            }
        }.lessThan);
    }

    fn formatRef(self: *ForEachRef, fmt: []const u8, ref: RefEntry) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        errdefer buf.deinit(self.allocator);

        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] == '%' and i + 1 < fmt.len) {
                const spec = fmt[i + 1];
                i += 2;
                if (spec == 'o' or spec == 'O') {
                    const s = try std.fmt.allocPrint(self.allocator, "{s}", .{ref.oid[0..@min(ref.oid.len, 40)]});
                    defer self.allocator.free(s);
                    try buf.appendSlice(self.allocator, s);
                } else if (spec == 'r') {
                    try buf.appendSlice(self.allocator, ref.name);
                } else if (spec == 's') {
                    const short = self.shortName(ref.name);
                    try buf.appendSlice(self.allocator, short);
                } else if (spec == 'u') {} else if (spec == 'S') {} else if (spec == 'f') {} else if (spec == 'H') {
                    try buf.appendSlice(self.allocator, " ");
                } else {
                    try buf.append(self.allocator, '%');
                    try buf.append(self.allocator, spec);
                }
            } else {
                try buf.append(self.allocator, fmt[i]);
                i += 1;
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn formatShell(self: *ForEachRef, shell_fmt: []const u8, ref: RefEntry) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        errdefer buf.deinit(self.allocator);

        var i: usize = 0;
        while (i < shell_fmt.len) {
            if (shell_fmt[i] == '$' and i + 1 < shell_fmt.len and shell_fmt[i + 1] == '{') {
                var end_idx: usize = i + 2;
                while (end_idx < shell_fmt.len and shell_fmt[end_idx] != '}') : (end_idx += 1) {}
                const var_name = shell_fmt[i + 2 .. end_idx];
                i = end_idx + 1;

                if (std.mem.eql(u8, var_name, "refname")) {
                    try buf.appendSlice(self.allocator, ref.name);
                } else if (std.mem.eql(u8, var_name, "objectname") or std.mem.eql(u8, var_name, "object")) {
                    try buf.appendSlice(self.allocator, ref.oid[0..@min(ref.oid.len, 40)]);
                } else if (std.mem.eql(u8, var_name, "short")) {
                    const short = self.shortName(ref.name);
                    try buf.appendSlice(self.allocator, short);
                } else {
                    try buf.appendSlice(self.allocator, "$");
                    try buf.append(self.allocator, '{');
                    try buf.appendSlice(self.allocator, var_name);
                    try buf.append(self.allocator, '}');
                }
            } else {
                try buf.append(self.allocator, shell_fmt[i]);
                i += 1;
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    fn shortName(_: *ForEachRef, full_name: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, full_name, '/')) |idx| {
            return full_name[idx + 1 ..];
        }
        return full_name;
    }

    fn globMatch(_: *ForEachRef, pattern: []const u8, subject: []const u8) bool {
        if (std.mem.indexOf(u8, pattern, "*") == null) {
            return std.mem.eql(u8, pattern, subject);
        }

        const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, subject);

        if (star_pos == 0 and pattern.len == 1) return true;

        if (star_pos == 0) {
            const suffix = pattern[1..];
            if (suffix.len == 0) return true;
            return std.mem.endsWith(u8, subject, suffix);
        }

        if (star_pos == pattern.len - 1) {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, subject, prefix);
        }

        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];
        return std.mem.startsWith(u8, subject, prefix) and std.mem.endsWith(u8, subject, suffix);
    }

    fn parseArgs(self: *ForEachRef, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--sort=refname") or std.mem.eql(u8, arg, "--sort")) self.options.sort = .refname;
            if (std.mem.eql(u8, arg, "--sort=version:refname")) self.options.sort = .version_refname;
            if (std.mem.eql(u8, arg, "--sort=objectname")) self.options.sort = .objectname;
            if (std.mem.startsWith(u8, arg, "--format=")) self.options.format = arg[9..];
            if (std.mem.startsWith(u8, arg, "--shell=")) self.options.shell = arg[8..];
            if (std.mem.eql(u8, arg, "--python")) self.options.python = true;
            if (std.mem.eql(u8, arg, "--perl")) self.options.perl = true;
            if (std.mem.eql(u8, arg, "--tcl")) self.options.tcl = true;
            if (std.mem.eql(u8, arg, "--count")) self.options.count = true;
            if (std.mem.eql(u8, arg, "--merge")) self.options.merge = true;
            if (std.mem.eql(u8, arg, "--upstream")) self.options.upstream = true;
            if (std.mem.startsWith(u8, arg, "--contains=")) self.options.contains = arg[11..];
            if (std.mem.startsWith(u8, arg, "--no-contains=")) self.options.no_contains = arg[14..];
            if (std.mem.startsWith(u8, arg, "--points-at=")) self.options.points_at = arg[13..];
            if (!std.mem.startsWith(u8, arg, "-") and self.options.pattern == null) {
                self.options.pattern = arg;
            }
        }
    }
};

fn extractVersion(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |last_slash| {
        const basename = name[last_slash + 1 ..];
        if (std.mem.indexOfScalar(u8, basename, 'v')) |v_idx| {
            if (v_idx < basename.len - 1 and std.ascii.isDigit(basename[v_idx + 1])) {
                return basename[v_idx..];
            }
        }
        return basename;
    }
    return name;
}
