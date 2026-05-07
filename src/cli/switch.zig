const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const BranchSwitcher = @import("../checkout/switch.zig").BranchSwitcher;
const RefStore = @import("../ref/store.zig").RefStore;

pub const SwitchOptions = struct {
    create: bool = false,
    force_create: bool = false,
    detach: bool = false,
    force: bool = false,
    track: bool = false,
    guess: bool = false,
};

pub const Switch = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: SwitchOptions,
    target: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *std.Io.Writer, style: OutputStyle) Switch {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
            .target = null,
        };
    }

    pub fn run(self: *Switch, args: []const []const u8) !void {
        self.parseArgs(args);

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        const target = self.target orelse {
            try self.output.errorMessage("Usage: hoz switch <branch>", .{});
            return;
        };

        var ref_store = RefStore.init(git_dir, self.allocator, self.io);
        const sw_opts = @import("../checkout/switch.zig").SwitchOptions{
            .create_branch = self.options.create,
            .force_create = self.options.force_create,
            .detach = self.options.detach,
            .force = self.options.force,
        };

        var switcher = BranchSwitcher.init(self.allocator, self.io, &ref_store, sw_opts, ".git");

        if (self.options.create) {
            const result = try switcher.createAndSwitch(target);
            if (result.success) {
                try self.output.successMessage("Switched to a new branch '{s}'", .{target});
            } else {
                try self.output.errorMessage("Failed to create and switch to branch '{s}'", .{target});
            }
        } else if (self.options.detach) {
            try self.output.errorMessage("switch --detach requires a commit OID", .{});
        } else {
            const result = try switcher.@"switch"(target);
            if (result.success) {
                try self.output.successMessage("Switched to branch '{s}'", .{target});
            } else {
                try self.output.errorMessage("Failed to switch to '{s}'", .{target});
            }
        }
    }

    fn parseArgs(self: *Switch, args: []const []const u8) void {
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--create")) {
                self.options.create = true;
            } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--force-create")) {
                self.options.force_create = true;
                self.options.create = true;
            } else if (std.mem.eql(u8, arg, "--detach")) {
                self.options.detach = true;
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                self.options.force = true;
            } else if (std.mem.eql(u8, arg, "--track")) {
                self.options.track = true;
            } else if (std.mem.eql(u8, arg, "--guess")) {
                self.options.guess = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                self.target = arg;
            }
        }
    }
};
