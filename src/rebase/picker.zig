//! Rebase Picker - Interactive rebase picker
const std = @import("std");

pub const Action = enum {
    pick,
    reword,
    edit,
    squash,
    fixup,
    drop,
    exec,
};

pub const CommitAction = struct {
    oid: []const u8,
    action: Action,
    message: []const u8 = "",
};

pub const PickerOptions = struct {
    autosquash: bool = false,
    keep_empty: bool = false,
};

pub const RebasePicker = struct {
    allocator: std.mem.Allocator,
    options: PickerOptions,

    pub fn init(allocator: std.mem.Allocator, options: PickerOptions) RebasePicker {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn parseTodoList(self: *RebasePicker, input: []const u8) ![]const CommitAction {
        var actions = std.ArrayList(CommitAction).empty;
        errdefer {
            for (actions.items) |a| {
                if (a.oid.len > 0) self.allocator.free(a.oid);
                if (a.message.len > 0) self.allocator.free(a.message);
            }
            actions.deinit(self.allocator);
        }

        var lines = std.mem.splitSequence(u8, input, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            var parts = std.mem.splitScalar(u8, trimmed, ' ');
            const action_str = parts.first() orelse continue;
            const rest = parts.rest();

            const action = self.parseAction(action_str) orelse continue;

            switch (action) {
                .exec => {
                    const cmd_owned = try self.allocator.dupe(u8, rest);
                    try actions.append(self.allocator, .{
                        .oid = "",
                        .action = action,
                        .message = cmd_owned,
                    });
                },
                else => {
                    var oid_parts = std.mem.splitScalar(u8, rest, ' ');
                    const oid_raw = oid_parts.first() orelse continue;
                    const msg_rest = oid_parts.rest();
                    const oid_owned = try self.allocator.dupe(u8, oid_raw);
                    const msg_owned = try self.allocator.dupe(u8, msg_rest);

                    try actions.append(self.allocator, .{
                        .oid = oid_owned,
                        .action = action,
                        .message = msg_owned,
                    });
                },
            }
        }

        return actions.toOwnedSlice(self.allocator);
    }

    pub fn getAction(self: *RebasePicker, commit: []const u8) !?Action {
        if (self.options.autosquash) {
            var iter = std.mem.splitScalar(u8, commit, '\n');
            const first_line = iter.first() orelse return .pick;

            if (std.mem.startsWith(u8, first_line, "squash! ") or std.mem.startsWith(u8, first_line, "squash!")) {
                return .squash;
            }
            if (std.mem.startsWith(u8, first_line, "fixup! ") or std.mem.startsWith(u8, first_line, "fixup!")) {
                return .fixup;
            }
        }

        return .pick;
    }

    fn parseAction(self: *RebasePicker, str: []const u8) ?Action {
        _ = self;

        const map = std.StaticStringMap(Action).initComptime(.{
            .{ "pick", .pick },
            .{ "p", .pick },
            .{ "reword", .reword },
            .{ "r", .reword },
            .{ "edit", .edit },
            .{ "e", .edit },
            .{ "squash", .squash },
            .{ "s", .squash },
            .{ "fixup", .fixup },
            .{ "f", .fixup },
            .{ "drop", .drop },
            .{ "d", .drop },
            .{ "exec", .exec },
            .{ "x", .exec },
        });

        return map.get(str);
    }
};

test "Action enum values" {
    try std.testing.expect(@as(u3, @intFromEnum(Action.pick)) == 0);
    try std.testing.expect(@as(u3, @intFromEnum(Action.drop)) == 5);
}

test "CommitAction structure" {
    const action = CommitAction{ .oid = "abc123", .action = .pick };
    try std.testing.expectEqualStrings("abc123", action.oid);
    try std.testing.expect(action.action == .pick);
}

test "PickerOptions default values" {
    const options = PickerOptions{};
    try std.testing.expect(options.autosquash == false);
    try std.testing.expect(options.keep_empty == false);
}

test "RebasePicker init" {
    const options = PickerOptions{};
    const picker = RebasePicker.init(std.testing.allocator, options);
    try std.testing.expect(picker.allocator == std.testing.allocator);
}

test "RebasePicker init with options" {
    var options = PickerOptions{};
    options.autosquash = true;
    options.keep_empty = true;
    const picker = RebasePicker.init(std.testing.allocator, options);
    try std.testing.expect(picker.options.autosquash == true);
}

test "RebasePicker parseTodoList basic" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const todo =
        \\pick abc1234 Initial commit
        \\pick def5678 Add feature
        \\pick ghi9012 Fix bug
    ;
    const result = try picker.parseTodoList(todo);
    defer {
        for (result) |a| {
            if (a.oid.len > 0) std.testing.allocator.free(a.oid);
            if (a.message.len > 0) std.testing.allocator.free(a.message);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("abc1234", result[0].oid);
    try std.testing.expectEqual(.pick, result[0].action);
    try std.testing.expectEqualStrings("Initial commit", result[0].message);
}

test "RebasePicker parseTodoList mixed actions" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const todo =
        \\pick abc1234 First commit
        \\squash def5678 Squashed in
        \\edit ghi9012 Edit this one
        \\drop jkl3456 Drop this
        \\exec make test
    ;
    const result = try picker.parseTodoList(todo);
    defer {
        for (result) |a| {
            if (a.oid.len > 0) std.testing.allocator.free(a.oid);
            if (a.message.len > 0) std.testing.allocator.free(a.message);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqual(.pick, result[0].action);
    try std.testing.expectEqual(.squash, result[1].action);
    try std.testing.expectEqual(.edit, result[2].action);
    try std.testing.expectEqual(.drop, result[3].action);
    try std.testing.expectEqual(.exec, result[4].action);
    try std.testing.expectEqualStrings("make test", result[4].message);
}

test "RebasePicker parseTodoList skips comments and blanks" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const todo =
        \\# Rebase master onto abc1234
        \\
        \\pick abc1234 Real commit
        \\# Comment line
        \\pick def5678 Another real
    ;
    const result = try picker.parseTodoList(todo);
    defer {
        for (result) |a| {
            if (a.oid.len > 0) std.testing.allocator.free(a.oid);
            if (a.message.len > 0) std.testing.allocator.free(a.message);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "RebasePicker parseTodoList short form actions" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const todo =
        \\p abc1234 Pick short
        \\s def5678 Squash short
        \\e ghi9012 Edit short
        \\d jkl3456 Drop short
    ;
    const result = try picker.parseTodoList(todo);
    defer {
        for (result) |a| {
            if (a.oid.len > 0) std.testing.allocator.free(a.oid);
            if (a.message.len > 0) std.testing.allocator.free(a.message);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(.pick, result[0].action);
    try std.testing.expectEqual(.squash, result[1].action);
    try std.testing.expectEqual(.edit, result[2].action);
    try std.testing.expectEqual(.drop, result[3].action);
}

test "RebasePicker getAction method exists" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const action = try picker.getAction("abc123");
    try std.testing.expect(action.? == .pick);
}
