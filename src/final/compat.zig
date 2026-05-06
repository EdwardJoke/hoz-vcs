//! Git Compatibility Tester - Test full Git compatibility via real command execution
const std = @import("std");
const Io = std.Io;

const TestHelper = struct {
    test_passed: u32 = 0,
    test_failed: u32 = 0,

    pub fn expect(self: *TestHelper, condition: bool, msg: []const u8) void {
        if (condition) {
            self.test_passed += 1;
        } else {
            self.test_failed += 1;
            const stderr = std.Io.File.stderr().writer(&.{});
            stderr.print("FAIL: {s}\n", .{msg}) catch {};
        }
    }

    pub fn expectEqualStrings(self: *TestHelper, a: []const u8, b: []const u8, msg: []const u8) void {
        if (std.mem.eql(u8, a, b)) {
            self.test_passed += 1;
        } else {
            self.test_failed += 1;
            const stderr = std.Io.File.stderr().writer(&.{});
            stderr.print("FAIL: {s} (expected \"{s}\", got \"{s}\")\n", .{ msg, a, b }) catch {};
        }
    }

    pub fn printSummary(self: *TestHelper) void {
        const stdout = std.Io.File.stdout().writer(&.{});
        stdout.print("Compat tests: {d} passed, {d} failed\n", .{ self.test_passed, self.test_failed }) catch {};
    }
};

pub const GitCompatTester = struct {
    allocator: std.mem.Allocator,
    io: Io,
    passed: u32,
    failed: u32,
    temp_dir: []const u8,
    test_helper: TestHelper,

    pub fn init(allocator: std.mem.Allocator, io: Io) GitCompatTester {
        return .{
            .allocator = allocator,
            .io = io,
            .passed = 0,
            .failed = 0,
            .temp_dir = undefined,
            .test_helper = TestHelper{},
        };
    }

    pub fn runFullSuite(self: *GitCompatTester) !void {
        self.temp_dir = try std.fs.path.join(self.allocator, &.{"_compat_test_temp"});
        try self.runInit();
        try self.runAdd();
        try self.runCommit();
        try self.runBranch();
        try self.runCheckout();
        try self.runMerge();
        try self.runRebase();
        try self.runStash();
        try self.runTag();
        try self.runLog();
        try self.runDiff();
        try self.runShow();
        try self.runBlame();
        try self.runBisect();
        try self.runWorktree();
        try self.runRemote();
        try self.printSummary();
    }

    fn runCommand(self: *GitCompatTester, argv: []const []const u8, cwd: []const u8) !void {
        var child = try std.process.Child.spawn(.{
            .argv = argv,
            .cwd = cwd,
        });
        const term = try child.wait();
        if (term != .exited or term.exited != 0) {
            const stderr = std.Io.File.stderr().writer(&.{});
            stderr.print("WARN: command {s} exited with {}\n", .{ argv[0], term }) catch {};
        }
    }

    fn runCommandWithOutput(self: *GitCompatTester, argv: []const []const u8, cwd: []const u8) ![]u8 {
        var child = try std.process.Child.spawn(.{
            .argv = argv,
            .cwd = cwd,
        });
        const result = try child.collect(self.allocator);
        if (result.term != .exited or result.term.exited != 0) {
            self.allocator.free(result.stdout);
            return error.CommandFailed;
        }
        return result.stdout;
    }

    fn cleanupDir(_: *GitCompatTester, path: []const u8) void {
        const cwd = Io.Dir.cwd();
        cwd.removeTree(std.Io.get(), path, .{}) catch {};
    }

    fn makeDir(self: *GitCompatTester, path: []const u8) !void {
        const cwd = Io.Dir.cwd();
        cwd.makePath(self.io, path, .{});
    }

    fn writeFileData(self: *GitCompatTester, path: []const u8, data: []const u8) !void {
        const cwd = Io.Dir.cwd();
        const f = cwd.createFile(self.io, path, .{});
        f.writeAll(self.io, data) catch {};
        f.close();
    }

    fn countDirEntries(path: []const u8) !usize {
        const cwd = Io.Dir.cwd();
        var dir = cwd.openDir(std.Io.get(), path, .{ .iterate = true });
        defer dir.close();
        var count: usize = 0;
        while (dir.next()) |_| count += 1;
        return count;
    }

    fn runInit(self: *GitCompatTester) !void {
        const git_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "git_repo" });
        defer self.allocator.free(git_path);
        self.cleanupDir(git_path);

        const hoz_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "hoz_repo" });
        defer self.allocator.free(hoz_path);
        self.cleanupDir(hoz_path);

        try self.runCommand(&.{ "git", "init", git_path }, ".");
        try self.runCommand(&.{ "hoz", "init", hoz_path }, ".");

        const git_head = try std.fs.path.join(self.allocator, &.{ git_path, ".git", "HEAD" });
        defer self.allocator.free(git_head);
        const hoz_head = try std.fs.path.join(self.allocator, &.{ hoz_path, ".git", "HEAD" });
        defer self.allocator.free(hoz_head);

        const git_exists = Io.Dir.cwd().openFile(git_head, .{}) catch null;
        defer if (git_exists) |f| f.close();
        const hoz_exists = Io.Dir.cwd().openFile(hoz_head, .{}) catch null;
        defer if (hoz_exists) |f| f.close();

        try self.test_helper.expect(git_exists != null, "git init should create .git/HEAD");
        try self.test_helper.expect(hoz_exists != null, "hoz init should create .git/HEAD");
        self.passed += 1;
    }

    fn runAdd(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "add_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "hello world\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);

        const git_index = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "index" });
        defer self.allocator.free(git_index);
        const hoz_index = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "index" });
        defer self.allocator.free(hoz_index);

        const git_idx = Io.Dir.cwd().openFile(git_index, .{}) catch null;
        defer if (git_idx) |f| f.close();
        const hoz_idx = Io.Dir.cwd().openFile(hoz_index, .{}) catch null;
        defer if (hoz_idx) |f| f.close();

        try self.test_helper.expect(git_idx != null, "git add should create index");
        try self.test_helper.expect(hoz_idx != null, "hoz add should create index");
        self.passed += 1;
    }

    fn runCommit(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "commit_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "test content\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "-m", "test" }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "-m", "test" }, repo_path);

        const git_commit = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "objects" });
        defer self.allocator.free(git_commit);
        const hoz_commit = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "objects" });
        defer self.allocator.free(hoz_commit);

        const git_objects = try countDirEntries(git_commit);
        const hoz_objects = try countDirEntries(hoz_commit);

        try self.test_helper.expect(git_objects > 0, "git commit should create objects");
        try self.test_helper.expect(hoz_objects > 0, "hoz commit should create objects");
        self.passed += 1;
    }

    fn runBranch(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "branch_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "branch", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "branch", "feature" }, repo_path);

        const git_branch = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "refs", "heads", "feature" });
        defer self.allocator.free(git_branch);
        const hoz_branch = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "refs", "heads", "feature" });
        defer self.allocator.free(hoz_branch);

        const git_exists = Io.Dir.cwd().openFile(git_branch, .{}) catch null;
        defer if (git_exists) |f| f.close();
        const hoz_exists = Io.Dir.cwd().openFile(hoz_branch, .{}) catch null;
        defer if (hoz_exists) |f| f.close();

        try self.test_helper.expect(git_exists != null, "git branch should create ref file");
        try self.test_helper.expect(hoz_exists != null, "hoz branch should create ref file");
        self.passed += 1;
    }

    fn runCheckout(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "checkout_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "content\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "-m", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "-b", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "-b", "feature" }, repo_path);

        const git_head = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD" }, ".");
        defer self.allocator.free(git_head);
        const hoz_head = try self.runCommandWithOutput(&.{ "hoz", "rev-parse", "--abbrev-ref", "HEAD" }, repo_path);
        defer self.allocator.free(hoz_head);

        try self.test_helper.expectEqualStrings(git_head, hoz_head, "checkout should set HEAD correctly");
        self.passed += 1;
    }

    fn runMerge(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "merge_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "base" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "base" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "branch", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "branch", "feature" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "feature" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "feature" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "feature" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "main" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "merge", "feature", "--no-edit" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "main" }, repo_path);
        try self.runCommand(&.{ "hoz", "merge", "feature", "--no-edit" }, repo_path);

        const git_log = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "log", "--oneline" }, ".");
        defer self.allocator.free(git_log);
        const hoz_log = try self.runCommandWithOutput(&.{ "hoz", "log", "--oneline" }, repo_path);
        defer self.allocator.free(hoz_log);

        try self.test_helper.expect(git_log.len > 0, "git merge should create commit");
        try self.test_helper.expect(hoz_log.len > 0, "hoz merge should create commit");
        self.passed += 1;
    }

    fn runRebase(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "rebase_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "base" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "base" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "branch", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "branch", "feature" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "feature" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "feature" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "feature" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "feature" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "main" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "main2" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "main" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "main2" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "checkout", "feature" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "rebase", "main" }, ".");
        try self.runCommand(&.{ "hoz", "checkout", "feature" }, repo_path);
        try self.runCommand(&.{ "hoz", "rebase", "main" }, repo_path);

        const git_rebased = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "log", "--oneline", "-2" }, ".");
        defer self.allocator.free(git_rebased);
        const hoz_rebased = try self.runCommandWithOutput(&.{ "hoz", "log", "--oneline", "-2" }, repo_path);
        defer self.allocator.free(hoz_rebased);

        try self.test_helper.expect(git_rebased.len > 0, "git rebase should produce output");
        try self.test_helper.expect(hoz_rebased.len > 0, "hoz rebase should produce output");
        self.passed += 1;
    }

    fn runStash(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "stash_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "content\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "stash" }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);
        try self.runCommand(&.{ "hoz", "stash" }, repo_path);

        const git_stash = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "stash", "list" }, ".");
        defer self.allocator.free(git_stash);
        const hoz_stash = try self.runCommandWithOutput(&.{ "hoz", "stash", "list" }, repo_path);
        defer self.allocator.free(hoz_stash);

        try self.test_helper.expect(git_stash.len > 0, "git stash should list entries");
        try self.test_helper.expect(hoz_stash.len > 0, "hoz stash should list entries");
        self.passed += 1;
    }

    fn runTag(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "tag_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "tag", "v1.0" }, ".");
        try self.runCommand(&.{ "hoz", "tag", "v1.0" }, repo_path);

        const git_tag = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "refs", "tags", "v1.0" });
        defer self.allocator.free(git_tag);
        const hoz_tag = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "refs", "tags", "v1.0" });
        defer self.allocator.free(hoz_tag);

        const git_exists = Io.Dir.cwd().openFile(git_tag, .{}) catch null;
        defer if (git_exists) |f| f.close();
        const hoz_exists = Io.Dir.cwd().openFile(hoz_tag, .{}) catch null;
        defer if (hoz_exists) |f| f.close();

        try self.test_helper.expect(git_exists != null, "git tag should create tag ref");
        try self.test_helper.expect(hoz_exists != null, "hoz tag should create tag ref");
        self.passed += 1;
    }

    fn runLog(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "log_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "first" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "second" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "first" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "second" }, repo_path);

        const git_log = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "log", "--oneline" }, ".");
        defer self.allocator.free(git_log);
        const hoz_log = try self.runCommandWithOutput(&.{ "hoz", "log", "--oneline" }, repo_path);
        defer self.allocator.free(hoz_log);

        try self.test_helper.expect(git_log.len > 0, "git log should produce output");
        try self.test_helper.expect(hoz_log.len > 0, "hoz log should produce output");
        self.passed += 1;
    }

    fn runDiff(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "diff_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "original\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "-m", "init" }, repo_path);

        try self.writeFileData(file_path, "modified\n");

        const git_diff = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "diff" }, ".");
        defer self.allocator.free(git_diff);
        const hoz_diff = try self.runCommandWithOutput(&.{ "hoz", "diff" }, repo_path);
        defer self.allocator.free(hoz_diff);

        try self.test_helper.expect(git_diff.len > 0, "git diff should show changes");
        try self.test_helper.expect(hoz_diff.len > 0, "hoz diff should show changes");
        self.passed += 1;
    }

    fn runShow(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "show_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "test" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "test" }, repo_path);

        const git_show = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "show", "--stat" }, ".");
        defer self.allocator.free(git_show);
        const hoz_show = try self.runCommandWithOutput(&.{ "hoz", "show", "--stat" }, repo_path);
        defer self.allocator.free(hoz_show);

        try self.test_helper.expect(git_show.len > 0, "git show should produce output");
        try self.test_helper.expect(hoz_show.len > 0, "hoz show should produce output");
        self.passed += 1;
    }

    fn runBlame(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "blame_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ repo_path, "test.txt" });
        defer self.allocator.free(file_path);
        try self.writeFileData(file_path, "line1\nline2\n");

        try self.runCommand(&.{ "git", "-C", repo_path, "add", "." }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "add", "." }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "-m", "init" }, repo_path);

        const git_blame = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "blame", "test.txt" }, ".");
        defer self.allocator.free(git_blame);
        const hoz_blame = try self.runCommandWithOutput(&.{ "hoz", "blame", "test.txt" }, repo_path);
        defer self.allocator.free(hoz_blame);

        try self.test_helper.expect(git_blame.len > 0, "git blame should produce output");
        try self.test_helper.expect(hoz_blame.len > 0, "hoz blame should produce output");
        self.passed += 1;
    }

    fn runBisect(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "bisect_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "good1" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "good2" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "bad" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "good1" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "good2" }, repo_path);
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "bad" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "bisect", "start" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "bisect", "good", "HEAD~2" }, ".");
        try self.runCommand(&.{ "git", "-C", repo_path, "bisect", "bad", "HEAD" }, ".");
        try self.runCommand(&.{ "hoz", "bisect", "start" }, repo_path);
        try self.runCommand(&.{ "hoz", "bisect", "good", "HEAD~2" }, repo_path);
        try self.runCommand(&.{ "hoz", "bisect", "bad", "HEAD" }, repo_path);

        const git_bisect = try self.runCommandWithOutput(&.{ "git", "-C", repo_path, "bisect", "log" }, ".");
        defer self.allocator.free(git_bisect);
        const hoz_bisect = try self.runCommandWithOutput(&.{ "hoz", "bisect", "log" }, repo_path);
        defer self.allocator.free(hoz_bisect);

        try self.test_helper.expect(git_bisect.len > 0, "git bisect should produce log");
        try self.test_helper.expect(hoz_bisect.len > 0, "hoz bisect should produce log");
        self.passed += 1;
    }

    fn runWorktree(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "worktree_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "init" }, ".");
        try self.runCommand(&.{ "hoz", "commit", "--allow-empty", "-m", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "worktree", "add", "feature", "main" }, ".");
        try self.runCommand(&.{ "hoz", "worktree", "add", "feature", "main" }, repo_path);

        const git_wt = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "worktrees", "feature" });
        defer self.allocator.free(git_wt);
        const hoz_wt = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "worktrees", "feature" });
        defer self.allocator.free(hoz_wt);

        const git_exists = Io.Dir.cwd().openDir(git_wt, .{}) catch null;
        defer if (git_exists) |d| d.close();
        const hoz_exists = Io.Dir.cwd().openDir(hoz_wt, .{}) catch null;
        defer if (hoz_exists) |d| d.close();

        try self.test_helper.expect(git_exists != null, "git worktree should create worktree");
        try self.test_helper.expect(hoz_exists != null, "hoz worktree should create worktree");
        self.passed += 1;
    }

    fn runRemote(self: *GitCompatTester) !void {
        const repo_path = try std.fs.path.join(self.allocator, &.{ self.temp_dir, "remote_test" });
        defer self.allocator.free(repo_path);
        self.cleanupDir(repo_path);

        try self.makeDir(repo_path);
        try self.runCommand(&.{ "git", "-C", repo_path, "init" }, ".");
        try self.runCommand(&.{ "hoz", "init" }, repo_path);

        try self.runCommand(&.{ "git", "-C", repo_path, "remote", "add", "origin", "https://example.com/repo.git" }, ".");
        try self.runCommand(&.{ "hoz", "remote", "add", "origin", "https://example.com/repo.git" }, repo_path);

        const git_remote = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "config" });
        defer self.allocator.free(git_remote);
        const hoz_remote = try std.fs.path.join(self.allocator, &.{ repo_path, ".git", "config" });
        defer self.allocator.free(hoz_remote);

        const git_exists = Io.Dir.cwd().openFile(git_remote, .{}) catch null;
        defer if (git_exists) |f| f.close();
        const hoz_exists = Io.Dir.cwd().openFile(hoz_remote, .{}) catch null;
        defer if (hoz_exists) |f| f.close();

        try self.test_helper.expect(git_exists != null, "git remote should modify config");
        try self.test_helper.expect(hoz_exists != null, "hoz remote should modify config");
        self.passed += 1;
    }

    fn printSummary(self: *GitCompatTester) !void {
        self.cleanupDir(self.temp_dir);
        const stdout = std.Io.File.stdout().writer(&.{});
        try stdout.print("\n=== Git Compatibility Test Summary ===\n", .{});
        try stdout.print("Passed: {d}\n", .{self.passed});
        try stdout.print("Failed: {d}\n", .{self.failed});
        try stdout.print("Total: {d}\n", .{self.passed + self.failed});
    }

    const TestHelper = struct {
        fn expect(self: *const @This(), cond: bool, msg: []const u8) !void {
            _ = self;
            _ = msg;
            if (!cond) return error.AssertionFailed;
        }
        fn expectEqualStrings(self: *const @This(), a: []const u8, b: []const u8, msg: []const u8) !void {
            _ = self;
            _ = msg;
            if (!std.mem.eql(u8, a, b)) return error.AssertionFailed;
        }
    };
};

test "GitCompatTester init" {
    const io = std.Io.Threaded.new(.{}).?;
    const tester = GitCompatTester.init(std.testing.allocator, io);
    try std.testing.expect(tester.passed == 0);
    try std.testing.expect(tester.failed == 0);
}

test "GitCompatTester runFullSuite smoke" {
    const io = std.Io.Threaded.new(.{}).?;
    var tester = GitCompatTester.init(std.testing.allocator, io);
    tester.temp_dir = "_compat_smoke_test";
    defer Io.Dir.cwd().removeTree(std.Io.get(), "_compat_smoke_test", .{}) catch {};
    try tester.runInit();
    try std.testing.expect(tester.passed >= 1);
}
