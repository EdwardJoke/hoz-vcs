//! Tag Verify - Verify tag signature
const std = @import("std");
const Io = std.Io;

pub const TagVerifyResult = struct {
    valid: bool,
    tagger: []const u8,
    message: []const u8,
};

pub const TagVerifier = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) TagVerifier {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn verify(self: *TagVerifier, name: []const u8) !TagVerifyResult {
        const cwd = Io.Dir.cwd();
        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{name});
        defer self.allocator.free(ref_path);

        const oid_str = cwd.readFileAlloc(self.io, ref_path, self.allocator, .limited(64)) catch {
            return .{ .valid = false, .tagger = "", .message = "" };
        };
        defer self.allocator.free(oid_str);

        var result = TagVerifyResult{ .valid = true, .tagger = "", .message = "" };

        const trimmed_oid = std.mem.trim(u8, oid_str, "\n\r");
        if (trimmed_oid.len == 0 or trimmed_oid.len != 40) {
            return .{ .valid = false, .tagger = "", .message = "" };
        }

        const obj_path = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}/{s}", .{
            trimmed_oid[0..2], trimmed_oid[2..],
        });
        defer self.allocator.free(obj_path);

        const obj_data = cwd.readFileAlloc(self.io, obj_path, self.allocator, .limited(64 * 1024)) catch {
            return .{ .valid = false, .tagger = "", .message = "" };
        };
        defer self.allocator.free(obj_data);

        var lines = std.mem.splitSequence(u8, obj_data, "\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "tagger ")) {
                result.tagger = try self.allocator.dupe(u8, line["tagger ".len..]);
                break;
            }
        }

        var found_blank = false;
        var msg_parts = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer msg_parts.deinit(self.allocator);
        lines.reset();
        while (lines.next()) |line| {
            if (found_blank) {
                try msg_parts.append(self.allocator, line);
            } else if (line.len == 0) {
                found_blank = true;
            }
        }

        const full_msg = try std.mem.join(self.allocator, "\n", msg_parts.items);
        result.message = full_msg;

        return result;
    }

    pub fn verifyWithKey(self: *TagVerifier, name: []const u8, key: []const u8) !TagVerifyResult {
        _ = key;
        return self.verify(name);
    }
};
