//! Git Fetch - Fetch updates from a remote
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const network = @import("../network/network.zig");
const transport = @import("../network/transport.zig");
const config_reader = @import("../config/read_write.zig");
const workdir = @import("../workdir/workdir.zig");
const refspec_mod = @import("../remote/refspec.zig");
const prune_mod = @import("../network/prune.zig");
const pack_recv = @import("../network/pack_recv.zig");

pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    prune: bool,
    tags: bool,
    all: bool,
    multiple: bool,
    force: bool,
    depth: u32,
    output: Output,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Fetch {
        return .{
            .allocator = allocator,
            .io = io,
            .prune = false,
            .tags = false,
            .all = false,
            .multiple = false,
            .force = false,
            .depth = 0,
            .output = Output.init(writer, style, allocator),
        };
    }

    pub fn run(self: *Fetch, remote_name: []const u8, refspec_input: ?[]const u8) !void {
        const repo = findRepository(self.io) catch |err| {
            try self.output.errorMessage("Not in a git repository: {}", .{err});
            return;
        };
        defer {
            self.allocator.free(repo.git_dir);
            self.allocator.free(repo.working_dir);
        }

        const remote_url = try getRemoteUrl(self.allocator, self.io, repo.git_dir, remote_name);
        const url = remote_url orelse {
            try self.output.errorMessage("Remote '{s}' not found", .{remote_name});
            return;
        };
        defer self.allocator.free(url);

        var t = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try t.connect();
        defer t.disconnect();

        const refs = try t.fetchRefs();
        defer self.allocator.free(refs);

        if (refs.len == 0) {
            try self.output.errorMessage("No refs found on remote", .{});
            return;
        }

        var want_oids = std.ArrayList([]const u8).initCapacity(self.allocator, refs.len) catch |err| return err;
        defer {
            for (want_oids.items) |oid| self.allocator.free(oid);
            want_oids.deinit(self.allocator);
        }

        for (refs) |ref| {
            const oid_copy = try self.allocator.dupe(u8, ref.oid);
            try want_oids.append(self.allocator, oid_copy);
        }

        const pack_data = try t.fetchPack(want_oids.items, &.{});
        defer self.allocator.free(pack_data);

        var receiver = pack_recv.PackReceiver.init(self.allocator, .{});
        _ = try receiver.receiveAndStore(self.io, self.allocator, repo.git_dir, pack_data);

        var parser = refspec_mod.RefspecParser.init(self.allocator);
        defer parser.deinit();

        const resolved_refs = refs;
        if (refspec_input) |input| {
            const parsed = try parser.parse(input);
            var ref_names_list = std.ArrayList([]const u8).initCapacity(self.allocator, refs.len) catch |err| return err;
            for (refs) |ref| {
                try ref_names_list.append(self.allocator, ref.name);
            }
            const ref_names = try ref_names_list.toOwnedSlice(self.allocator);
            const expanded = try parser.expand(parsed, ref_names);
            for (expanded) |dst| {
                try self.output.successMessage("  {s} -> {s}", .{ parsed.source, dst });
            }
            for (refs) |ref| {
                try self.updateRef(repo.git_dir, ref.name, ref.oid);
            }
        } else {
            try self.output.successMessage("From {s}", .{url});
            for (resolved_refs) |ref| {
                try self.output.successMessage("  {s} {s}", .{ ref.oid, ref.name });
                try self.updateRef(repo.git_dir, ref.name, ref.oid);
            }
        }

        if (self.prune) {
            try self.pruneStaleRefs(repo.git_dir, remote_name, refs);
        }

        try self.output.successMessage("Fetch complete for {s}", .{remote_name});
    }

    fn findRepository(io: Io) !workdir.RepositoryLayout {
        return workdir.findRepositoryRoot(std.heap.c_allocator, io, ".");
    }

    fn getRemoteUrl(allocator: std.mem.Allocator, io: Io, git_dir: []const u8, remote_name: []const u8) !?[]const u8 {
        var reader = config_reader.ConfigReader.init(allocator);
        return reader.getRemoteUrl(io, git_dir, remote_name);
    }

    fn updateRef(self: *Fetch, git_dir: []const u8, ref_name: []const u8, oid: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const ref_path = try std.mem.concat(std.heap.c_allocator, u8, &.{ git_dir, "/", ref_name });
        defer std.heap.c_allocator.free(ref_path);

        const parent = std.fs.path.dirname(ref_path);
        if (parent) |p| {
            cwd.createDirPath(self.io, p) catch {};
        }

        const data = try std.fmt.allocPrint(std.heap.c_allocator, "{s}\n", .{oid});
        defer std.heap.c_allocator.free(data);
        try cwd.writeFile(self.io, .{ .sub_path = ref_path, .data = data });
    }

    fn pruneStaleRefs(self: *Fetch, git_dir: []const u8, remote_name: []const u8, remote_refs: []const network.refs.RemoteRef) !void {
        var ref_names = std.ArrayList([]const u8).initCapacity(self.allocator, remote_refs.len) catch |err| return err;
        defer {
            for (ref_names.items) |ref| self.allocator.free(ref);
            ref_names.deinit(self.allocator);
        }
        for (remote_refs) |ref| {
            try ref_names.append(self.allocator, ref.name);
        }
        const pruned = try prune_mod.pruneStaleRefs(self.allocator, self.io, git_dir, remote_name, ref_names.items);
        if (pruned > 0) {
            try self.output.successMessage("Pruned {d} stale remote tracking branch(es)", .{pruned});
        }
    }

    pub fn runAll(self: *Fetch) !void {
        self.all = true;
        try self.output.successMessage("Fetching from all remotes", .{});
    }

    pub fn runPrune(self: *Fetch, remote: []const u8) !void {
        _ = remote;
        self.prune = true;
        try self.output.successMessage("Fetching and pruning stale remote tracking branches", .{});
    }
};

pub const FetchOptions = struct {
    prune: bool = false,
    tags: bool = false,
    depth: u32 = 0,
    force: bool = false,
};

pub fn parseFetchArgs(args: []const []const u8) struct { remote: ?[]const u8, refspec: ?[]const u8, options: FetchOptions } {
    var remote: ?[]const u8 = null;
    var refspec: ?[]const u8 = null;
    var options = FetchOptions{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-p")) {
            options.prune = true;
        } else if (std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "-t")) {
            options.tags = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            options.force = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote == null) {
            remote = arg;
        } else if (!std.mem.startsWith(u8, arg, "-") and remote != null and refspec == null) {
            refspec = arg;
        }
    }

    return .{
        .remote = remote,
        .refspec = refspec,
        .options = options,
    };
}

test "Fetch init" {
    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    const io = std.Io.Threaded.new(.{}).?;
    const fetch = Fetch.init(std.testing.allocator, io, &writer.interface, .{});
    try std.testing.expect(fetch.prune == false);
    try std.testing.expect(fetch.tags == false);
}

test "FetchOptions default" {
    const options = FetchOptions{};
    try std.testing.expect(options.prune == false);
    try std.testing.expect(options.tags == false);
    try std.testing.expect(options.depth == 0);
}

test "parseFetchArgs basic" {
    const result = parseFetchArgs(&.{"origin"});
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expect(result.refspec == null);
}

test "parseFetchArgs with refspec" {
    const result = parseFetchArgs(&.{ "origin", "main" });
    try std.testing.expectEqualStrings("origin", result.remote);
    try std.testing.expectEqualStrings("main", result.refspec);
}

test "parseFetchArgs with prune" {
    const result = parseFetchArgs(&.{ "--prune", "origin" });
    try std.testing.expect(result.options.prune == true);
}
