//! Git Status - Show working tree status
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const StatusScanner = @import("../workdir/scanner.zig").StatusScanner;
const status_mod = @import("../workdir/status.zig");

pub const Status = struct {
    allocator: std.mem.Allocator,
    io: Io,
    porcelain: bool,
    short_format: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Status {
        return .{
            .allocator = allocator,
            .io = io,
            .porcelain = false,
            .short_format = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Status) !void {
        var scanner = StatusScanner.init(
            self.allocator,
            &self.io,
            ".",
            ".",
            .{ .show_untracked = true, .porcelain = self.porcelain },
        );
        defer scanner.deinit();

        scanner.loadIndex();
        const result = try scanner.scan();

        if (self.porcelain) {
            try self.runPorcelain(result);
        } else if (self.short_format) {
            try self.runShort(result);
        } else {
            try self.runLong(result);
        }

        for (result.entries) |entry| {
            self.allocator.free(entry.path);
        }
        self.allocator.free(result.entries);
    }

    fn runPorcelain(self: *Status, result: status_mod.StatusResult) !void {
        for (result.entries) |entry| {
            const code = switch (entry.status) {
                .unmodified => " ",
                .modified => "M",
                .added => "A",
                .deleted => "D",
                .renamed => "R",
                .copied => "C",
                .untracked => "?",
                .ignored => "I",
                .conflicted => "U",
            };
            try self.output.writer.print(" {s} {s}\n", .{ code, entry.path });
        }
        if (!result.has_changes) {
            try self.output.result(.{ .success = true, .code = 0, .message = "Working tree clean" });
        }
    }

    fn runShort(self: *Status, result: status_mod.StatusResult) !void {
        try self.runPorcelain(result);
    }

    fn runLong(self: *Status, result: status_mod.StatusResult) !void {
        var staged: usize = 0;
        var unstaged: usize = 0;
        var untracked: usize = 0;

        for (result.entries) |entry| {
            switch (entry.status) {
                .added, .modified, .deleted, .renamed, .copied => unstaged += 1,
                .untracked => untracked += 1,
                else => staged += 1,
            }
        }

        try self.output.section("Status");

        if (unstaged > 0) {
            try self.output.item("Changes not staged", "");
            for (result.entries) |entry| {
                switch (entry.status) {
                    .modified => try self.output.writer.print("  modified: {s}\n", .{entry.path}),
                    .added => try self.output.writer.print("  new file: {s}\n", .{entry.path}),
                    .deleted => try self.output.writer.print("  deleted: {s}\n", .{entry.path}),
                    else => {},
                }
            }
        }

        if (untracked > 0) {
            try self.output.item("Untracked files", "");
            for (result.entries) |entry| {
                if (entry.status == .untracked) {
                    try self.output.writer.print("  {s}\n", .{entry.path});
                }
            }
        }

        if (unstaged == 0 and untracked == 0) {
            try self.output.result(.{ .success = true, .code = 0, .message = "Working tree clean" });
        }

        try self.output.hint("Run 'hoz add <file>' to stage changes", .{});
    }
};
