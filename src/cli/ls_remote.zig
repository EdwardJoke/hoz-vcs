//! Git LS-Remote - List remote refs
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const transport = @import("../network/transport.zig");

pub const LsRemote = struct {
    allocator: std.mem.Allocator,
    io: Io,
    heads: bool,
    tags: bool,
    refs: bool,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) LsRemote {
        return .{
            .allocator = allocator,
            .io = io,
            .heads = false,
            .tags = false,
            .refs = false,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *LsRemote, remote: ?[]const u8) !void {
        if (remote) |r| {
            try self.runRemote(r);
        } else {
            try self.output.errorMessage("Usage: hoz ls-remote <remote>", .{});
        }
    }

    fn runRemote(self: *LsRemote, remote_url: []const u8) !void {
        var t = transport.Transport.init(self.allocator, self.io, .{ .url = remote_url });
        try t.connect();
        defer t.disconnect();

        const all_refs = try t.fetchRefs();
        defer self.allocator.free(all_refs);

        if (all_refs.len == 0) {
            try self.output.infoMessage("No refs found on {s}", .{remote_url});
            return;
        }

        var shown: usize = 0;
        for (all_refs) |ref| {
            if (!self.shouldShowRef(ref.name)) continue;

            if (self.styleIsHuman()) {
                try self.output.writer.print("{s}\t{s}\n", .{ ref.oid, ref.name });
            } else {
                try self.output.writer.print("{s} {s}\n", .{ ref.oid, ref.name });
            }

            if (ref.peeled) |peeled_oid| {
                if (self.styleIsHuman()) {
                    try self.output.writer.print("{s}\t{s}^{{}}\n", .{ peeled_oid, ref.name });
                } else {
                    try self.output.writer.print("{s} {s}^{{}}\n", .{ peeled_oid, ref.name });
                }
            }

            shown += 1;
        }

        if (shown == 0 and (self.heads or self.tags)) {
            try self.output.infoMessage("No matching refs found for the given filter on {s}", .{remote_url});
        }
    }

    fn shouldShowRef(self: *LsRemote, ref_name: []const u8) bool {
        const is_head = std.mem.startsWith(u8, ref_name, "refs/heads/");
        const is_tag = std.mem.startsWith(u8, ref_name, "refs/tags/");
        const is_peeled = std.mem.endsWith(u8, ref_name, "^{}");

        if (is_peeled) return false;

        if (self.heads and !self.tags and !self.refs) {
            return is_head;
        }
        if (self.tags and !self.heads and !self.refs) {
            return is_tag;
        }
        if (self.refs) {
            return true;
        }

        return true;
    }

    fn styleIsHuman(self: *LsRemote) bool {
        return self.output.style.format == .human;
    }
};

pub const LsRemoteOptions = struct {
    heads: bool = false,
    tags: bool = false,
    refs: bool = false,
};

pub fn parseLsRemoteArgs(args: []const []const u8) struct { remote: ?[]const u8, options: LsRemoteOptions } {
    var remote: ?[]const u8 = null;
    var options = LsRemoteOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--heads") or std.mem.eql(u8, arg, "-h")) {
            options.heads = true;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            options.tags = true;
        } else if (std.mem.eql(u8, arg, "--refs")) {
            options.refs = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            remote = arg;
        }
    }

    return .{
        .remote = remote,
        .options = options,
    };
}

test "LsRemote init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const ls = LsRemote.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(ls.heads == false);
    try std.testing.expect(ls.tags == false);
}

test "LsRemoteOptions default" {
    const options = LsRemoteOptions{};
    try std.testing.expect(options.heads == false);
    try std.testing.expect(options.tags == false);
}

test "parseLsRemoteArgs basic" {
    const result = parseLsRemoteArgs(&.{"origin"});
    try std.testing.expectEqualStrings("origin", result.remote);
}
