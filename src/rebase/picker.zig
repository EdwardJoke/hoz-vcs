//! Rebase Picker - Interactive rebase picker
const std = @import("std");
const Io = std.Io;

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

pub const EditorLoop = struct {
    allocator: std.mem.Allocator,
    actions: []CommitAction,
    cursor: usize,
    modified: bool,

    pub fn init(allocator: std.mem.Allocator, actions: []CommitAction) EditorLoop {
        return .{
            .allocator = allocator,
            .actions = actions,
            .cursor = 0,
            .modified = false,
        };
    }

    pub fn renderTodo(self: *EditorLoop, writer: anytype) !void {
        try writer.writeAll("\n# Interactive rebase todo\n");
        try writer.writeAll("# Commands:\n");
        try writer.writeAll("#  p, pick <commit> = use commit\n");
        try writer.writeAll("#  r, reword <commit> = use commit, but edit the commit message\n");
        try writer.writeAll("#  e, edit <commit> = use commit, but stop for amending\n");
        try writer.writeAll("#  s, squash <commit> = use commit, but meld into previous commit\n");
        try writer.writeAll("#  f, fixup <commit> = like \"squash\", but discard this commit's log message\n");
        try writer.write("#  d, drop <commit> = remove commit\n");
        try writer.writeAll("#  x, exec <command> = run command (the rest of the line) using shell\n");
        try writer.writeAll("#\n");
        try writer.print("# These lines can be re-ordered; they are executed from top to bottom.\n", .{});
        try writer.writeAll("#\n");

        for (self.actions, 0..) |action, i| {
            const prefix: []const u8 = if (i == self.cursor) "> " else "  ";
            const action_str = actionName(action.action);
            switch (action.action) {
                .exec => {
                    try writer.print("{s}{s} {s}\n", .{ prefix, action_str, action.message });
                },
                else => {
                    const short_oid = if (action.oid.len > 7) action.oid[0..7] else action.oid;
                    try writer.print("{s}{s} {s} {s}\n", .{ prefix, action_str, short_oid, action.message });
                },
            }
        }

        try writer.writeAll("\n");
    }

    fn actionName(action: Action) []const u8 {
        return switch (action) {
            .pick => "pick",
            .reword => "reword",
            .edit => "edit",
            .squash => "squash",
            .fixup => "fixup",
            .drop => "drop",
            .exec => "exec",
        };
    }

    pub fn applyCommand(self: *EditorLoop, cmd: []const u8) !bool {
        var parts = std.mem.splitScalar(u8, cmd, ' ');
        const verb = parts.first() orelse return false;

        if (std.mem.eql(u8, verb, "q") or std.mem.eql(u8, verb, "quit")) {
            return false;
        }

        if (std.mem.eql(u8, verb, "done") or std.mem.eql(u8, verb, "w") or std.mem.eql(u8, verb, "write")) {
            return true;
        }

        if (std.mem.eql(u8, verb, "j") or std.mem.eql(u8, verb, "down")) {
            if (self.actions.len > 0 and self.cursor < self.actions.len - 1) {
                self.cursor += 1;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "k") or std.mem.eql(u8, verb, "up")) {
            if (self.cursor > 0) {
                self.cursor -= 1;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "p") or std.mem.eql(u8, verb, "pick")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .pick;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "r") or std.mem.eql(u8, verb, "reword")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .reword;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "e") or std.mem.eql(u8, verb, "edit")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .edit;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "s") or std.mem.eql(u8, verb, "squash")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .squash;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "f") or std.mem.eql(u8, verb, "fixup")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .fixup;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "d") or std.mem.eql(u8, verb, "drop")) {
            if (self.cursor < self.actions.len) {
                self.actions[self.cursor].action = .drop;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "move-down") or std.mem.eql(u8, verb, "md")) {
            if (self.cursor < self.actions.len - 1) {
                const tmp = self.actions[self.cursor];
                self.actions[self.cursor] = self.actions[self.cursor + 1];
                self.actions[self.cursor + 1] = tmp;
                self.cursor += 1;
                self.modified = true;
            }
            return true;
        }

        if (std.mem.eql(u8, verb, "move-up") or std.mem.eql(u8, verb, "mu")) {
            if (self.cursor > 0) {
                const tmp = self.actions[self.cursor];
                self.actions[self.cursor] = self.actions[self.cursor - 1];
                self.actions[self.cursor - 1] = tmp;
                self.cursor -= 1;
                self.modified = true;
            }
            return true;
        }

        return true;
    }

    pub fn generateOutput(self: *EditorLoop, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        for (self.actions) |action| {
            const action_str = actionName(action.action);
            switch (action.action) {
                .exec => {
                    try buf.appendSlice(allocator, action_str);
                    try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, action.message);
                    try buf.append(allocator, '\n');
                },
                else => {
                    try buf.appendSlice(allocator, action_str);
                    try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, action.oid);
                    try buf.append(allocator, ' ');
                    try buf.appendSlice(allocator, action.message);
                    try buf.append(allocator, '\n');
                },
            }
        }

        return buf.toOwnedSlice(allocator);
    }

    pub fn countByAction(self: *EditorLoop, target_action: Action) usize {
        var count: usize = 0;
        for (self.actions) |a| {
            if (a.action == target_action) count += 1;
        }
        return count;
    }
};

test "EditorLoop init" {
    var actions = [_]CommitAction{
        .{ .oid = "abc1234", .action = .pick, .message = "First" },
    };
    const loop = EditorLoop.init(std.testing.allocator, &actions);
    try std.testing.expectEqual(@as(usize, 0), loop.cursor);
    try std.testing.expect(loop.modified == false);
}

test "EditorLoop renderTodo outputs content" {
    var actions = [_]CommitAction{
        .{ .oid = "abc1234", .action = .pick, .message = "First" },
        .{ .oid = "def5678", .action = .reword, .message = "Second" },
    };

    var loop = EditorLoop.init(std.testing.allocator, &actions);
    var buf: [2048]u8 = undefined;
    const writer = Io.Writer.fixed(&buf);

    loop.renderTodo(&writer.writer.interface) catch {};
    const output = Io.Writer.buffered(&writer);
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "pick abc1234 First") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reword def5678 Second") != null);
}

test "EditorLoop applyCommand pick changes action" {
    var actions = [_]CommitAction{
        .{ .oid = "abc1234", .action = .pick, .message = "First" },
    };
    var loop = EditorLoop.init(std.testing.allocator, &actions);

    _ = loop.applyCommand("pick") catch false;
    try std.testing.expect(actions[0].action == .pick);

    _ = loop.applyCommand("drop") catch false;
    try std.testing.expect(actions[0].action == .drop);
}

test "EditorLoop applyCommand navigation" {
    var actions = [_]CommitAction{
        .{ .oid = "a", .action = .pick, .message = "1" },
        .{ .oid = "b", .action = .pick, .message = "2" },
        .{ .oid = "c", .action = .pick, .message = "3" },
    };
    var loop = EditorLoop.init(std.testing.allocator, &actions);

    _ = loop.applyCommand("j") catch false;
    try std.testing.expectEqual(@as(usize, 1), loop.cursor);

    _ = loop.applyCommand("k") catch false;
    try std.testing.expectEqual(@as(usize, 0), loop.cursor);
}

test "EditorLoop moveDown swaps entries" {
    var actions = [_]CommitAction{
        .{ .oid = "aaa", .action = .pick, .message = "A" },
        .{ .oid = "bbb", .action = .pick, .message = "B" },
    };
    var loop = EditorLoop.init(std.testing.allocator, &actions);

    _ = loop.applyCommand("move-down") catch false;
    try std.testing.expectEqualStrings("bbb", actions[0].oid);
    try std.testing.expectEqualStrings("aaa", actions[1].oid);
    try std.testing.expectEqual(@as(usize, 1), loop.cursor);
}

test "EditorLoop generateOutput produces valid todo format" {
    var actions = [_]CommitAction{
        .{ .oid = "abc1234", .action = .pick, .message = "First commit" },
        .{ .oid = "def5678", .action = .drop, .message = "Dropped" },
    };
    var loop = EditorLoop.init(std.testing.allocator, &actions);

    const output = loop.generateOutput(std.testing.allocator) catch "";
    defer if (output.len > 0) std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "pick abc1234 First commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "drop def5678 Dropped") != null);
}

test "EditorLoop countByAction" {
    var actions = [_]CommitAction{
        .{ .oid = "a", .action = .pick, .message = "" },
        .{ .oid = "b", .action = .squash, .message = "" },
        .{ .oid = "c", .action = .squash, .message = "" },
        .{ .oid = "d", .action = .drop, .message = "" },
    };
    var loop = EditorLoop.init(std.testing.allocator, &actions);

    try std.testing.expectEqual(@as(usize, 2), loop.countByAction(.squash));
    try std.testing.expectEqual(@as(usize, 1), loop.countByAction(.pick));
    try std.testing.expectEqual(@as(usize, 1), loop.countByAction(.drop));
    try std.testing.expectEqual(@as(usize, 0), loop.countByAction(.edit));
}
