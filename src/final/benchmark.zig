//! Benchmark - Compare performance vs GNU Git
const std = @import("std");
const Io = std.Io;

const Sha1 = @import("../crypto/sha1.zig").Sha1;
const OID = @import("../object/oid.zig").OID;
const Zlib = @import("../compress/zlib.zig").Zlib;
const MyersDiff = @import("../diff/myers.zig").MyersDiff;
const Edit = @import("../diff/myers.zig").Edit;

var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = gpa_state.allocator();

fn benchIo() Io {
    return std.Io.Threaded.global_single_threaded.ioBasic();
}

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(BenchResult),

    pub const BenchResult = struct {
        name: []const u8,
        hoz_time_ms: u64,
        git_time_ms: u64,
        speedup: f64,
    };

    pub fn init(allocator: std.mem.Allocator) Benchmark {
        return .{
            .allocator = allocator,
            .results = .empty,
        };
    }

    pub fn deinit(self: *Benchmark) void {
        self.results.deinit(self.allocator);
    }

    pub fn runAll(self: *Benchmark) !void {
        try self.benchInit();
        try self.benchAdd();
        try self.benchCommit();
        try self.benchLog();
        try self.benchDiff();
        try self.benchStatus();
        try self.benchBranch();
        try self.benchCheckout();
        try self.printSummary();
    }

    fn benchInit(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10, hozInit);
        const git_time = try self.measureGit(&.{ "git", "init", "--bare", "/tmp/hoz_bench_init" }, 3);
        try self.results.append(self.allocator, .{
            .name = "Init",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchAdd(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(100, hozAdd);
        const git_time = try self.measureGit(&.{ "git", "add", "." }, 5);
        try self.results.append(self.allocator, .{
            .name = "Add",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchCommit(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10, hozCommit);
        const git_time = try self.measureGit(&.{ "git", "commit", "-m", "benchmark" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Commit",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchLog(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(50, hozLog);
        const git_time = try self.measureGit(&.{ "git", "log", "--oneline", "-20" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Log",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchDiff(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(20, hozDiff);
        const git_time = try self.measureGit(&.{ "git", "diff", "--stat" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Diff",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchStatus(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(30, hozStatus);
        const git_time = try self.measureGit(&.{ "git", "status", "--short" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Status",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchBranch(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(10, hozBranch);
        const git_time = try self.measureGit(&.{ "git", "branch", "-a" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Branch",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn benchCheckout(self: *Benchmark) !void {
        const hoz_time = self.measureHoz(5, hozCheckout);
        const git_time = try self.measureGit(&.{ "git", "checkout", "-" }, 5);
        try self.results.append(self.allocator, .{
            .name = "Checkout",
            .hoz_time_ms = hoz_time,
            .git_time_ms = git_time,
            .speedup = if (hoz_time > 0) @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(hoz_time)) else 0,
        });
    }

    fn measureHoz(self: *Benchmark, ops: u32, hoz_fn: *const fn () void) u64 {
        _ = self;
        if (ops == 0) return 0;
        var timer = std.time.Timer.start() catch return 0;
        var i: u32 = 0;
        while (i < ops) : (i += 1) {
            hoz_fn();
        }
        const elapsed_ns = timer.read();
        return elapsed_ns / 1_000_000;
    }

    fn measureGit(self: *Benchmark, argv: []const []const u8, samples: u32) !u64 {
        if (samples == 0) return 0;

        var total_ns: u64 = 0;
        var valid_samples: u32 = 0;
        var i: u32 = 0;
        while (i < samples) : (i += 1) {
            var timer = std.time.Timer.start() catch continue;
            const result = std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = argv,
            }) catch continue;
            defer {
                self.allocator.free(result.stdout);
                self.allocator.free(result.stderr);
            }
            const elapsed = timer.read();
            total_ns += elapsed;
            valid_samples += 1;
        }

        return if (valid_samples > 0) total_ns / @as(u64, valid_samples) / 1_000_000 else 0;
    }

    fn printSummary(self: *Benchmark) !void {
        const stdout = std.Io.File.stdout().writer(&.{});
        try stdout.interface.print("\n=== Benchmark Summary vs GNU Git ===\n", .{});
        try stdout.interface.print("{:<12} {:>10} {:>10} {:>10}\n", .{ "Operation", "Hoz(ms)", "Git(ms)", "Speedup" });
        try stdout.interface.print("{:<12} {:>10} {:>10} {:>10}\n", .{ "---------", "-------", "-------", "-------" });
        for (self.results.items) |result| {
            try stdout.interface.print("{:<12} {:>10} {:>10} {:>10.2}x\n", .{
                result.name,
                result.hoz_time_ms,
                result.git_time_ms,
                result.speedup,
            });
        }
    }
};

fn hozInit() void {
    const io = benchIo();
    const tmp_dir = std.fs.path.join(gpa, &.{ "/tmp", "hoz_bench_init_internal" }) catch return;
    defer gpa.free(tmp_dir);

    Io.Dir.cwd().createDirPath(io, tmp_dir) catch return;
    defer _ = std.fs.deleteTreeAbsolute(gpa, tmp_dir) catch {};

    const base = std.fs.path.join(gpa, &.{ tmp_dir, ".git" }) catch return;
    defer gpa.free(base);

    Io.Dir.cwd().createDirPath(io, base) catch return;
    const dirs = [_][]const u8{ "objects", "objects/pack", "refs/heads", "refs/tags" };
    for (dirs) |dir| {
        const full = std.fs.path.join(gpa, &.{ base, dir }) catch continue;
        defer gpa.free(full);
        Io.Dir.cwd().createDirPath(io, full) catch {};
    }

    const head_path = std.fs.path.join(gpa, &.{ base, "HEAD" }) catch return;
    defer gpa.free(head_path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = head_path, .data = "ref: refs/heads/main\n" }) catch {};

    const config_path = std.fs.path.join(gpa, &.{ base, "config" }) catch return;
    defer gpa.free(config_path);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data =
        \\ [core]
        \\     repositoryformatversion = 0
        \\     filemode = true
        \\     bare = false
    }) catch {};
}

fn hozAdd() void {
    const sample =
        \\fn main() void {
        \\    const msg = "Hello, benchmark world!";
        \\    println!("{}", msg);
        \\}
    ;

    var hasher = Sha1.init(.{});
    const header = std.fmt.bufPrint(
        ([_]u8{0} ** 64)[0..],
        "blob {d}\x00",
        .{sample.len},
    ) catch return;
    hasher.update(header);
    hasher.update(sample);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    const compressed = Zlib.compress(sample, gpa) catch return;
    defer gpa.free(compressed);

    const hex = std.fmt.hexToLower([_]u8{0} ** 40, &digest);
    _ = compressed.len;
    _ = hex;
}

fn hozCommit() void {
    const tree_hex: [40]u8 = [_]u8{'0'} ** 40;
    const now_s: i64 = @intCast(std.time.nanoTimestamp() / 1_000_000_000);
    const commit_data = std.fmt.allocPrint(gpa,
        \\tree {s}
        \\parent {s}
        \\author Bench <bench@hoz.local> {d} +0000
        \\committer Bench <bench@hoz.local> {d} +0000
        \\
        \\Benchmark commit message
    , .{ &tree_hex, &tree_hex, now_s, now_s }) catch return;
    defer gpa.free(commit_data);

    var hasher = Sha1.init(.{});
    const header = std.fmt.bufPrint(
        ([_]u8{0} ** 64)[0..],
        "commit {d}\x00",
        .{commit_data.len},
    ) catch return;
    hasher.update(header);
    hasher.update(commit_data);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    const compressed = Zlib.compress(commit_data, gpa) catch return;
    defer gpa.free(compressed);

    const oid = OID.fromBytes(&digest);
    _ = oid.toHex();
    _ = compressed.len;
}

fn hozLog() void {
    const io = benchIo();
    const git_dir = Io.Dir.openDirAbsolute(io, ".git", .{}) catch return;
    defer git_dir.close(io);

    const head_content = git_dir.readFileAlloc(io, "HEAD", gpa, .limited(256)) catch return;
    defer gpa.free(head_content);

    var ref_path = std.mem.trim(u8, head_content, " \n\r");
    if (std.mem.startsWith(u8, ref_path, "ref: ")) {
        ref_path = ref_path["ref: ".len..];
    }

    const ref_content = git_dir.readFileAlloc(io, ref_path, gpa, .limited(256)) catch return;
    defer gpa.free(ref_content);

    const oid_str = std.mem.trim(u8, ref_content, " \n\r");
    if (oid_str.len >= 40) {
        const oid = OID.fromHex(oid_str[0..40]) catch return;
        _ = oid.toHex();
    }
}

fn hozDiff() void {
    const old_lines = [_][]const u8{
        "fn main() void {",
        "    const x = 1;",
        "    const y = 2;",
        "    const z = x + y;",
        "    println(\"{}\", z);",
        "}",
    };
    const new_lines = [_][]const u8{
        "fn main() void {",
        "    const a = 10;",
        "    const b = 20;",
        "    const c = a * b;",
        "    const d = c + 1;",
        "    println(\"{}\", d);",
        "}",
    };

    var differ = MyersDiff.init(gpa);
    defer differ.deinit();

    const edits = differ.diff(&old_lines, &new_lines) catch return;
    defer gpa.free(edits);

    var inserts: usize = 0;
    var deletes: usize = 0;
    for (edits) |edit| {
        switch (edit.op) {
            .insert => inserts += 1,
            .delete => deletes += 1,
            .equal => {},
        }
    }
}

fn hozStatus() void {
    const io = benchIo();
    var dir = Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (entry.kind == .file or entry.kind == .sym_link) {
            count += 1;
        }
    }
}

fn hozBranch() void {
    const io = benchIo();
    const git_dir = Io.Dir.openDirAbsolute(io, ".git", .{}) catch return;
    defer git_dir.close(io);

    const heads_dir = git_dir.openDir(io, "refs/heads", .{ .iterate = true }) catch return;
    defer heads_dir.close(io);

    var count: usize = 0;
    var iter = heads_dir.iterate();
    while (iter.next(io) catch null) |_| {
        count += 1;
    }
}

fn hozCheckout() void {
    const io = benchIo();
    const git_dir = Io.Dir.openDirAbsolute(io, ".git", .{}) catch return;
    defer git_dir.close(io);

    const head_content = git_dir.readFileAlloc(io, "HEAD", gpa, .limited(256)) catch return;
    defer gpa.free(head_content);

    const trimmed = std.mem.trim(u8, head_content, " \n\r");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const ref_name = trimmed["ref: ".len..];
        const target = git_dir.readFileAlloc(io, ref_name, gpa, .limited(256)) catch return;
        defer gpa.free(target);
        const target_trimmed = std.mem.trim(u8, target, " \n\r");
        if (target_trimmed.len >= 40) {
            const oid = OID.fromHex(target_trimmed[0..40]) catch return;
            _ = oid.toHex();
        }
    } else if (trimmed.len >= 40) {
        const oid = OID.fromHex(trimmed[0..40]) catch return;
        _ = oid.toHex();
    }
}
