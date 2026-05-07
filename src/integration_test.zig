//! Integration tests - seed repo roundtrip: init/add/commit/log/branch/branch-out
const std = @import("std");
const Io = std.Io;

const Init = @import("./cli/init.zig").Init;
const Add = @import("./cli/add.zig").Add;
const Commit = @import("./cli/commit.zig").Commit;
const Log = @import("./cli/log.zig").Log;
const Branch = @import("./cli/branch.zig").Branch;

const test_allocator = std.testing.allocator;

fn tmpPath(tmp: anytype) ![]u8 {
    return std.fs.path.join(test_allocator, &.{ ".zig-cache/tmp", &tmp.sub_path });
}

test "integration: init creates .git directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 1024);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const path = try tmpPath(&tmp);
    defer test_allocator.free(path);
    try init_cmd.run(path);

    const git_dir = tmp.dir.openDir(io, ".git", .{}) catch {
        try std.testing.expect(false);
        return;
    };
    defer git_dir.close(io);

    const head_file = git_dir.openFile(io, "HEAD", .{}) catch {
        try std.testing.expect(false);
        return;
    };
    defer head_file.close(io);
}

test "integration: add and commit roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 4096);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const path = try tmpPath(&tmp);
    defer test_allocator.free(path);
    try init_cmd.run(path);

    try tmp.dir.createDirPath(io, "subdir");

    const test_file_content =
        \\Hello from integration test!
        \\This file will be committed.
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = test_file_content });
    try tmp.dir.writeFile(io, .{ .sub_path = "subdir/nested.txt", .data = "nested content" });

    var add_cmd = Add.init(test_allocator, io, &writer, .{});
    try add_cmd.run(&.{ "hello.txt", "subdir/nested.txt" });

    var commit_cmd = Commit.init(test_allocator, io, &writer, .{});
    commit_cmd.message = "Initial commit from integration test";
    try commit_cmd.run();

    const objects_dir = tmp.dir.openDir(io, ".git/objects", .{}) catch {
        try std.testing.expect(false);
        return;
    };
    defer objects_dir.close(io);

    var entry_count: usize = 0;
    var walker = objects_dir.iterate();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory and entry.name.len == 2) {
            entry_count += 1;
        }
    }
    try std.testing.expect(entry_count > 0);
}

test "integration: log after commit produces output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 4096);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const path = try tmpPath(&tmp);
    defer test_allocator.free(path);
    try init_cmd.run(path);

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "content" });

    var add_cmd = Add.init(test_allocator, io, &writer, .{});
    try add_cmd.run(&.{"file.txt"});

    var commit_cmd = Commit.init(test_allocator, io, &writer, .{});
    commit_cmd.message = "Test commit for log";
    try commit_cmd.run();

    var log_out = try std.ArrayList(u8).initCapacity(test_allocator, 2048);
    defer log_out.deinit(test_allocator);
    var log_writer = Io.Writer.fixed(log_out.items);

    var log_cmd = Log.init(test_allocator, io, &log_writer, .{});
    try log_cmd.run(null);

    const written = Io.Writer.buffered(&log_writer);
    try std.testing.expect(written.len > 0);
}

test "integration: create branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 4096);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const repo_path = try tmpPath(&tmp);
    defer test_allocator.free(repo_path);
    try init_cmd.run(repo_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "branch_test.txt", .data = "branch data" });

    var add_cmd = Add.init(test_allocator, io, &writer, .{});
    try add_cmd.run(&.{"branch_test.txt"});

    var commit_cmd = Commit.init(test_allocator, io, &writer, .{});
    commit_cmd.message = "Commit for branch test";
    try commit_cmd.run();

    var branch_out = try std.ArrayList(u8).initCapacity(test_allocator, 1024);
    defer branch_out.deinit(test_allocator);
    var branch_writer = Io.Writer.fixed(branch_out.items);

    var branch_cmd = Branch.init(test_allocator, io, &branch_writer, .{});
    branch_cmd.action = .create;
    branch_cmd.new_branch_name = "feature-integration-test";
    try branch_cmd.run();

    const branch_written = Io.Writer.buffered(&branch_writer);
    try std.testing.expect(branch_written.len > 0);
}

test "integration: checkout branch switch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 4096);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const repo_path = try tmpPath(&tmp);
    defer test_allocator.free(repo_path);
    try init_cmd.run(repo_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "checkout_test.txt", .data = "checkout data" });

    var add_cmd = Add.init(test_allocator, io, &writer, .{});
    try add_cmd.run(&.{"checkout_test.txt"});

    var commit_cmd = Commit.init(test_allocator, io, &writer, .{});
    commit_cmd.message = "Commit for checkout test";
    try commit_cmd.run();

    var branch_out = try std.ArrayList(u8).initCapacity(test_allocator, 512);
    defer branch_out.deinit(test_allocator);
    var branch_writer = Io.Writer.fixed(branch_out.items);

    var branch_cmd = Branch.init(test_allocator, io, &branch_writer, .{});
    branch_cmd.action = .create;
    branch_cmd.new_branch_name = "checkout-target";
    try branch_cmd.run();

    var co_out = try std.ArrayList(u8).initCapacity(test_allocator, 512);
    defer co_out.deinit(test_allocator);
    var co_writer = Io.Writer.fixed(co_out.items);

    var checkout_cmd = Branch.init(test_allocator, io, &co_writer, .{});
    checkout_cmd.action = .checkout;
    checkout_cmd.target = "checkout-target";
    try checkout_cmd.run();

    const head_content = tmp.dir.readFileAlloc(io, ".git/HEAD", test_allocator, .limited(256)) catch {
        try std.testing.expect(false);
        return;
    };
    defer test_allocator.free(head_content);

    try std.testing.expect(std.mem.indexOf(u8, head_content, "checkout-target") != null or
        std.mem.indexOf(u8, head_content, "refs/heads/checkout-target") != null);
}

test "integration: multiple commits produce multiple log entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var out_buf = try std.ArrayList(u8).initCapacity(test_allocator, 4096);
    defer out_buf.deinit(test_allocator);
    var writer = Io.Writer.fixed(out_buf.items);

    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();
    const io = io_instance.io();

    var init_cmd = Init.init(test_allocator, io, &writer, .{});
    const repo_path = try tmpPath(&tmp);
    defer test_allocator.free(repo_path);
    try init_cmd.run(repo_path);

    var add_cmd = Add.init(test_allocator, io, &writer, .{});
    var commit_cmd = Commit.init(test_allocator, io, &writer, .{});

    const files = [_][]const u8{ "first.txt", "second.txt", "third.txt" };
    const msgs = [_][]const u8{ "First commit", "Second commit", "Third commit" };

    for (files, msgs) |file, msg| {
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = msg });
        add_cmd = Add.init(test_allocator, io, &writer, .{});
        try add_cmd.run(&.{file});
        commit_cmd = Commit.init(test_allocator, io, &writer, .{});
        commit_cmd.message = msg;
        try commit_cmd.run();
    }

    var log_out = try std.ArrayList(u8).initCapacity(test_allocator, 2048);
    defer log_out.deinit(test_allocator);
    var log_writer = Io.Writer.fixed(log_out.items);

    var log_cmd = Log.init(test_allocator, io, &log_writer, .{});
    try log_cmd.run(null);

    const log_data = Io.Writer.buffered(&log_writer);
    var commit_count: usize = 0;
    var iter = std.mem.splitScalar(u8, log_data, '\n');
    while (iter.next()) |line| {
        if (std.mem.indexOf(u8, line, "commit") != null) {
            commit_count += 1;
        }
    }
    try std.testing.expect(commit_count >= 3);
}
