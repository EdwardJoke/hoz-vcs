const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const TagVerifier = @import("../tag/verify.zig").TagVerifier;
const TagVerifyResult = @import("../tag/verify.zig").TagVerifyResult;
const OID = @import("../object/oid.zig").OID;

pub const VerifyTagOptions = struct {
    verbose: bool = false,
    raw: bool = false,
};

pub const VerifyTag = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: VerifyTagOptions,
    tags: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) VerifyTag {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .tags = &.{},
        };
    }

    pub fn run(self: *VerifyTag, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.tags.len == 0) {
            try self.output.errorMessage("error: no tag specified", .{});
            return;
        }

        var any_error = false;
        for (self.tags) |tag_name| {
            const result = self.verifyOne(tag_name) catch {
                try self.output.errorMessage("fatal: could not verify '{s}'", .{tag_name});
                any_error = true;
                continue;
            };

            if (!result.valid) {
                try self.output.errorMessage("error: tag '{s}' is not valid", .{tag_name});
                any_error = true;
                continue;
            }

            if (self.options.raw) {
                if (result.tagger.len > 0) {
                    try self.output.writer.print("{s}\n", .{result.tagger});
                    try self.output.writer.print("{s}\n", .{result.message});
                }
            } else {
                try self.output.infoMessage("--→ tag '{s}' verified OK", .{tag_name});

                if (self.options.verbose and result.tagger.len > 0) {
                    try self.output.writer.print("  Tagger: {s}\n", .{result.tagger});
                    if (result.message.len > 0) {
                        try self.output.writer.print("  Message:\n{s}\n", .{result.message});
                    }
                }
            }

            self.allocator.free(result.tagger);
            self.allocator.free(result.message);
        }

        if (any_error) return error.VerificationFailed;
    }

    fn verifyOne(self: *VerifyTag, tag_name: []const u8) !TagVerifyResult {
        var verifier = TagVerifier.init(self.allocator, self.io);
        return verifier.verify(tag_name);
    }

    fn parseArgs(self: *VerifyTag, args: []const []const u8) void {
        var tag_list = std.ArrayList([]const u8).initCapacity(self.allocator, args.len) catch return;
        defer tag_list.deinit(self.allocator);

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                self.options.verbose = true;
            } else if (std.mem.eql(u8, arg, "--raw")) {
                self.options.raw = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                tag_list.append(self.allocator, arg) catch {};
            }
        }

        if (tag_list.items.len > 0) {
            self.tags = tag_list.toOwnedSlice(self.allocator) catch &.{};
        }
    }
};
