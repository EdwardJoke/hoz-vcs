//! Stash Drop - Drop stash entries
const std = @import("std");
const Io = std.Io;
const StashLister = @import("list.zig").StashLister;

pub const DropOptions = struct {
    index: u32 = 0,
};

pub const DropResult = struct {
    success: bool,
    entries_remaining: u32,
    message: ?[]const u8 = null,
};

pub const StashDropper = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,
    options: DropOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir, options: DropOptions) StashDropper {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
            .options = options,
        };
    }

    pub fn drop(self: *StashDropper) !DropResult {
        return try self.dropIndex(self.options.index);
    }

    pub fn dropIndex(self: *StashDropper, index: u32) !DropResult {
        const reflog_path = "logs/refs/stash";
        const content = self.git_dir.readFileAlloc(self.io, reflog_path, self.allocator, .limited(1024 * 1024)) catch {
            return DropResult{
                .success = false,
                .entries_remaining = 0,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        };
        defer self.allocator.free(content);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, content, '\n');
        var logical_index: u32 = 0;
        var found = false;
        var remaining_count: u32 = 0;
        var latest_oid: ?@import("../object/oid.zig").OID = null;

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (logical_index == index) {
                found = true;
                logical_index += 1;
                continue;
            }

            try out.appendSlice(self.allocator, line);
            try out.append(self.allocator, '\n');
            remaining_count += 1;
            latest_oid = parseNewOidFromReflogLine(line);
            logical_index += 1;
        }

        if (!found) {
            return DropResult{
                .success = false,
                .entries_remaining = remaining_count,
                .message = try std.fmt.allocPrint(self.allocator, "stash@{d} not found", .{index}),
            };
        }

        if (remaining_count == 0) {
            self.git_dir.deleteFile(self.io, reflog_path) catch {};
            self.git_dir.deleteFile(self.io, "refs/stash") catch {};
        } else {
            try self.git_dir.writeFile(self.io, .{ .sub_path = reflog_path, .data = out.items });
            if (latest_oid) |oid| {
                const hex = oid.toHex();
                const ref_content = try std.fmt.allocPrint(self.allocator, "{s}\n", .{&hex});
                defer self.allocator.free(ref_content);
                try self.git_dir.writeFile(self.io, .{ .sub_path = "refs/stash", .data = ref_content });
            }
        }

        return DropResult{
            .success = true,
            .entries_remaining = remaining_count,
            .message = try std.fmt.allocPrint(self.allocator, "Dropped stash@{d}", .{index}),
        };
    }

    pub fn clear(self: *StashDropper) !DropResult {
        self.git_dir.deleteFile(self.io, "logs/refs/stash") catch {};
        self.git_dir.deleteFile(self.io, "refs/stash") catch {};
        return DropResult{
            .success = true,
            .entries_remaining = 0,
            .message = try std.fmt.allocPrint(self.allocator, "Cleared all stash entries", .{}),
        };
    }
};

fn parseNewOidFromReflogLine(line: []const u8) ?@import("../object/oid.zig").OID {
    const OID = @import("../object/oid.zig").OID;
    var parts = std.mem.splitScalar(u8, line, ' ');
    _ = parts.next() orelse return null;
    const new_oid = parts.next() orelse return null;
    if (new_oid.len < 40) return null;
    return OID.fromHex(new_oid[0..40]) catch null;
}

test "DropOptions default values" {
    const options = DropOptions{};
    try std.testing.expect(options.index == 0);
}

test "DropResult structure" {
    const result = DropResult{ .success = true, .entries_remaining = 5 };
    try std.testing.expect(result.success == true);
    try std.testing.expect(result.entries_remaining == 5);
}
