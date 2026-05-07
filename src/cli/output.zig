//! Standardized CLI output module for AI-friendly interfaces
//!
//! Provides consistent, structured output formats that are both human-readable
//! and machine-parseable. All CLI commands should use this module for output.
//!
//! Symbol convention:
//!   Tree nesting:  ├── └── │   (AI-parseable hierarchy)
//!   Status icons:  ✗ ? + - ~ R U  (file state markers)
//!   Section div:   ─────────────  (visual grouping)
//!   Semantic:      ✓ ℹ ⚠ → ◉ ●  (outcome/flow indicators)

const std = @import("std");
const Io = std.Io;

pub const OutputFormat = enum {
    human,
    json,
    porcelain,
};

pub const OutputStyle = struct {
    format: OutputFormat = .human,
    use_color: bool = true,
    use_unicode: bool = true,
    verbose: bool = false,
    quiet: bool = false,
};

pub const Result = struct {
    success: bool,
    code: u8,
    message: []const u8,
    data: ?[]const u8 = null,
};

pub const Progress = struct {
    current: usize,
    total: usize,
    message: []const u8,

    pub fn percent(self: Progress) f64 {
        if (self.total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }
};

pub const TreeSymbols = struct {
    pub const branch: []const u8 = "├──";
    pub const last: []const u8 = "└──";
    pub const vertical: []const u8 = "│";
    pub const indent: []const u8 = "  ";
    pub const continuation: []const u8 = "…";

    pub const Ascii = struct {
        pub const branch: []const u8 = "+--";
        pub const last: []const u8 = "`--";
        pub const vertical: []const u8 = "|";
        pub const indent: []const u8 = "  ";
        pub const continuation: []const u8 = "...";
    };
};

pub const StatusIcon = enum(u8) {
    modified = 'M',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    copied = 'C',
    untracked = '?',
    ignored = '!',
    conflicted = 'U',
    unmodified = ' ',
    submodule = 'S',

    pub fn symbol(self: StatusIcon, unicode: bool) []const u8 {
        if (!unicode) {
            return switch (self) {
                .modified => "M ",
                .added => "A ",
                .deleted => "D ",
                .renamed => "R ",
                .copied => "C ",
                .untracked => "? ",
                .ignored => "! ",
                .conflicted => "U ",
                .unmodified => "  ",
                .submodule => "S ",
            };
        }
        return switch (self) {
            .modified => "~",
            .added => "+",
            .deleted => "-",
            .renamed => "→",
            .copied => "⇄",
            .untracked => "?",
            .ignored => "⊘",
            .conflicted => "✗",
            .unmodified => " ",
            .submodule => "⊞",
        };
    }

    pub fn colorCode(self: StatusIcon) []const u8 {
        return switch (self) {
            .modified => Color.yellow,
            .added => Color.green,
            .deleted => Color.red,
            .renamed => Color.cyan,
            .copied => Color.magenta,
            .untracked => Color.dim,
            .ignored => Color.dim,
            .conflicted => Color.red,
            .unmodified => "",
            .submodule => Color.blue,
        };
    }
};

pub const Output = struct {
    writer: *Io.Writer,
    style: OutputStyle,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(writer: *Io.Writer, style: OutputStyle, allocator: std.mem.Allocator) Self {
        return .{
            .writer = writer,
            .style = style,
            .allocator = allocator,
        };
    }

    pub fn result(self: Self, res: Result) !void {
        switch (self.style.format) {
            .human => try self.resultHuman(res),
            .json => try self.resultJson(res),
            .porcelain => try self.resultPorcelain(res),
        }
    }

    fn resultHuman(self: Self, res: Result) !void {
        if (self.style.quiet) return;

        if (res.success) {
            try self.writeSymbol(self.writer, .check);
        } else {
            try self.writeSymbol(self.writer, .cross);
        }
        try self.writer.print(" {s}\n", .{res.message});

        if (res.data) |data| {
            try self.writer.print("{s}\n", .{data});
        }
    }

    fn resultJson(self: Self, res: Result) !void {
        const data_str = if (res.data) |d| d else "null";
        try self.writer.print(
            "{{\"success\":{s},\"code\":{d},\"message\":\"{s}\",\"data\":{s}}}\n",
            .{
                if (res.success) "true" else "false",
                res.code,
                res.message,
                data_str,
            },
        );
    }

    fn resultPorcelain(self: Self, res: Result) !void {
        if (self.style.quiet) return;
        try self.writer.print("{d}\t{s}\n", .{ res.code, res.message });
        if (res.data) |data| {
            try self.writer.print("{s}\n", .{data});
        }
    }

    pub fn section(self: Self, title: []const u8) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.sectionDivider();
        try self.writer.print("{s}{s}{s}\n", .{
            self.color(if (self.style.use_color) Color.bold else ""),
            title,
            self.color(if (self.style.use_color) Color.reset else ""),
        });
    }

    pub fn sectionDivider(self: Self) !void {
        if (self.style.quiet) return;
        if (self.style.format != .human) return;

        try self.writer.print("{s}{s}{s}\n", .{
            self.color(if (self.style.use_color) Color.dim else ""),
            self.sym(.divider),
            self.color(if (self.style.use_color) Color.reset else ""),
        });
    }

    pub fn item(self: Self, label_text: []const u8, value_text: []const u8) !void {
        if (self.style.quiet) return;

        switch (self.style.format) {
            .human => {
                try self.treeNode(.branch, 1, "{s}{s}{s}: {s}", .{
                    self.color(if (self.style.use_color) Color.dim else ""),
                    label_text,
                    self.color(if (self.style.use_color) Color.reset else ""),
                    value_text,
                });
            },
            .json => {
                try self.writer.print("  \"{s}\": \"{s}\",\n", .{ label_text, value_text });
            },
            .porcelain => {
                try self.writer.print("{s}\t{s}\n", .{ label_text, value_text });
            },
        }
    }

    pub fn listItem(self: Self, marker: ListMarker, text: []const u8) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        const m = switch (marker) {
            .bullet => if (self.style.use_unicode) "•" else "*",
            .arrow => if (self.style.use_unicode) "→" else ">",
            .check => if (self.style.use_unicode) "✓" else "[x]",
            .cross => if (self.style.use_unicode) "✗" else "[ ]",
            .none => " ",
        };

        try self.writer.print("  {s} {s}\n", .{ m, text });
    }

    pub fn treeNode(
        self: Self,
        kind: TreeKind,
        depth: usize,
        comptime fmt_str: []const u8,
        args: anytype,
    ) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        const prefix = switch (kind) {
            .branch => self.sym(.tree_branch),
            .last => self.sym(.tree_last),
            .blank => self.sym(.tree_indent),
        };
        const indent = self.sym(.tree_indent);

        var indent_buf: [128]u8 = undefined;
        var indent_len: usize = 0;
        for (0..depth) |_| {
            @memcpy(indent_buf[indent_len..][0..indent.len], indent);
            indent_len += indent.len;
        }

        try self.writer.writeAll(indent_buf[0..indent_len]);
        try self.writer.writeAll(prefix);
        try self.writer.writeAll(" ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn treeNodeVertical(self: Self, depth: usize, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        const vertical = self.sym(.tree_vertical);
        const indent = self.sym(.tree_indent);

        var indent_buf: [128]u8 = undefined;
        var indent_len: usize = 0;
        for (0..depth) |_| {
            @memcpy(indent_buf[indent_len..][0..vertical.len], vertical);
            indent_len += vertical.len;
            @memcpy(indent_buf[indent_len..][0..indent.len], indent);
            indent_len += indent.len;
        }

        try self.writer.writeAll(indent_buf[0..indent_len]);
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn statusItem(
        self: Self,
        icon: StatusIcon,
        staged: bool,
        path: []const u8,
    ) !void {
        if (self.style.quiet) return;

        switch (self.style.format) {
            .human => {
                const icon_sym = icon.symbol(self.style.use_unicode);
                const color_code = icon.colorCode();
                const stage_marker = if (staged) if (self.style.use_unicode) "◀" else "<" else " ";

                try self.writer.print(" {s}{s}{s} {s} {s}\n", .{
                    self.color(if (self.style.use_color and color_code.len > 0) color_code else ""),
                    stage_marker,
                    icon_sym,
                    self.color(Color.reset),
                    path,
                });
            },
            .json => {
                try self.writer.print("  {{\"status\":\"{c}\",\"staged\":{s},\"path\":\"{s}\"}},\n", .{
                    @intFromEnum(icon),
                    if (staged) "true" else "false",
                    path,
                });
            },
            .porcelain => {
                const stage_char = if (staged) @intFromEnum(icon) else ' ';
                const work_char = if (!staged) @intFromEnum(icon) else ' ';
                try self.writer.print("{c}{c} {s}\n", .{ stage_char, work_char, path });
            },
        }
    }

    pub fn groupHeader(self: Self, title: []const u8, count: ?usize) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        const count_str = if (count) |c|
            try std.fmt.allocPrint(self.allocator, " ({d})", .{c})
        else
            "";

        defer if (count != null) self.allocator.free(count_str);

        try self.writer.print("{s}[{s}]{s}{s}\n", .{
            self.color(if (self.style.use_color) Color.bold else ""),
            title,
            count_str,
            self.color(if (self.style.use_color) Color.reset else ""),
        });
    }

    pub fn progress(self: Self, prog: Progress) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        const pct = prog.percent();
        const bar_width: usize = 30;
        const filled = @as(usize, @intFromFloat(pct / 100.0 * @as(f64, @floatFromInt(bar_width))));

        var bar: [bar_width]u8 = undefined;
        for (0..bar_width) |i| {
            bar[i] = if (i < filled) '█' else '░';
        }

        try self.writer.print("\r{s} {d:.1}% {d}/{d} {s}", .{
            bar,
            pct,
            prog.current,
            prog.total,
            prog.message,
        });

        if (prog.current >= prog.total) {
            try self.writer.writeAll("\n");
        }
    }

    pub fn errorMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.format == .json) {
            try self.result(.{
                .success = false,
                .code = 1,
                .message = try std.fmt.allocPrint(self.allocator, fmt_str, args),
            });
            return;
        }

        try self.writeSymbol(self.writer, .cross);
        try self.writer.writeAll(" ERROR: ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn warningMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .warn);
        try self.writer.writeAll(" WARNING: ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn infoMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .info);
        try self.writer.writeAll(" ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn successMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .check);
        try self.writer.writeAll(" ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    pub fn hint(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writer.writeAll("  ");
        try self.writeSymbol(self.writer, .arrow);
        try self.writer.writeAll(" ");
        try self.writer.print(fmt_str, args);
        try self.writer.writeAll("\n");
    }

    fn writeSymbol(self: Self, writer: *Io.Writer, s: Symbol) !void {
        const is_tree = switch (s) {
            .tree_branch, .tree_last, .tree_vertical, .tree_indent, .tree_continuation, .divider => true,
            else => false,
        };
        if (is_tree) {
            try writer.writeAll(self.sym(s));
            return;
        }

        if (!self.style.use_unicode) {
            switch (s) {
                .check => try writer.writeAll("[OK]"),
                .cross => try writer.writeAll("[ERR]"),
                .info => try writer.writeAll("[INFO]"),
                .warn => try writer.writeAll("[WARN]"),
                .arrow => try writer.writeAll("->"),
                .node => try writer.writeAll("o"),
                .merge_node => try writer.writeAll("m"),
                .file_add => try writer.writeAll("+"),
                .file_del => try writer.writeAll("-"),
                .file_mod => try writer.writeAll("~"),
                else => {},
            }
            return;
        }

        const sym_char = switch (s) {
            .check => "✓",
            .cross => "✗",
            .info => "ℹ",
            .warn => "⚠",
            .arrow => "→",
            .node => "○",
            .merge_node => "●",
            .file_add => "➕",
            .file_del => "➖",
            .file_mod => "✏️",
            else => "",
        };

        if (self.style.use_color) {
            const code = switch (s) {
                .check => Color.green,
                .cross => Color.red,
                .info => Color.blue,
                .warn => Color.yellow,
                .arrow => Color.cyan,
                .node => Color.blue,
                .merge_node => Color.magenta,
                .file_add => Color.green,
                .file_del => Color.red,
                .file_mod => Color.yellow,
                else => Color.reset,
            };
            try writer.print("{s}{s}{s}", .{ code, sym_char, Color.reset });
        } else {
            try writer.writeAll(sym_char);
        }
    }

    fn color(self: Self, code: []const u8) []const u8 {
        if (!self.style.use_color) return "";
        return code;
    }

    fn sym(self: Self, s: Symbol) []const u8 {
        return switch (s) {
            .tree_branch => if (self.style.use_unicode) "├──" else "+--",
            .tree_last => if (self.style.use_unicode) "└──" else "`--",
            .tree_vertical => if (self.style.use_unicode) "│" else "|",
            .tree_indent => "  ",
            .tree_continuation => if (self.style.use_unicode) "…" else "...",
            .divider => if (self.style.use_unicode) "────────────────────────────────────────" else "----------------------------------------",
            else => "",
        };
    }
};

pub const ListMarker = enum {
    bullet,
    arrow,
    check,
    cross,
    none,
};

pub const TreeKind = enum {
    branch,
    last,
    blank,
};

pub const Symbol = enum {
    check,
    cross,
    info,
    warn,
    arrow,
    node,
    merge_node,
    file_add,
    file_del,
    file_mod,
    tree_branch,
    tree_last,
    tree_vertical,
    tree_indent,
    tree_continuation,
    divider,
};

const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
};

test "Output human format" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .use_color = false }, std.testing.allocator);
    try out.result(.{ .success = true, .code = 0, .message = "Done" });

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Done"));
}

test "Output JSON format" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .json }, std.testing.allocator);
    try out.result(.{ .success = true, .code = 0, .message = "Done" });

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "\"success\":true"));
}

test "Output porcelain format" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .porcelain }, std.testing.allocator);
    try out.result(.{ .success = true, .code = 0, .message = "Done" });

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "0\tDone"));
}

test "Output quiet mode suppresses output" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .quiet = true }, std.testing.allocator);
    try out.result(.{ .success = true, .code = 0, .message = "Done" });

    const output = try w.readAll();
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "Progress bar calculation" {
    const prog = Progress{ .current = 50, .total = 100, .message = "Processing" };
    try std.testing.expectEqual(@as(f64, 50.0), prog.percent());
}

test "Tree node rendering with unicode" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .use_color = false }, std.testing.allocator);
    try out.treeNode(.branch, 0, "{s}", .{"src/main.zig"});
    try out.treeNode(.last, 0, "{s}", .{"src/root.zig"});

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "├──"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "└──"));
}

test "Tree node rendering with ASCII fallback" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .use_color = false, .use_unicode = false }, std.testing.allocator);
    try out.treeNode(.branch, 0, "{s}", .{"src/main.zig"});
    try out.treeNode(.last, 0, "{s}", .{"src/root.zig"});

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "+--"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "`--"));
}

test "Status icon rendering" {
    const modified_icon = StatusIcon.modified;
    try std.testing.expectEqualStrings("~", modified_icon.symbol(true));
    try std.testing.expectEqualStrings("M ", modified_icon.symbol(false));

    const added_icon = StatusIcon.added;
    try std.testing.expectEqualStrings("+", added_icon.symbol(true));
}

test "Section divider renders" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .use_color = false }, std.testing.allocator);
    try out.sectionDivider();

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "─"));
}

test "Status item with staging info" {
    var buf: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const w = &writer.interface;

    var out = Output.init(w, .{ .format = .human, .use_color = false }, std.testing.allocator);
    try out.statusItem(.modified, true, "src/main.zig");
    try out.statusItem(.added, false, "README.md");

    const output = try w.readAll();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "~"));
}
