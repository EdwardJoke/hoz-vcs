//! Stash List - List stash entries
const std = @import("std");
const Io = std.Io;
const OID = @import("../object/oid.zig").OID;
const ReflogManager = @import("../ref/reflog.zig").ReflogManager;

pub const StashEntry = struct {
    index: u32,
    message: []const u8,
    branch: []const u8,
    date: []const u8,
    oid: OID,
};

pub const StashLister = struct {
    allocator: std.mem.Allocator,
    io: Io,
    git_dir: Io.Dir,

    pub fn init(allocator: std.mem.Allocator, io: Io, git_dir: Io.Dir) StashLister {
        return .{
            .allocator = allocator,
            .io = io,
            .git_dir = git_dir,
        };
    }

    pub fn list(self: *StashLister) ![]const StashEntry {
        var entries = std.ArrayList(StashEntry).empty;
        errdefer entries.deinit(self.allocator);

        const reflog_path = "logs/refs/stash";
        const content = self.git_dir.readFileAlloc(self.io, reflog_path, self.allocator, .limited(65536)) catch {
            return entries.toOwnedSlice(self.allocator);
        };
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_idx: usize = 0;
        while (lines.next()) |line| : (line_idx += 1) {
            if (line.len == 0) continue;
            if (parseStashLine(line, line_idx)) |entry| {
                entries.append(self.allocator, entry) catch continue;
            }
        }

        return entries.toOwnedSlice(self.allocator);
    }

    fn parseStashLine(line: []const u8, line_idx: usize) ?StashEntry {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const oids_part = parts.next() orelse return null;
        const message = parts.rest();

        var oid_parts = std.mem.splitScalar(u8, oids_part, ' ');
        _ = oid_parts.next() orelse return null;
        const new_oid_str = oid_parts.next() orelse return null;

        const oid = OID.fromHex(new_oid_str[0..40]) catch return null;

        const branch = extractBranchFromMessage(message);
        const date = "unknown";
        const index = parseStashIndex(message) orelse line_idx;

        return StashEntry{
            .index = @intCast(index),
            .message = if (message.len > 0) message else "No message",
            .branch = branch,
            .date = date,
            .oid = oid,
        };
    }

    fn extractBranchFromMessage(message: []const u8) []const u8 {
        if (std.mem.startsWith(u8, message, "WIP on ")) {
            return message[7..];
        } else if (std.mem.startsWith(u8, message, "On ")) {
            if (std.mem.indexOf(u8, message, ": ")) |colon| {
                return message[3..colon];
            }
            return message[3..];
        }
        return "unknown";
    }

    fn parseStashIndex(message: []const u8) ?u32 {
        if (std.mem.startsWith(u8, message, "WIP on") or std.mem.startsWith(u8, message, "On")) {
            if (std.mem.indexOf(u8, message, "stash@{")) |start| {
                const brace_start = start + 6;
                if (brace_start < message.len and message[brace_start] == '{') {
                    const rest = message[brace_start + 1 ..];
                    if (std.mem.indexOf(u8, rest, "}")) |end| {
                        const index_str = rest[0..end];
                        return std.fmt.parseInt(u32, index_str, 10) catch null;
                    }
                }
            }
        }
        return null;
    }

    fn getEntry(self: *StashLister, index: u32) !?StashEntry {
        const entries = try self.list();
        defer self.allocator.free(entries);

        for (entries) |entry| {
            if (entry.index == index) return entry;
        }
        return null;
    }

    fn count(self: *StashLister) !usize {
        const entries = try self.list();
        defer self.allocator.free(entries);
        return entries.len;
    }
};
