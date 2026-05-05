//! Git Notes - Add or inspect object notes
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;
const oid_mod = @import("../object/oid.zig");
const OID = oid_mod.OID;
const compress_mod = @import("../compress/zlib.zig");

pub const NotesAction = enum {
    add,
    show,
    list,
    remove,
};

pub const Notes = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    notes_ref: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) Notes {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .notes_ref = "refs/notes/commits",
        };
    }

    pub fn run(self: *Notes, args: []const []const u8) !void {
        if (args.len < 2) {
            try self.output.errorMessage("Usage: hoz notes <add|show|list|remove> [options] <object>", .{});
            return;
        }

        const action_str = args[1];
        const action = self.parseAction(action_str) orelse {
            try self.output.errorMessage("Unknown notes action: {s}. Use: add, show, list, remove", .{action_str});
            return;
        };

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository", .{});
            return;
        };
        defer git_dir.close(self.io);

        switch (action) {
            .add => try self.cmdAdd(git_dir, args[2..]),
            .show => try self.cmdShow(git_dir, args[2..]),
            .list => try self.cmdList(git_dir),
            .remove => try self.cmdRemove(git_dir, args[2..]),
        }
    }

    fn parseAction(_: *Notes, action: []const u8) ?NotesAction {
        if (std.mem.eql(u8, action, "add")) return .add;
        if (std.mem.eql(u8, action, "show")) return .show;
        if (std.mem.eql(u8, action, "list")) return .list;
        if (std.mem.eql(u8, action, "remove") or std.mem.eql(u8, action, "delete")) return .remove;
        return null;
    }

    fn cmdAdd(self: *Notes, git_dir: Io.Dir, args: []const []const u8) !void {
        var object: ?[]const u8 = null;
        var message: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
                i += 1;
                message = args[i];
            } else if (!std.mem.startsWith(u8, args[i], "-")) {
                object = args[i];
            }
        }

        const obj = object orelse {
            try self.output.errorMessage("Missing object argument. Usage: hoz notes add [-m msg] <object>", .{});
            return;
        };

        const oid = OID.fromHex(obj) catch {
            try self.output.errorMessage("Invalid object ID: {s}", .{obj});
            return;
        };

        const note_text = message orelse "Note added via hoz";

        self.writeNote(git_dir, oid, note_text) catch |err| {
            try self.output.errorMessage("Failed to add note: {}", .{err});
            return;
        };

        try self.output.section("Notes");
        try self.output.item("object", obj);
        try self.output.successMessage("Note added", .{});
    }

    fn cmdShow(self: *Notes, git_dir: Io.Dir, args: []const []const u8) !void {
        const obj = if (args.len > 0) args[0] else null;

        const target = obj orelse {
            try self.output.errorMessage("Missing object argument. Usage: hoz notes show <object>", .{});
            return;
        };

        const oid = OID.fromHex(target) catch {
            try self.output.errorMessage("Invalid object ID: {s}", .{target});
            return;
        };

        const note = self.readNote(git_dir, oid) catch |err| {
            if (err == error.FileNotFound or err == error.NoteNotFound) {
                try self.output.infoMessage("No note found for object {s}", .{target});
                return;
            }
            try self.output.errorMessage("Failed to read note: {}", .{err});
            return;
        };
        defer self.allocator.free(note);

        try self.output.section("Notes");
        try self.output.item("object", target);
        try self.output.writer.print("\n{s}\n", .{note});
    }

    fn cmdList(self: *Notes, git_dir: Io.Dir) !void {
        const notes_tree_oid = self.readNotesRef(git_dir) orelse {
            try self.output.infoMessage("No notes found", .{});
            return;
        };

        var all_notes: []NoteEntry = &.{};
        var notes_owned = false;
        all_notes = self.listAllNotes(git_dir, notes_tree_oid) catch |err| {
            try self.output.errorMessage("Failed to list notes: {}", .{err});
            return;
        };
        notes_owned = true;
        defer if (notes_owned) {
            for (all_notes) |n| {
                self.allocator.free(n.object_hex);
                self.allocator.free(n.note_text);
            }
            self.allocator.free(all_notes);
        };

        if (all_notes.len == 0) {
            try self.output.infoMessage("No notes found", .{});
            return;
        }

        try self.output.section("Notes");
        for (all_notes) |n| {
            try self.output.item("object", n.object_hex);
            const preview = if (n.note_text.len > 60) n.note_text[0..60] else n.note_text;
            try self.output.writer.print("    {s}\n", .{preview});
        }
    }

    fn cmdRemove(self: *Notes, git_dir: Io.Dir, args: []const []const u8) !void {
        const obj = if (args.len > 0) args[0] else null;

        const target = obj orelse {
            try self.output.errorMessage("Missing object argument. Usage: hoz notes remove <object>", .{});
            return;
        };

        const oid = OID.fromHex(target) catch {
            try self.output.errorMessage("Invalid object ID: {s}", .{target});
            return;
        };

        self.removeNote(git_dir, oid) catch |err| {
            if (err == error.FileNotFound or err == error.NoteNotFound) {
                try self.output.infoMessage("No note found for object {s}", .{target});
                return;
            }
            try self.output.errorMessage("Failed to remove note: {}", .{err});
            return;
        };

        try self.output.section("Notes");
        try self.output.item("object", target);
        try self.output.successMessage("Note removed", .{});
    }

    const NoteEntry = struct {
        object_hex: []u8,
        note_text: []u8,
    };

    const TreeEntry = struct {
        name: []const u8,
        oid: OID,
    };

    fn readNotesRef(self: *Notes, git_dir: Io.Dir) ?OID {
        const ref_path = self.notes_ref;
        var file = git_dir.openFile(self.io, ref_path, .{}) catch return null;
        defer file.close(self.io);

        var buf: [oid_mod.OID_HEX_SIZE + 2]u8 = undefined;
        var iovec: [1][]u8 = .{&buf};
        const bytes_read = file.readStreaming(self.io, &iovec) catch return null;
        const hex = std.mem.trim(u8, buf[0..bytes_read], "\r\n ");
        if (hex.len != oid_mod.OID_HEX_SIZE) return null;
        return OID.fromHex(hex) catch null;
    }

    fn writeNotesRef(self: *Notes, git_dir: Io.Dir, tree_oid: OID) !void {
        const hex = tree_oid.toHex();
        var file = try git_dir.createFile(self.io, self.notes_ref, .{});
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        try writer.interface.print("{s}\n", .{hex});
    }

    fn writeNote(self: *Notes, git_dir: Io.Dir, object_oid: OID, note_text: []const u8) !void {
        const blob_data = try std.fmt.allocPrint(self.allocator, "{s}\n", .{note_text});
        defer self.allocator.free(blob_data);

        const note_blob_oid = try self.writeBlob(git_dir, blob_data);
        const object_hex = try self.allocator.dupe(u8, &object_oid.toHex());

        var existing_entries = try std.ArrayList(TreeEntry).initCapacity(self.allocator, 4);
        defer {
            for (existing_entries.items) |e| self.allocator.free(e.name);
            existing_entries.deinit(self.allocator);
        }

        if (self.readNotesRef(git_dir)) |tree_oid| {
            _ = self.readTreeEntries(git_dir, tree_oid, &existing_entries) catch {};
        }

        var found = false;
        for (existing_entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, object_hex)) {
                entry.oid = note_blob_oid;
                found = true;
                break;
            }
        }
        if (!found) {
            try existing_entries.append(self.allocator, .{ .name = object_hex, .oid = note_blob_oid });
        }

        const new_tree_oid = try self.writeNotesTree(git_dir, existing_entries.items);
        try self.writeNotesRef(git_dir, new_tree_oid);
    }

    fn readNote(self: *Notes, git_dir: Io.Dir, object_oid: OID) ![]u8 {
        const tree_oid = self.readNotesRef(git_dir) orelse return error.NoteNotFound;

        const object_hex = object_oid.toHex();

        var entries = try std.ArrayList(TreeEntry).initCapacity(self.allocator, 4);
        defer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        try self.readTreeEntries(git_dir, tree_oid, &entries);

        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, &object_hex)) {
                return self.readBlob(git_dir, entry.oid);
            }
        }

        return error.NoteNotFound;
    }

    fn removeNote(self: *Notes, git_dir: Io.Dir, object_oid: OID) !void {
        const tree_oid = self.readNotesRef(git_dir) orelse return error.NoteNotFound;

        const object_hex = object_oid.toHex();

        var entries = try std.ArrayList(TreeEntry).initCapacity(self.allocator, 4);
        defer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        try self.readTreeEntries(git_dir, tree_oid, &entries);

        var idx: ?usize = null;
        for (entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, &object_hex)) {
                idx = i;
                break;
            }
        }

        if (idx == null) return error.NoteNotFound;

        _ = entries.orderedRemove(idx.?);
        self.allocator.free(entries.items[idx.?].name);

        if (entries.items.len == 0) {
            git_dir.deleteFile(self.io, self.notes_ref) catch {};
            return;
        }

        const new_tree_oid = try self.writeNotesTree(git_dir, entries.items);
        try self.writeNotesRef(git_dir, new_tree_oid);
    }

    fn listAllNotes(self: *Notes, git_dir: Io.Dir, tree_oid: OID) ![]NoteEntry {
        var entries = try std.ArrayList(TreeEntry).initCapacity(self.allocator, 8);
        defer {
            for (entries.items) |e| self.allocator.free(e.name);
            entries.deinit(self.allocator);
        }

        try self.readTreeEntries(git_dir, tree_oid, &entries);

        var result = try std.ArrayList(NoteEntry).initCapacity(self.allocator, entries.items.len);
        errdefer {
            for (result.items) |n| {
                self.allocator.free(n.object_hex);
                self.allocator.free(n.note_text);
            }
            result.deinit(self.allocator);
        }

        for (entries.items) |entry| {
            const note_text = self.readBlob(git_dir, entry.oid) catch continue;
            const obj_hex = try self.allocator.dupe(u8, entry.name);
            try result.append(self.allocator, .{ .object_hex = obj_hex, .note_text = note_text });
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn writeBlob(self: *Notes, git_dir: Io.Dir, data: []const u8) !OID {
        const header = try std.fmt.allocPrint(self.allocator, "blob {d}\x00", .{data.len});
        defer self.allocator.free(header);

        const combined = try std.mem.concat(self.allocator, u8, &.{ header, data });
        defer self.allocator.free(combined);

        const oid = @import("../object/oid.zig").oidFromContent(combined);

        const hex = oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        const obj_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_file);

        git_dir.createDirPath(self.io, obj_dir) catch return oid;

        const compressed = compress_mod.Zlib.compress(combined, self.allocator) catch return oid;
        defer self.allocator.free(compressed);

        var file = git_dir.createFile(self.io, obj_file, .{}) catch return oid;
        defer file.close(self.io);
        var writer = file.writer(self.io, &.{});
        writer.interface.writeAll(compressed) catch {
            file.close(self.io);
            return oid;
        };

        return oid;
    }

    fn readBlob(self: *Notes, git_dir: Io.Dir, oid: OID) ![]u8 {
        const hex = oid.toHex();
        const obj_path = try std.fmt.allocPrint(self.allocator, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_path);

        const compressed = git_dir.readFileAlloc(self.io, obj_path, self.allocator, .limited(1024 * 1024)) catch {
            return error.FileNotFound;
        };
        defer self.allocator.free(compressed);

        return compress_mod.Zlib.decompress(compressed, self.allocator) catch {
            return error.IoError;
        };
    }

    fn readTreeEntries(self: *Notes, git_dir: Io.Dir, tree_oid: OID, entries: *std.ArrayList(TreeEntry)) !void {
        const raw = self.readBlob(git_dir, tree_oid) catch return;
        defer self.allocator.free(raw);

        if (!std.mem.startsWith(u8, raw, "tree ")) return;

        var offset: usize = @as(usize, 5);
        while (offset < raw.len and raw[offset] != 0) : (offset += 1) {}
        offset += 1;

        while (offset < raw.len) {
            const space_idx = std.mem.indexOfScalarPos(u8, raw, offset, ' ') orelse break;
            const name_start = space_idx + 1;
            const null_idx = std.mem.indexOfScalarPos(u8, raw, name_start, 0) orelse break;
            const name = raw[name_start..null_idx];
            const oid_start = null_idx + 1;
            if (oid_start + 20 > raw.len) break;

            var oid_bytes: [oid_mod.OID_SIZE]u8 = undefined;
            @memcpy(&oid_bytes, raw[oid_start .. oid_start + 20]);

            const name_copy = try self.allocator.dupe(u8, name);
            try entries.append(self.allocator, .{ .name = name_copy, .oid = OID{ .bytes = oid_bytes } });

            offset = oid_start + 20;
        }
    }

    fn writeNotesTree(self: *Notes, git_dir: Io.Dir, entries: []const TreeEntry) !OID {
        var content = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
        defer content.deinit(self.allocator);

        for (entries) |entry| {
            try content.appendSlice(self.allocator, "100644 ");
            try content.appendSlice(self.allocator, entry.name);
            try content.append(self.allocator, 0);
            try content.appendSlice(self.allocator, &entry.oid.bytes);
        }

        const header = try std.fmt.allocPrint(self.allocator, "tree {d}\x00", .{content.items.len});
        defer self.allocator.free(header);

        const combined = try std.mem.concat(self.allocator, u8, &.{ header, content.items });
        defer self.allocator.free(combined);

        const tree_oid = @import("../object/oid.zig").oidFromContent(combined);

        const hex = tree_oid.toHex();
        const obj_dir = try std.fmt.allocPrint(self.allocator, "objects/{s}", .{hex[0..2]});
        defer self.allocator.free(obj_dir);
        const obj_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ hex[0..2], hex[2..] });
        defer self.allocator.free(obj_file);

        git_dir.createDirPath(self.io, obj_dir) catch return tree_oid;

        const compressed = compress_mod.Zlib.compress(combined, self.allocator) catch return tree_oid;
        defer self.allocator.free(compressed);

        var file = git_dir.createFile(self.io, obj_file, .{}) catch return tree_oid;
        defer file.close(self.io);
        var w = file.writer(self.io, &.{});
        w.interface.writeAll(compressed) catch {
            file.close(self.io);
            return tree_oid;
        };

        return tree_oid;
    }
};

test "Notes init" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);

    const notes = Notes.init(std.testing.allocator, io_instance.io(), &writer.interface, .{});
    _ = notes;
}

test "Notes parse actions" {
    var io_instance: Io.Threaded = .init_single_threaded;
    defer io_instance.deinit();

    var buf: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);

    var notes = Notes.init(std.testing.allocator, io_instance.io(), &writer.interface, .{});

    try std.testing.expect(notes.parseAction("add") == .add);
    try std.testing.expect(notes.parseAction("show") == .show);
    try std.testing.expect(notes.parseAction("list") == .list);
    try std.testing.expect(notes.parseAction("remove") == .remove);
    try std.testing.expect(notes.parseAction("delete") == .remove);
    try std.testing.expect(notes.parseAction("bad") == null);
}
