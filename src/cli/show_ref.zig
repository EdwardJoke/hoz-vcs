const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;

pub const ShowRefOptions = struct {
    heads: bool = false,
    tags: bool = false,
    hash: bool = true,
    verify: bool = false,
    abbrev: usize = 0,
};

pub const ShowRef = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: ShowRefOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) ShowRef {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *ShowRef, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.options.verify) {
            if (args.len == 0) {
                try self.output.errorMessage("Nothing to verify", .{});
                return;
            }
            for (args) |arg| {
                if (std.mem.startsWith(u8, arg, "-")) continue;
                _ = OID.fromHex(arg) catch {
                    try self.output.errorMessage("fatal: '{s}' - not a valid OID", .{arg});
                    return;
                };
            }
            return;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const ref_store = RefStore.init(git_dir, self.allocator, self.io);
        const refs = ref_store.list("refs/") catch {
            try self.output.errorMessage("Failed to list refs", .{});
            return;
        };
        defer {
            for (refs) |ref| {
                self.allocator.free(ref.name);
            }
            self.allocator.free(refs);
        }

        for (refs) |ref| {
            if (self.options.heads and !std.mem.startsWith(u8, ref.name, "refs/heads/")) continue;
            if (self.options.tags and !std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;

            if (ref.isDirect()) {
                const hex = ref.target.direct.toHex();
                try self.output.writer.print("{s} {s}\n", .{ &hex, ref.name });
            } else {
                const resolved = ref_store.resolve(ref.name) catch {
                    try self.output.writer.print("{s} {s}\n", .{ "0000000000000000000000000000000000000000", ref.name });
                    continue;
                };
                if (resolved.isDirect()) {
                    const hex = resolved.target.direct.toHex();
                    try self.output.writer.print("{s} {s}\n", .{ &hex, ref.name });
                }
            }
        }

        const head_content = git_dir.readFileAlloc(self.io, "HEAD", self.allocator, .limited(256)) catch "";
        if (head_content.len > 0) {
            const trimmed = std.mem.trim(u8, head_content, "\r\n");
            if (!std.mem.startsWith(u8, trimmed, "ref: ")) {
                const oid = OID.fromHex(trimmed) catch return;
                const hex = oid.toHex();
                try self.output.writer.print("{s} HEAD\n", .{&hex});
            }
        }
    }

    fn parseArgs(self: *ShowRef, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--heads")) {
                self.options.heads = true;
            } else if (std.mem.eql(u8, arg, "--tags")) {
                self.options.tags = true;
            } else if (std.mem.eql(u8, arg, "--verify") or std.mem.eql(u8, arg, "-v")) {
                self.options.verify = true;
            } else if (std.mem.eql(u8, arg, "--hash") or std.mem.eql(u8, arg, "-h")) {
                self.options.hash = true;
            }
        }
    }
};
