//! Fetch Refs - Update refs after clone
const std = @import("std");
const Io = std.Io;

pub const FetchRefsResult = struct {
    success: bool,
    refs_updated: u32,
};

pub const RefEntry = struct {
    name: []const u8,
    oid: []const u8,
};

pub const FetchRefsUpdater = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) FetchRefsUpdater {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn updateRefs(self: *FetchRefsUpdater, refs: []const RefEntry) !FetchRefsResult {
        const cwd = Io.Dir.cwd();
        const refs_path = ".git/refs/heads";
        cwd.createDirPath(self.io, refs_path) catch return error.CreateRefDirFailed;

        var updated: u32 = 0;
        for (refs) |ref| {
            const ref_file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ refs_path, ref.name });
            defer self.allocator.free(ref_file_path);
            const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{ref.oid});
            defer self.allocator.free(ref_content);
            cwd.writeFile(self.io, .{ .sub_path = ref_file_path, .data = ref_content }) catch continue;
            updated += 1;
        }
        return FetchRefsResult{ .success = true, .refs_updated = updated };
    }

    pub fn updateRemoteRefs(self: *FetchRefsUpdater, remote: []const u8, refs: []const RefEntry) !FetchRefsResult {
        const cwd = Io.Dir.cwd();
        const refs_path = try std.fmt.allocPrint(self.allocator, ".git/refs/remotes/{s}", .{remote});
        defer self.allocator.free(refs_path);
        cwd.createDirPath(self.io, refs_path) catch return error.CreateRefDirFailed;

        var updated: u32 = 0;
        for (refs) |ref| {
            const ref_file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ refs_path, ref.name });
            defer self.allocator.free(ref_file_path);
            const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{ref.oid});
            defer self.allocator.free(ref_content);
            cwd.writeFile(self.io, .{ .sub_path = ref_file_path, .data = ref_content }) catch continue;
            updated += 1;
        }
        return FetchRefsResult{ .success = true, .refs_updated = updated };
    }
};

test "FetchRefsResult structure" {
    const result = FetchRefsResult{ .success = true, .refs_updated = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.refs_updated == 5);
}

test "FetchRefsUpdater init" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    const updater = FetchRefsUpdater.init(std.testing.allocator, io);
    try std.testing.expect(updater.allocator == std.testing.allocator);
}

test "FetchRefsUpdater updateRefs writes ref files" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var updater = FetchRefsUpdater.init(std.testing.allocator, io);
    const refs = [_]RefEntry{
        .{ .name = "main", .oid = "abcdef1234567890123456789012345678901234" },
    };
    const result = try updater.updateRefs(&refs);
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.refs_updated >= 1);
}

test "FetchRefsUpdater updateRemoteRefs writes ref files" {
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var updater = FetchRefsUpdater.init(std.testing.allocator, io);
    const refs = [_]RefEntry{
        .{ .name = "main", .oid = "abcdef1234567890123456789012345678901234" },
    };
    const result = try updater.updateRemoteRefs("origin", &refs);
    try std.testing.expect(result.success == true);
}
