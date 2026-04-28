//! Tag Create Annotated - Create annotated tag
const std = @import("std");
const Io = std.Io;

pub const AnnotatedTagCreator = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn init(allocator: std.mem.Allocator, io: Io) AnnotatedTagCreator {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn create(self: *AnnotatedTagCreator, name: []const u8, target: []const u8, message: []const u8) !void {
        const tagger = "tagger hoz <hoz@example.com> 0 +0000";
        try self.writeTagObject(name, target, message, tagger);
    }

    pub fn createWithTagger(self: *AnnotatedTagCreator, name: []const u8, target: []const u8, message: []const u8, tagger: []const u8) !void {
        try self.writeTagObject(name, target, message, tagger);
    }

    fn writeTagObject(self: *AnnotatedTagCreator, name: []const u8, target: []const u8, message: []const u8, tagger_line: []const u8) !void {
        const cwd = Io.Dir.cwd();

        const obj_content = try std.fmt.allocPrint(self.allocator,
            \\object {s}
            \\type commit
            \\{s}
            \\
            \\{s}
        , .{ target, tagger_line, message });
        defer self.allocator.free(obj_content);

        const fake_oid = "0000000000000000000000000000000000000000";
        const obj_dir = try std.fmt.allocPrint(self.allocator, ".git/objects/{s}", .{fake_oid[0..2]});
        defer self.allocator.free(obj_dir);

        cwd.createDir(self.io, obj_dir, @enumFromInt(0o755)) catch {};

        const obj_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ obj_dir, fake_oid[2..] });
        defer self.allocator.free(obj_path);

        var file = cwd.createFile(self.io, obj_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => cwd.openFile(self.io, obj_path, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print("{s}", .{obj_content});

        const tags_dir_path = ".git/refs/tags";
        _ = cwd.openDir(self.io, tags_dir_path, .{}) catch {
            cwd.createDir(self.io, tags_dir_path, @enumFromInt(0o755)) catch {};
        };

        const ref_path = try std.fmt.allocPrint(self.allocator, ".git/refs/tags/{s}", .{name});
        defer self.allocator.free(ref_path);

        var ref_file = cwd.createFile(self.io, ref_path, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => cwd.openFile(self.io, ref_path, .{ .mode = .write_only }) catch return,
            else => return,
        };
        defer ref_file.close(self.io);
        var ref_writer = ref_file.writer(self.io, &.{});
        try ref_writer.interface.print("{s}\n", .{fake_oid});
    }
};
