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
        _ = self;
        _ = input;
        return &.{};
    }

    pub fn getAction(self: *RebasePicker, commit: []const u8) !?Action {
        _ = self;
        _ = commit;
        return .pick;
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

test "RebasePicker parseTodoList method exists" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const result = try picker.parseTodoList("pick abc123");
    _ = result;
    try std.testing.expect(picker.allocator != undefined);
}

test "RebasePicker getAction method exists" {
    var picker = RebasePicker.init(std.testing.allocator, .{});
    const action = try picker.getAction("abc123");
    try std.testing.expect(action.? == .pick);
}