const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const OID = @import("../object/oid.zig").OID;
const RefStore = @import("../ref/store.zig").RefStore;
const Ref = @import("../ref/ref.zig").Ref;
const head_mod = @import("../commit/head.zig");

pub const NameRevOptions = struct {
    all: bool = false,
    tags: bool = false,
    abbrev: usize = 0,
    name_only: bool = false,
    no_undefined: bool = false,
};

pub const NameRev = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: NameRevOptions,
    oids: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) NameRev {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .oids = &.{},
        };
    }

    pub fn run(self: *NameRev, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const ref_store = RefStore.init(git_dir, self.allocator, self.io);
        const all_refs = ref_store.list("refs/") catch &.{};
        defer self.allocator.free(all_refs);

        if (self.options.all) {
            const head_oid = resolveHead(&git_dir, self.allocator, self.io);
            if (head_oid) |oid| {
                const hex = oid.toHex();
                const name = self.findBestName(all_refs, oid);
                if (self.options.name_only) {
                    try self.output.writer.print("{s}\n", .{name});
                } else {
                    try self.output.writer.print("{s} {s}\n", .{ &hex, name });
                }
            }
        }

        if (self.oids.len == 0 and !self.options.all) {
            if (!self.options.no_undefined) {
                try self.output.infoMessage("--→ No OIDs provided", .{});
            }
            return;
        }

        for (self.oids) |oid_str| {
            const oid = OID.fromHex(oid_str) catch {
                if (!self.options.no_undefined) {
                    try self.output.errorMessage("Cannot parse OID: {s}", .{oid_str});
                }
                continue;
            };

            const hex = oid.toHex();
            const name = self.findBestName(all_refs, oid);

            if (self.options.name_only) {
                try self.output.writer.print("{s}\n", .{name});
            } else {
                try self.output.writer.print("{s} {s}\n", .{ &hex, name });
            }
        }
    }

    fn findBestName(self: *NameRev, all_refs: []const Ref, target: OID) []const u8 {
        var best_name: []const u8 = "undefined";
        var best_len: usize = 9999;

        for (all_refs) |ref| {
            if (ref.isDirect()) {
                if (ref.target.direct.eql(target)) {
                    const display = @This().refToDisplayName(ref.name);
                    if (display.len < best_len) {
                        best_name = display;
                        best_len = display.len;
                    }
                }
            }
        }

        if (std.mem.eql(u8, best_name, "undefined")) {
            const short = target.short(if (self.options.abbrev > 0) self.options.abbrev else 7);
            best_name = &short;
        }

        return best_name;
    }

    fn refToDisplayName(ref_name: []const u8) []const u8 {
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            return ref_name["refs/heads/".len..];
        }
        if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
            return ref_name["refs/tags/".len..];
        }
        if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
            return ref_name["refs/remotes/".len..];
        }
        return ref_name;
    }

    fn resolveHead(git_dir: *const Io.Dir, allocator: std.mem.Allocator, io: Io) ?OID {
        return head_mod.resolveHeadOid(git_dir, io, allocator);
    }

    fn parseArgs(self: *NameRev, args: []const []const u8) void {
        var oid_list = std.ArrayList([]const u8).initCapacity(self.allocator, args.len) catch return;
        defer {
            const needs_deinit = oid_list.items.ptr != self.oids.ptr;
            if (needs_deinit) {
                oid_list.deinit(self.allocator);
            }
        }

        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
                self.options.all = true;
            } else if (std.mem.eql(u8, arg, "--tags")) {
                self.options.tags = true;
            } else if (std.mem.eql(u8, arg, "--name-only")) {
                self.options.name_only = true;
            } else if (std.mem.eql(u8, arg, "--no-undefined")) {
                self.options.no_undefined = true;
            } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
                const val = arg["--abbrev=".len..];
                self.options.abbrev = std.fmt.parseInt(usize, val, 10) catch 0;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                oid_list.append(self.allocator, arg) catch {};
            }
        }

        if (oid_list.items.len > 0) {
            self.oids = oid_list.toOwnedSlice(self.allocator) catch &.{};
        }
    }
};
