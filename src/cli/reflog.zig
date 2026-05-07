//! Git Reflog - Show reference logs
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const ReflogManager = @import("../ref/reflog.zig").ReflogManager;
const ReflogEntry = @import("../ref/reflog.zig").ReflogEntry;
const OID = @import("../object/oid.zig").OID;

pub const Reflog = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    ref_name: []const u8,
    max_count: ?usize,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Reflog {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .ref_name = "HEAD",
            .max_count = null,
        };
    }

    pub fn run(self: *Reflog, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not in a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        try self.showReflog(git_dir);
    }

    fn parseArgs(self: *Reflog, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--max-count")) {
                continue;
            } else if (std.mem.startsWith(u8, arg, "-n=") or std.mem.startsWith(u8, arg, "--max-count=")) {
                const val = if (std.mem.startsWith(u8, arg, "-n="))
                    arg[3..]
                else
                    arg[12..];
                self.max_count = std.fmt.parseInt(usize, val, 10) catch null;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.ref_name = arg;
            }
        }
    }

    fn showReflog(self: *Reflog, git_dir: Io.Dir) !void {
        var reflog_manager = ReflogManager.initWithIo(git_dir, self.io, self.allocator);
        const entries = reflog_manager.read(self.ref_name) catch {
            try self.output.infoMessage("No reflog entries for {s}", .{self.ref_name});
            return;
        };
        defer self.allocator.free(entries);

        if (entries.len == 0) {
            try self.output.infoMessage("No reflog entries for {s}", .{self.ref_name});
            return;
        }

        try self.output.section("Reflog");

        const count = if (self.max_count) |c| @min(c, entries.len) else entries.len;
        const start = entries.len - count;

        for (entries[start..], start..) |entry, i| {
            const short_oid = entry.new_oid.toHex();
            const short_msg = if (entry.message.len > 50) entry.message[0..50] else entry.message;

            try self.output.writer.print("{d: >4} {s} {s} <{s}>: {s}\n", .{
                entries.len - i,
                short_oid[0..7],
                entry.committer.name,
                entry.committer.email,
                short_msg,
            });
        }

        try self.output.successMessage("{d} reflog entries", .{count});
    }
};

test "Reflog init" {
    const reflog = Reflog.init(std.testing.allocator, undefined, undefined, .{});
    try std.testing.expect(std.mem.eql(u8, reflog.ref_name, "HEAD"));
    try std.testing.expect(reflog.max_count == null);
}

test "Reflog parseArgs sets ref_name" {
    var reflog = Reflog.init(std.testing.allocator, undefined, undefined, .{});
    reflog.parseArgs(&.{ "main", "-n", "5" });
    try std.testing.expect(std.mem.eql(u8, reflog.ref_name, "main"));
}
