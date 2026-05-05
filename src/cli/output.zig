//! Standardized CLI output module for AI-friendly interfaces
//!
//! Provides consistent, structured output formats that are both human-readable
//! and machine-parseable. All CLI commands should use this module for output.

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

        try self.writer.print("\n{s}{s}{s}\n", .{
            self.color(if (self.style.use_color) Color.bold else ""),
            title,
            self.color(if (self.style.use_color) Color.reset else ""),
        });
    }

    pub fn item(self: Self, label_text: []const u8, value_text: []const u8) !void {
        if (self.style.quiet) return;

        switch (self.style.format) {
            .human => {
                try self.writer.print("  {s}{s}{s}: {s}\n", .{
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
            try self.writer.print("\n", .{});
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
        try self.writer.print(" ERROR: ", .{});
        try self.writer.print(fmt_str, args);
        try self.writer.print("\n", .{});
    }

    pub fn warningMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .warn);
        try self.writer.print(" WARNING: ", .{});
        try self.writer.print(fmt_str, args);
        try self.writer.print("\n", .{});
    }

    pub fn infoMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .info);
        try self.writer.print(" ", .{});
        try self.writer.print(fmt_str, args);
        try self.writer.print("\n", .{});
    }

    pub fn successMessage(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writeSymbol(self.writer, .check);
        try self.writer.print(" ", .{});
        try self.writer.print(fmt_str, args);
        try self.writer.print("\n", .{});
    }

    pub fn hint(self: Self, comptime fmt_str: []const u8, args: anytype) !void {
        if (self.style.quiet) return;
        if (self.style.format == .json) return;

        try self.writer.print("  ", .{});
        try self.writeSymbol(self.writer, .arrow);
        try self.writer.print(" ", .{});
        try self.writer.print(fmt_str, args);
        try self.writer.print("\n", .{});
    }

    fn writeSymbol(self: Self, writer: *Io.Writer, s: Symbol) !void {
        if (!self.style.use_unicode) {
            switch (s) {
                .check => try writer.writeAll("[OK]"),
                .cross => try writer.writeAll("[ERR]"),
                .info => try writer.writeAll("[INFO]"),
                .warn => try writer.writeAll("[WARN]"),
                .arrow => try writer.writeAll("->"),
            }
            return;
        }

        const sym = switch (s) {
            .check => "✓",
            .cross => "✗",
            .info => "ℹ",
            .warn => "⚠",
            .arrow => "→",
        };

        if (self.style.use_color) {
            const code = switch (s) {
                .check => Color.green,
                .cross => Color.red,
                .info => Color.blue,
                .warn => Color.yellow,
                .arrow => Color.cyan,
            };
            try writer.print("{s}{s}{s}", .{ code, sym, Color.reset });
        } else {
            try writer.writeAll(sym);
        }
    }

    fn color(self: Self, code: []const u8) []const u8 {
        if (!self.style.use_color) return "";
        return code;
    }
};

pub const ListMarker = enum {
    bullet,
    arrow,
    check,
    cross,
    none,
};

const Symbol = enum {
    check,
    cross,
    info,
    warn,
    arrow,
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
