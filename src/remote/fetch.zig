//! Fetch - Fetch from remote repository
const std = @import("std");
const Io = std.Io;

const config_mod = @import("../config/read_write.zig");
const transport = @import("../network/transport.zig");
const refs = @import("../network/refs.zig");
const pack_recv = @import("../network/pack_recv.zig");

pub const FetchOptions = struct {
    remote: []const u8 = "origin",
    refspecs: []const []const u8 = &.{},
    prune: enum { no, all, matching } = .no,
    depth: u32 = 0,
    unshallow: bool = false,
};

pub const FetchResult = struct {
    success: bool,
    heads_updated: u32,
    tags_updated: u32,
};

pub const FetchFetcher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir_path: []const u8,
    options: FetchOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir_path: []const u8, options: FetchOptions) FetchFetcher {
        return .{ .allocator = allocator, .io = io, .git_dir_path = git_dir_path, .options = options };
    }

    pub fn fetch(self: *FetchFetcher) !FetchResult {
        const url = self.resolveRemoteUrl() catch |err| {
            if (err == error.FileNotFound) return FetchResult{ .success = false, .heads_updated = 0, .tags_updated = 0 };
            return err;
        };
        defer self.allocator.free(url);

        var tport = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try tport.connect();
        defer tport.disconnect();

        try tport.fillCredentials();

        const remote_refs = tport.fetchRefs() catch {
            return FetchResult{ .success = false, .heads_updated = 0, .tags_updated = 0 };
        };
        defer self.allocator.free(remote_refs);

        var wants = std.ArrayList([]const u8).initCapacity(self.allocator, remote_refs.len) catch |e| return e;
        defer {
            for (wants.items) |w| self.allocator.free(w);
            wants.deinit(self.allocator);
        }
        var haves = std.ArrayList([]const u8).empty;
        defer haves.deinit(self.allocator);

        var heads_updated: u32 = 0;
        var tags_updated: u32 = 0;

        for (remote_refs) |rref| {
            const local_ref_name = self.mapRemoteRefToLocal(rref.name);
            defer self.allocator.free(local_ref_name);

            const local_oid = self.readLocalRef(local_ref_name);
            const want_new = local_oid == null or !std.mem.eql(u8, local_oid.?, rref.oid);

            if (!std.mem.startsWith(u8, rref.name, "refs/tags/")) {
                if (want_new) heads_updated += 1;
            } else {
                if (want_new) tags_updated += 1;
            }

            if (want_new) {
                try wants.append(self.allocator, rref.oid);
            } else {
                try haves.append(self.allocator, rref.oid);
            }
        }

        if (wants.items.len > 0) {
            const pack_data = tport.fetchPack(wants.items, haves.items) catch {
                return FetchResult{
                    .success = true,
                    .heads_updated = heads_updated,
                    .tags_updated = tags_updated,
                };
            };
            defer self.allocator.free(pack_data);

            var receiver = pack_recv.PackReceiver.init(self.allocator, .{});
            _ = receiver.receiveAndStore(self.io, self.allocator, ".git", pack_data) catch 0;
            receiver.deinit();
        }

        for (remote_refs) |rref| {
            const local_ref_name = self.mapRemoteRefToLocal(rref.name);
            defer self.allocator.free(local_ref_name);
            self.updateLocalRef(local_ref_name, rref.oid) catch {};
        }

        return FetchResult{
            .success = true,
            .heads_updated = heads_updated,
            .tags_updated = tags_updated,
        };
    }

    pub fn fetchRefspec(self: *FetchFetcher, refspec: []const u8) !FetchResult {
        const url = self.resolveRemoteUrl() catch |err| {
            if (err == error.FileNotFound) return FetchResult{ .success = false, .heads_updated = 0, .tags_updated = 0 };
            return err;
        };
        defer self.allocator.free(url);

        var tport = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try tport.connect();
        defer tport.disconnect();

        try tport.fillCredentials();

        const remote_refs = tport.fetchRefs() catch {
            return FetchResult{ .success = false, .heads_updated = 0, .tags_updated = 0 };
        };
        defer self.allocator.free(remote_refs);

        const colon_idx = std.mem.indexOf(u8, refspec, ":") orelse refspec.len;
        const src_pattern = refspec[0..colon_idx];
        const dst_pattern = if (colon_idx < refspec.len) refspec[colon_idx + 1 ..] else src_pattern;

        var wants = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch |e| return e;
        defer {
            for (wants.items) |w| self.allocator.free(w);
            wants.deinit(self.allocator);
        }
        var haves = std.ArrayList([]const u8).empty;
        defer haves.deinit(self.allocator);

        var matched: u32 = 0;

        for (remote_refs) |rref| {
            if (!self.refMatches(src_pattern, rref.name)) continue;

            const local_name = if (dst_pattern.len > 0 and !std.mem.eql(u8, dst_pattern, src_pattern))
                self.expandRefPattern(dst_pattern, rref.name)
            else
                try self.allocator.dupe(u8, rref.name);
            defer self.allocator.free(local_name);

            const local_oid = self.readLocalRef(local_name);
            if (local_oid == null or !std.mem.eql(u8, local_oid.?, rref.oid)) {
                try wants.append(self.allocator, rref.oid);
                matched += 1;
            } else {
                try haves.append(self.allocator, rref.oid);
            }
        }

        if (wants.items.len > 0) {
            const pack_data = tport.fetchPack(wants.items, haves.items) catch {
                return FetchResult{ .success = true, .heads_updated = matched, .tags_updated = 0 };
            };
            defer self.allocator.free(pack_data);

            var receiver = pack_recv.PackReceiver.init(self.allocator, .{});
            _ = receiver.receiveAndStore(self.io, self.allocator, ".git", pack_data) catch 0;
            receiver.deinit();
        }

        for (remote_refs) |rref| {
            if (!self.refMatches(src_pattern, rref.name)) continue;
            const local_name = if (dst_pattern.len > 0 and !std.mem.eql(u8, dst_pattern, src_pattern))
                self.expandRefPattern(dst_pattern, rref.name)
            else
                try self.allocator.dupe(u8, rref.name);
            defer self.allocator.free(local_name);
            self.updateLocalRef(local_name, rref.oid) catch {};
        }

        return FetchResult{ .success = true, .heads_updated = matched, .tags_updated = 0 };
    }

    fn resolveRemoteUrl(self: *FetchFetcher) ![]u8 {
        var reader = config_mod.ConfigReader.init(self.allocator);
        const url = (try reader.getRemoteUrl(self.io, ".git", self.options.remote)) orelse return error.FileNotFound;
        return @constCast(url);
    }

    fn mapRemoteRefToLocal(self: *FetchFetcher, remote_ref: []const u8) []u8 {
        if (std.mem.startsWith(u8, remote_ref, "refs/heads/")) {
            const branch = remote_ref["refs/heads/".len..];
            return std.fmt.allocPrint(self.allocator, "refs/remotes/{s}/{s}", .{ self.options.remote, branch }) catch unreachable;
        }
        if (std.mem.startsWith(u8, remote_ref, "refs/tags/")) {
            return std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{remote_ref["refs/tags/".len..]}) catch unreachable;
        }
        return self.allocator.dupe(u8, remote_ref) catch unreachable;
    }

    fn readLocalRef(self: *FetchFetcher, ref_path: []const u8) ?[]const u8 {
        const git_dir = Io.Dir.openDirAbsolute(self.io, self.git_dir_path, .{}) catch return null;
        const content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return null;
        defer self.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \n\r\t");
        if (trimmed.len >= 40) return trimmed[0..40];
        return null;
    }

    fn updateLocalRef(self: *FetchFetcher, ref_path: []const u8, oid_hex: []const u8) !void {
        const git_dir = Io.Dir.openDirAbsolute(self.io, self.git_dir_path, .{}) catch return;
        const parent = std.fs.path.dirname(ref_path);
        if (parent) |p| {
            git_dir.createDirPath(self.io, p) catch {};
        }
        const data = try std.fmt.allocPrint(self.allocator, "{s}\n", .{oid_hex});
        defer self.allocator.free(data);
        git_dir.writeFile(self.io, .{ .sub_path = ref_path, .data = data }) catch {};
    }

    fn refMatches(_: *FetchFetcher, pattern: []const u8, ref_name: []const u8) bool {
        if (std.mem.indexOf(u8, pattern, "*") == null) {
            return std.mem.eql(u8, pattern, ref_name);
        }
        const star_idx = std.mem.indexOf(u8, pattern, "*").?;
        const prefix = pattern[0..star_idx];
        const suffix = pattern[star_idx + 1 ..];
        if (suffix.len == 0) return std.mem.startsWith(u8, ref_name, prefix);
        return std.mem.startsWith(u8, ref_name, prefix) and std.mem.endsWith(u8, ref_name, suffix);
    }

    fn expandRefPattern(self: *FetchFetcher, pattern: []const u8, source_ref: []const u8) []u8 {
        const star_idx = std.mem.indexOf(u8, pattern, "*") orelse return self.allocator.dupe(u8, pattern) catch unreachable;
        const star_src = std.mem.indexOf(u8, "refs/heads/", source_ref) orelse source_ref.len;
        const tail = if (star_src < source_ref.len) source_ref[star_src + "refs/heads/".len ..] else "";
        const result = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            pattern[0..star_idx],
            tail,
            pattern[star_idx + 1 ..],
        }) catch unreachable;
        return result;
    }
};

test "FetchOptions default values" {
    const options = FetchOptions{};
    try std.testing.expectEqualStrings("origin", options.remote);
    try std.testing.expect(options.prune == .no);
    try std.testing.expect(options.depth == 0);
}

test "FetchResult structure" {
    const result = FetchResult{ .success = true, .heads_updated = 5, .tags_updated = 2 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.heads_updated == 5);
}

test "FetchFetcher init" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    const options = FetchOptions{};
    const fetcher = FetchFetcher.init(gpa.allocator(), io, ".git", options);
    try std.testing.expect(fetcher.allocator == gpa.allocator());
}

test "FetchFetcher init with options" {
    var options = FetchOptions{};
    options.prune = .all;
    options.depth = 100;
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    const fetcher = FetchFetcher.init(gpa.allocator(), io, ".git", options);
    try std.testing.expect(fetcher.options.prune == .all);
}

test "refMatches exact" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var fetcher = FetchFetcher.init(gpa.allocator(), io, ".git", .{});
    try std.testing.expect(fetcher.refMatches("refs/heads/main", "refs/heads/main") == true);
    try std.testing.expect(fetcher.refMatches("refs/heads/main", "refs/heads/dev") == false);
}

test "refMatches glob" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var fetcher = FetchFetcher.init(gpa.allocator(), io, ".git", .{});
    try std.testing.expect(fetcher.refMatches("refs/heads/*", "refs/heads/main") == true);
    try std.testing.expect(fetcher.refMatches("refs/heads/*", "refs/heads/feature/x") == true);
    try std.testing.expect(fetcher.refMatches("refs/heads/*", "refs/tags/v1") == false);
}
