const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const ConfigReader = @import("../config/read_write.zig").ConfigReader;
const ConfigWriter = @import("../config/read_write.zig").ConfigWriter;
const ConfigGetter = @import("../config/get.zig").ConfigGetter;
const ConfigSetter = @import("../config/set.zig").ConfigSetter;

pub const ConfigAction = enum {
    get,
    set,
    unset,
    list,
    add,
    rename_section,
    remove_section,
    get_regexp,
    get_urlmatch,
};

pub const ConfigScope = enum {
    local,
    global,
    system,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    action: ConfigAction,
    scope: ConfigScope,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Config {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .action = .get,
            .scope = .local,
        };
    }

    pub fn run(self: *Config, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.output.errorMessage("Usage: hoz config <get|set|unset|list> [options] <key> [value]", .{});
            return;
        }

        const subcmd = args[0];
        const rest = if (args.len > 1) args[1..] else &.{};

        if (std.mem.eql(u8, subcmd, "get") or std.mem.eql(u8, subcmd, "get-all") or std.mem.eql(u8, subcmd, "--get")) {
            self.action = .get;
            try self.runGet(rest);
        } else if (std.mem.eql(u8, subcmd, "set") or std.mem.eql(u8, subcmd, "--set") or std.mem.eql(u8, subcmd, "--add")) {
            self.action = if (std.mem.eql(u8, subcmd, "--add")) .add else .set;
            try self.runSet(rest);
        } else if (std.mem.eql(u8, subcmd, "unset") or std.mem.eql(u8, subcmd, "--unset")) {
            self.action = .unset;
            try self.runUnset(rest);
        } else if (std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "-l") or std.mem.eql(u8, subcmd, "--list")) {
            self.action = .list;
            try self.runList(rest);
        } else if (std.mem.eql(u8, subcmd, "--rename-section")) {
            self.action = .rename_section;
            try self.output.infoMessage("config rename-section: requires old_name new_name", .{});
        } else if (std.mem.eql(u8, subcmd, "--remove-section")) {
            self.action = .remove_section;
            try self.output.infoMessage("config remove-section: requires section name", .{});
        } else if (std.mem.eql(u8, subcmd, "--get-regexp")) {
            self.action = .get_regexp;
            try self.runGetRegexp(rest);
        } else if (std.mem.eql(u8, subcmd, "--get-urlmatch")) {
            self.action = .get_urlmatch;
            try self.output.infoMessage("config --get-urlmatch: requires name URL", .{});
        } else if (!std.mem.startsWith(u8, subcmd, "-")) {
            try self.runGet(args);
        } else if (std.mem.startsWith(u8, subcmd, "--global")) {
            self.scope = .global;
            const inner = if (args.len > 1) args[1..] else &.{};
            try self.run(inner);
        } else if (std.mem.startsWith(u8, subcmd, "--local")) {
            self.scope = .local;
            const inner = if (args.len > 1) args[1..] else &.{};
            try self.run(inner);
        } else if (std.mem.startsWith(u8, subcmd, "--system")) {
            self.scope = .system;
            const inner = if (args.len > 1) args[1..] else &.{};
            try self.run(inner);
        } else {
            try self.output.errorMessage("Unknown config action: {s}", .{subcmd});
        }
    }

    fn runGet(self: *Config, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.output.errorMessage("config: missing key argument for 'get'", .{});
            return;
        }

        const key = args[0];

        var getter = ConfigGetter.init(self.allocator);
        const value = try getter.get(key);

        if (value) |v| {
            try self.output.writer.print("{s}\n", .{v});
        } else {
            try self.output.errorMessage("Key '{s}' not found", .{key});
        }
    }

    fn runSet(self: *Config, args: []const []const u8) !void {
        if (args.len < 2) {
            try self.output.errorMessage("config: need key and value arguments for 'set'", .{});
            return;
        }

        const key = args[0];
        const value = args[1];

        var setter = ConfigSetter.init(self.allocator);

        switch (self.scope) {
            .global => try setter.setGlobal(key, value),
            .system => try setter.setSystem(key, value),
            .local => try setter.set(key, value),
        }

        try self.output.successMessage("Set {s}={s} ({s})", .{ key, value, @tagName(self.scope) });
    }

    fn runUnset(self: *Config, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.output.errorMessage("config: missing key argument for 'unset'", .{});
            return;
        }

        const key = args[0];
        var setter = ConfigSetter.init(self.allocator);
        try setter.unset(key);

        try self.output.successMessage("Unset {s}", .{key});
    }

    fn runList(self: *Config, args: []const []const u8) !void {
        _ = args;

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var reader = ConfigReader.init(self.allocator);
        const lines = reader.read(self.io, ".git/config") catch |err| {
            if (err == error.FileNotFound) {
                try self.output.infoMessage("(empty)", .{});
                return;
            }
            return err;
        };
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }

        for (lines) |line| {
            try self.output.writer.print("{s}\n", .{line});
        }
    }

    fn runGetRegexp(self: *Config, args: []const []const u8) !void {
        if (args.len == 0) {
            try self.output.errorMessage("config: missing pattern for 'get-regexp'", .{});
            return;
        }

        const pattern = args[0];

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        var reader = ConfigReader.init(self.allocator);
        const lines = reader.read(self.io, ".git/config") catch |err| {
            if (err == error.FileNotFound) return err;
            return err;
        };
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }

        for (lines) |line| {
            if (std.mem.indexOf(u8, line, pattern) != null) {
                try self.output.writer.print("{s}\n", .{line});
            }
        }
    }
};
