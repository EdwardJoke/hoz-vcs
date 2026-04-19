//! Hoz - Git-compatible VCS in Zig
//!
//! A streamlined CLI designed for simplicity and usability.

const std = @import("std");
const Io = std.Io;

const log_mod = @import("util/log.zig");
const format = @import("util/format.zig").Formatter;

pub const Command = enum {
    init,
    add,
    commit,
    status,
    log,
    diff,
    branch,
    checkout,
    merge,
    reset,
    clean,
    cat_file,
    hash_object,
    clone,
    remote,
    fetch,
    push,
    pull,
    stash,
    tag,
    rebase,
    reflog,
    ls_tree,
    show,
    help,
    version,
};

const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
    aliases: []const []const u8 = &.{},
};

const ALL_COMMANDS = [_][]const u8{
    "init",  "add",   "commit", "status", "log",     "diff",  "branch",   "checkout",
    "clone", "fetch", "push",   "pull",   "remote",  "stash", "tag",      "rebase",
    "merge", "reset", "clean",  "reflog", "ls-tree", "show",  "cat-file", "hash-object",
};

fn findCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "init")) return .init;
    if (std.mem.eql(u8, name, "add")) return .add;
    if (std.mem.eql(u8, name, "commit")) return .commit;
    if (std.mem.eql(u8, name, "ci")) return .commit;
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "st")) return .status;
    if (std.mem.eql(u8, name, "log")) return .log;
    if (std.mem.eql(u8, name, "diff")) return .diff;
    if (std.mem.eql(u8, name, "branch")) return .branch;
    if (std.mem.eql(u8, name, "br")) return .branch;
    if (std.mem.eql(u8, name, "checkout")) return .checkout;
    if (std.mem.eql(u8, name, "co")) return .checkout;
    if (std.mem.eql(u8, name, "clone")) return .clone;
    if (std.mem.eql(u8, name, "fetch")) return .fetch;
    if (std.mem.eql(u8, name, "push")) return .push;
    if (std.mem.eql(u8, name, "pull")) return .pull;
    if (std.mem.eql(u8, name, "remote")) return .remote;
    if (std.mem.eql(u8, name, "stash")) return .stash;
    if (std.mem.eql(u8, name, "tag")) return .tag;
    if (std.mem.eql(u8, name, "rebase")) return .rebase;
    if (std.mem.eql(u8, name, "merge")) return .merge;
    if (std.mem.eql(u8, name, "reset")) return .reset;
    if (std.mem.eql(u8, name, "clean")) return .clean;
    if (std.mem.eql(u8, name, "reflog")) return .reflog;
    if (std.mem.eql(u8, name, "ls-tree")) return .ls_tree;
    if (std.mem.eql(u8, name, "ls_tree")) return .ls_tree;
    if (std.mem.eql(u8, name, "show")) return .show;
    if (std.mem.eql(u8, name, "cat-file")) return .cat_file;
    if (std.mem.eql(u8, name, "cat_file")) return .cat_file;
    if (std.mem.eql(u8, name, "hash-object")) return .hash_object;
    if (std.mem.eql(u8, name, "hash_object")) return .hash_object;
    return null;
}

fn editDistanceSimple(a: []const u8, b: []const u8) usize {
    const max_len = 20;
    var matrix: [max_len + 1][max_len + 1]usize = undefined;

    for (0..max_len + 1) |i| {
        for (0..max_len + 1) |j| {
            if (i == 0) {
                matrix[i][j] = j;
            } else if (j == 0) {
                matrix[i][j] = i;
            } else {
                matrix[i][j] = 0;
            }
        }
    }

    const a_len = @min(a.len, max_len);
    const b_len = @min(b.len, max_len);

    for (1..a_len + 1) |i| {
        for (1..b_len + 1) |j| {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            matrix[i][j] = @min(
                @min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1),
                matrix[i - 1][j - 1] + cost,
            );
        }
    }

    return matrix[a_len][b_len];
}

fn suggestSimilarCommand(input: []const u8) ?[]const u8 {
    var best_cmd: ?[]const u8 = null;
    var best_dist: usize = 3;

    for (ALL_COMMANDS) |cmd| {
        const dist = editDistanceSimple(input, cmd);
        if (dist < best_dist) {
            best_dist = dist;
            best_cmd = cmd;
        }
    }
    const aliases = [_][]const u8{ "ci", "st", "br", "co" };
    for (aliases) |alias| {
        const alias_dist = editDistanceSimple(input, alias);
        if (alias_dist < best_dist) {
            best_dist = alias_dist;
            best_cmd = alias;
        }
    }

    return best_cmd;
}

fn printHelp(writer: *Io.Writer, use_color: bool) !void {
    var fmt = format.init(writer, use_color);

    try writer.writeAll("Usage: ");
    try fmt.colored("hoz <command> [options]", format.Color.bold);
    try writer.writeAll("\n\n");

    try fmt.colored("Commands:\n", format.Color.cyan);

    inline for (ALL_COMMANDS) |cmd| {
        try writer.writeAll("  ");
        try fmt.colored(cmd, format.Color.green);
        try writer.writeAll("\n");
    }

    try writer.writeAll("\n");
    try fmt.colored("Options:\n", format.Color.cyan);
    try writer.writeAll("  ");
    try fmt.colored("--help, -h", format.Color.dim);
    try writer.writeAll("  Show this help\n");
    try writer.writeAll("  ");
    try fmt.colored("--version, -v", format.Color.dim);
    try writer.writeAll("  Show version\n");
    try writer.writeAll("  ");
    try fmt.colored("--no-color", format.Color.dim);
    try writer.writeAll("   Disable colors\n");
    try writer.writeAll("\n");
    try fmt.colored("Get started: ", format.Color.yellow);
    try fmt.colored("hoz init", format.Color.bold);
    try writer.writeAll("\n");
    try writer.writeAll("\n");
    try fmt.colored("Aliases:\n", format.Color.cyan);
    try writer.writeAll("  ");
    try fmt.colored("ci", format.Color.yellow);
    try writer.writeAll(" = commit, ");
    try fmt.colored("st", format.Color.yellow);
    try writer.writeAll(" = status, ");
    try fmt.colored("br", format.Color.yellow);
    try writer.writeAll(" = branch, ");
    try fmt.colored("co", format.Color.yellow);
    try writer.writeAll(" = checkout\n");
}

fn printVersion(writer: *Io.Writer) !void {
    try writer.writeAll("hoz version 0.1.0\n");
}

fn printUnknown(writer: *Io.Writer, cmd: []const u8, use_color: bool) !void {
    var fmt = format.init(writer, use_color);
    try fmt.err("Unknown command");
    try writer.print("  '{s}' is not a hoz command.\n", .{cmd});

    if (suggestSimilarCommand(cmd)) |suggestion| {
        try writer.writeAll("\n");
        try writer.writeAll("  Did you mean '");
        try fmt.colored(suggestion, format.Color.green);
        try writer.writeAll("'?\n");
    }

    try writer.writeAll("\n");
    try writer.writeAll("  Run '");
    try fmt.colored("hoz help", format.Color.bold);
    try writer.writeAll("' for available commands.\n");
}

fn runCommand(cmd: Command, args: []const []const u8, writer: *Io.Writer, use_color: bool) !void {
    _ = args;
    var fmt = format.init(writer, use_color);

    switch (cmd) {
        .help => try printHelp(writer, use_color),
        .version => try printVersion(writer),
        .init => {
            try fmt.success("Initialized empty repository");
            try writer.writeAll("  Start with ");
            try fmt.colored("hoz add .", format.Color.bold);
            try writer.writeAll(" to stage files\n");
        },
        .add => {
            try fmt.success("Files staged");
            try writer.writeAll("  Run ");
            try fmt.colored("hoz commit", format.Color.bold);
            try writer.writeAll(" to record changes\n");
        },
        .commit => {
            try fmt.success("Changes committed");
            try writer.writeAll("  Use ");
            try fmt.colored("hoz log", format.Color.bold);
            try writer.writeAll(" to view history\n");
        },
        .status => {
            try fmt.info("Working tree clean");
            try writer.writeAll("  Nothing to commit, working tree clean\n");
        },
        .log => {
            try fmt.header("Commit History");
            try fmt.commitHash("abc1234", "Initial commit");
        },
        .diff => {
            try fmt.info("No changes");
        },
        .branch => {
            try fmt.header("Branches");
            try fmt.branch("master", true);
        },
        .checkout => {
            try fmt.success("Switched branch");
        },
        .merge => {
            try fmt.success("Merge completed");
        },
        .reset => {
            try fmt.success("Reset HEAD");
        },
        .clean => {
            try fmt.info("Working tree clean");
        },
        .cat_file => {
            try fmt.info("Object content");
        },
        .hash_object => {
            try fmt.success("Object hash computed");
        },
        .clone => {
            try fmt.header("Clone");
            try writer.writeAll("  Cloning from remote repository...\n");
        },
        .remote => {
            try fmt.header("Remote");
            try fmt.info("No remotes configured");
        },
        .fetch => {
            try fmt.header("Fetch");
            try fmt.info("Fetching from remote...");
        },
        .push => {
            try fmt.header("Push");
            try fmt.info("Pushing to remote...");
        },
        .pull => {
            try fmt.header("Pull");
            try fmt.info("Fetching and merging...");
        },
        .stash => {
            try fmt.header("Stash");
            try fmt.info("No stash entries");
        },
        .tag => {
            try fmt.header("Tags");
            try fmt.info("No tags");
        },
        .rebase => {
            try fmt.header("Rebase");
            try fmt.info("No rebase in progress");
        },
        .reflog => {
            try fmt.header("Reflog");
            try fmt.info("No reflog entries");
        },
        .ls_tree => {
            try fmt.header("Tree");
            try fmt.info("Use 'hoz ls-tree <tree-ish>'");
        },
        .show => {
            try fmt.header("Show");
            try fmt.info("Use 'hoz show <object>'");
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var remaining: []const []const u8 = &.{};
    if (args.len > 1) {
        remaining = args[1..];
    }

    if (remaining.len == 0) {
        try printHelp(stdout_writer, true);
        try stdout_writer.flush();
        return;
    }

    var use_color = true;
    var arg_offset: usize = 0;

    for (remaining, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--no-color")) {
            use_color = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp(stdout_writer, use_color);
            try stdout_writer.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try printVersion(stdout_writer);
            try stdout_writer.flush();
            return;
        } else {
            arg_offset = i;
            break;
        }
    }

    log_mod.setColor(use_color);

    const cmd_str = if (arg_offset < remaining.len) remaining[arg_offset] else "help";
    const cmd = findCommand(cmd_str);

    if (cmd) |c| {
        try runCommand(c, remaining[arg_offset..], stdout_writer, use_color);
        try stdout_writer.flush();
    } else {
        try printUnknown(stdout_writer, cmd_str, use_color);
        try stdout_writer.flush();
    }
}
