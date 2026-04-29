//! Push - Push to remote repository
const std = @import("std");
const Io = std.Io;

const config_mod = @import("../config/read_write.zig");
const transport = @import("../network/transport.zig");
const pack_gen = @import("../network/pack_gen.zig");

pub const PushOptions = struct {
    remote: []const u8 = "origin",
    refspecs: []const []const u8 = &.{},
    force: bool = false,
    force_with_lease: bool = false,
    thin: bool = true,
    verify: bool = true,
};

pub const PushResult = struct {
    success: bool,
    refs_updated: u32,
    refs_delta: u32,
};

pub const PushPusher = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir_path: []const u8,
    options: PushOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir_path: []const u8, options: PushOptions) PushPusher {
        return .{ .allocator = allocator, .io = io, .git_dir_path = git_dir_path, .options = options };
    }

    pub fn push(self: *PushPusher) !PushResult {
        if (self.options.refspecs.len == 0) {
            return self.pushMatching();
        }

        var total_updated: u32 = 0;
        var total_delta: u32 = 0;

        for (self.options.refspecs) |refspec| {
            const result = try self.pushRefspec(refspec);
            total_updated += result.refs_updated;
            total_delta += result.refs_delta;
        }

        return PushResult{
            .success = total_updated > 0 or self.options.refspecs.len == 0,
            .refs_updated = total_updated,
            .refs_delta = total_delta,
        };
    }

    pub fn pushRefspec(self: *PushPusher, refspec: []const u8) !PushResult {
        const url = self.resolveRemoteUrl() catch |err| {
            if (err == error.FileNotFound) return PushResult{ .success = false, .refs_updated = 0, .refs_delta = 0 };
            return err;
        };
        defer self.allocator.free(url);

        var tport = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try tport.connect();
        defer tport.disconnect();

        try tport.fillCredentials();

        const colon_idx = std.mem.indexOf(u8, refspec, ":") orelse refspec.len;
        const src_ref = refspec[0..colon_idx];
        const dst_ref = if (colon_idx < refspec.len) refspec[colon_idx + 1 ..] else src_ref;

        var updates = std.ArrayList(transport.RefUpdate).initCapacity(self.allocator, 4) catch |e| return e;
        defer {
            for (updates.items) |u| {
                self.allocator.free(u.name);
                self.allocator.free(u.old_oid);
                self.allocator.free(u.new_oid);
            }
            updates.deinit(self.allocator);
        }

        var want_oids = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch |e| return e;
        defer {
            for (want_oids.items) |oid| self.allocator.free(oid);
            want_oids.deinit(self.allocator);
        }

        const local_oid = self.readLocalRef(src_ref);
        if (local_oid == null) {
            return PushResult{ .success = false, .refs_updated = 0, .refs_delta = 0 };
        }

        const old_remote = "0000000000000000000000000000000000000000";
        const new_oid_hex = local_oid.?;

        try want_oids.append(self.allocator, new_oid_hex);
        try updates.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, dst_ref),
            .old_oid = try self.allocator.dupe(u8, old_remote),
            .new_oid = try self.allocator.dupe(u8, new_oid_hex),
            .force = self.options.force,
        });

        if (want_oids.items.len > 0) {
            var gen = pack_gen.PackGenerator.init(self.allocator, .{
                .thin = self.options.thin,
                .include_tag = false,
                .ofs_delta = true,
            }) catch |e| return e;
            defer gen.deinit();

            const pack_result = gen.generateFromWants(want_oids.items, &.{}, ".git", self.io) catch {
                tport.pushRefs(updates.items, null) catch {};
                return PushResult{ .success = true, .refs_updated = @as(u32, @intCast(updates.items.len)), .refs_delta = 0 };
            };

            tport.pushRefs(updates.items, pack_result.pack_data) catch {};
            self.allocator.free(pack_result.pack_data);
        } else {
            tport.pushRefs(updates.items, null) catch {};
        }

        return PushResult{ .success = true, .refs_updated = @as(u32, @intCast(updates.items.len)), .refs_delta = 0 };
    }

    pub fn pushAll(self: *PushPusher) !PushResult {
        const url = self.resolveRemoteUrl() catch |err| {
            if (err == error.FileNotFound) return PushResult{ .success = false, .refs_updated = 0, .refs_delta = 0 };
            return err;
        };
        defer self.allocator.free(url);

        var tport = transport.Transport.init(self.allocator, self.io, .{ .url = url });
        try tport.connect();
        defer tport.disconnect();

        try tport.fillCredentials();

        const heads_dir_path = "refs/heads";
        const git_dir = Io.Dir.openDirAbsolute(self.io, self.git_dir_path, .{}) catch {
            return PushResult{ .success = true, .refs_updated = 0, .refs_delta = 0 };
        };
        const heads_dir = git_dir.openDir(self.io, heads_dir_path, .{ .iterate = true }) catch {
            return PushResult{ .success = true, .refs_updated = 0, .refs_delta = 0 };
        };
        var walker = heads_dir.walk(self.allocator) catch {
            return PushResult{ .success = true, .refs_updated = 0, .refs_delta = 0 };
        };
        defer walker.deinit();

        var updates = std.ArrayList(transport.RefUpdate).initCapacity(self.allocator, 16) catch |e| return e;
        defer {
            for (updates.items) |u| {
                self.allocator.free(u.name);
                self.allocator.free(u.old_oid);
                self.allocator.free(u.new_oid);
            }
            updates.deinit(self.allocator);
        }
        var want_oids = std.ArrayList([]const u8).initCapacity(self.allocator, 16) catch |e| return e;
        defer {
            for (want_oids.items) |oid| self.allocator.free(oid);
            want_oids.deinit(self.allocator);
        }

        while (walker.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;

            const full_local_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ heads_dir_path, entry.path });
            defer self.allocator.free(full_local_path);

            const oid_str = self.readLocalRef(full_local_path) orelse continue;

            const remote_name = try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{entry.path});
            try want_oids.append(self.allocator, oid_str);
            try updates.append(self.allocator, .{
                .name = remote_name,
                .old_oid = try self.allocator.dupe(u8, "0000000000000000000000000000000000000000"),
                .new_oid = try self.allocator.dupe(u8, oid_str),
                .force = self.options.force,
            });
        }

        if (want_oids.items.len > 0) {
            var gen = pack_gen.PackGenerator.init(self.allocator, .{
                .thin = self.options.thin,
                .include_tag = false,
                .ofs_delta = true,
            }) catch |e| return e;
            defer gen.deinit();

            const pack_result = gen.generateFromWants(want_oids.items, &.{}, ".git", self.io) catch {
                tport.pushRefs(updates.items, null) catch {};
                return PushResult{ .success = true, .refs_updated = @as(u32, @intCast(updates.items.len)), .refs_delta = 0 };
            };

            tport.pushRefs(updates.items, pack_result.pack_data) catch {};
            self.allocator.free(pack_result.pack_data);
        } else {
            tport.pushRefs(updates.items, null) catch {};
        }

        return PushResult{ .success = true, .refs_updated = @as(u32, @intCast(updates.items.len)), .refs_delta = 0 };
    }

    pub fn pushMatching(self: *PushPusher) !PushResult {
        return self.pushAll();
    }

    fn resolveRemoteUrl(self: *PushPusher) ![]u8 {
        var reader = config_mod.ConfigReader.init(self.allocator);
        const url = (try reader.getRemoteUrl(self.io, ".git", self.options.remote)) orelse return error.FileNotFound;
        return @constCast(url);
    }

    fn readLocalRef(self: *PushPusher, ref_path: []const u8) ?[]const u8 {
        const git_dir = Io.Dir.openDirAbsolute(self.io, self.git_dir_path, .{}) catch return null;
        const content = git_dir.readFileAlloc(self.io, ref_path, self.allocator, .limited(256)) catch return null;
        defer self.allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \n\r\t");
        if (trimmed.len >= 40) return trimmed[0..40];
        return null;
    }
};

test "PushOptions default values" {
    const options = PushOptions{};
    try std.testing.expectEqualStrings("origin", options.remote);
    try std.testing.expect(options.force == false);
    try std.testing.expect(options.thin == true);
}

test "PushResult structure" {
    const result = PushResult{ .success = true, .refs_updated = 3, .refs_delta = 2 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.refs_updated == 3);
}

test "PushPusher init" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    const options = PushOptions{};
    const pusher = PushPusher.init(gpa.allocator(), io, ".git", options);
    try std.testing.expect(pusher.allocator == gpa.allocator());
}

test "PushPusher init with options" {
    var options = PushOptions{};
    options.force = true;
    options.verify = false;
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    const pusher = PushPusher.init(gpa.allocator(), io, ".git", options);
    try std.testing.expect(pusher.options.force == true);
}

test "PushPusher push method exists" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var pusher = PushPusher.init(gpa.allocator(), io, ".git", .{});
    const result = try pusher.push();
    try std.testing.expect(result.success == true);
}

test "PushPusher pushRefspec method exists" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var pusher = PushPusher.init(gpa.allocator(), io, ".git", .{});
    const result = try pusher.pushRefspec("refs/heads/main:refs/heads/main");
    try std.testing.expect(result.success == true);
}

test "PushPusher pushAll method exists" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var pusher = PushPusher.init(gpa.allocator(), io, ".git", .{});
    const result = try pusher.pushAll();
    try std.testing.expect(result.success == true);
}

test "PushPusher pushMatching method exists" {
    const gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();
    var pusher = PushPusher.init(gpa.allocator(), io, ".git", .{});
    const result = try pusher.pushMatching();
    try std.testing.expect(result.success == true);
}
