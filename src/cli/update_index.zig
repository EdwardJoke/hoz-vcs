//! update-index command implementation
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

const Index = @import("../index/index.zig").Index;
const IndexEntry = @import("../index/index_entry.zig").IndexEntry;
const ObjectStore = @import("../object/store.zig").ObjectStore;
const OID = @import("../object/oid.zig").OID;

pub const UpdateIndex = struct {
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    style: OutputStyle,
    index: Index,
    object_store: ObjectStore,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) !UpdateIndex {
        const index = Index.init(allocator);
        const object_store = ObjectStore.init(allocator);
        return .{
            .allocator = allocator,
            .io = io,
            .writer = writer,
            .style = style,
            .index = index,
            .object_store = object_store,
        };
    }

    pub fn deinit(self: *UpdateIndex) void {
        self.index.deinit();
        self.object_store.deinit();
    }

    pub fn run(self: *UpdateIndex, args: []const []const u8) !void {
        var out = Output.init(self.writer, self.style, self.allocator);

        // Read existing index
        self.index = try Index.read(self.allocator, self.io, "./index");

        var i: usize = 0;
        var add: bool = false;
        var remove: bool = false;
        var refresh: bool = false;

        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--add")) {
                add = true;
            } else if (std.mem.eql(u8, arg, "--remove")) {
                remove = true;
            } else if (std.mem.eql(u8, arg, "--refresh")) {
                refresh = true;
            } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
                if (i + 3 >= args.len) {
                    try out.errorMessage("--cacheinfo requires mode, oid, and path", .{});
                    return error.InvalidArgument;
                }
                i += 1;
                const mode = try std.fmt.parseInt(u32, args[i], 8);
                i += 1;
                const oid_arg = args[i];
                i += 1;
                const path = args[i];

                if (oid_arg.len != 40) {
                    try out.errorMessage("OID must be 40 characters", .{});
                    return error.InvalidArgument;
                }
                const oid = try OID.fromHex(oid_arg);

                // Create minimal index entry
                const entry = IndexEntry{
                    .ctime_sec = 0,
                    .ctime_nsec = 0,
                    .mtime_sec = 0,
                    .mtime_nsec = 0,
                    .dev = 0,
                    .ino = 0,
                    .mode = mode,
                    .uid = 0,
                    .gid = 0,
                    .file_size = 0,
                    .oid = oid,
                    .flags = 0,
                };
                try self.index.addEntry(entry, path);
            } else if (arg[0] == '-') {
                try out.errorMessage("Unknown option: {s}", .{arg});
                return error.InvalidArgument;
            } else {
                const path = arg;
                if (add) {
                    try self.addFileToIndex(path);
                } else if (remove) {
                    try self.index.removeEntry(path);
                } else if (refresh) {
                    try self.refreshEntry(path);
                } else {
                    try self.addFileToIndex(path);
                }
            }
        }

        // Write updated index
        try self.index.write(self.io, "./index");
    }

    fn addFileToIndex(self: *UpdateIndex, path: []const u8) !void {
        // Read file content
        // For now, skip actual file reading and create minimal entry
        var oid_bytes: [20]u8 = undefined;
        @memset(&oid_bytes, 0);
        const oid = OID{ .bytes = oid_bytes };

        const entry = IndexEntry{
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = 0,
            .mode = 0o100644,
            .uid = 0,
            .gid = 0,
            .file_size = 0,
            .oid = oid,
            .flags = 0,
        };
        try self.index.addEntry(entry, path);
    }

    fn refreshEntry(_: *UpdateIndex, _: []const u8) !void {
        // For now, just return
    }
};
