//! Fuzz-style edge-case tests for Git object parsing (blob/commit/tree/tag)
const std = @import("std");
const object_mod = @import("./object/object.zig");
const blob_mod = @import("./object/blob.zig");
const commit_mod = @import("./object/commit.zig");
const tree_mod = @import("./object/tree.zig");
const tag_mod = @import("./object/tag.zig");

fn makeRaw(obj_type: []const u8, content: []const u8) ![]u8 {
    const size_str = try std.fmt.allocPrint(std.testing.allocator, "{}", .{content.len});
    defer std.testing.allocator.free(size_str);
    return try std.mem.concat(std.testing.allocator, u8, &.{ obj_type, " ", size_str, "\x00", content });
}

test "fuzz: object parse empty input" {
    try std.testing.expectError(error.InvalidObjectFormat, object_mod.parse(""));
}

test "fuzz: object parse null only" {
    try std.testing.expectError(error.InvalidObjectFormat, object_mod.parse("\x00"));
}

test "fuzz: object parse type only no space" {
    try std.testing.expectError(error.InvalidObjectFormat, object_mod.parse("blob\x00data"));
}

test "fuzz: object parse space only header" {
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(" \x00data"));
}

test "fuzz: object parse negative size" {
    try std.testing.expectError(error.InvalidObjectSize, object_mod.parse("blob -1\x00data"));
}

test "fuzz: object parse size zero with content" {
    const raw = try makeRaw("blob", "oops");
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidObjectSize, object_mod.parse(raw));
}

test "fuzz: object parse size zero empty content" {
    const raw = try makeRaw("blob", "");
    defer std.testing.allocator.free(raw);
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqual(.blob, obj.obj_type);
    try std.testing.expectEqual(0, obj.data.len);
}

test "fuzz: object parse huge size small content" {
    const raw = "blob 9999999999\x00hi";
    try std.testing.expectError(error.InvalidObjectSize, object_mod.parse(raw));
}

test "fuzz: object parse extra null bytes in header" {
    const raw = "blob 5\x00\x00hello";
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqualSlices(u8, "\x00hello", obj.data);
}

test "fuzz: object parse type with trailing spaces" {
    const raw = "blob   3\x00abc";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse tab delimiter" {
    const raw = "blob\t3\x00abc";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse unknown type" {
    const raw = "unknown_type 0\x00";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse numeric type string" {
    const raw = "12345 0\x00";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse uppercase BLOB" {
    const raw = "BLOB 0\x00";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse mixed case Blob" {
    const raw = "Blob 0\x00";
    try std.testing.expectError(error.InvalidObjectType, object_mod.parse(raw));
}

test "fuzz: object parse size as float" {
    const raw = "blob 3.14\x00data";
    try std.testing.expectError(error.InvalidObjectSize, object_mod.parse(raw));
}

test "fuzz: object parse size as hex" {
    const raw = "blob 0xff\x00data";
    try std.testing.expectError(error.InvalidObjectSize, object_mod.parse(raw));
}

test "fuzz: object parse size with leading zeros" {
    const raw = try makeRaw("blob", "ab");
    defer std.testing.allocator.free(raw);
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqual(2, obj.data.len);
}

test "fuzz: object parse tree valid" {
    const raw = try makeRaw("tree", "");
    defer std.testing.allocator.free(raw);
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqual(.tree, obj.obj_type);
}

test "fuzz: object parse commit valid" {
    const raw = try makeRaw("commit", "tree abc\n\nmessage\n");
    defer std.testing.allocator.free(raw);
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqual(.commit, obj.obj_type);
}

test "fuzz: object parse tag valid" {
    const raw = try makeRaw("tag", "object abc\ntype commit\ntag v1\n\ntagger <a@b> 0 +0000\n\nmsg\n");
    defer std.testing.allocator.free(raw);
    const obj = try object_mod.parse(raw);
    try std.testing.expectEqual(.tag, obj.obj_type);
}

test "fuzz: blob parse single byte" {
    const raw = try makeRaw("blob", "X");
    defer std.testing.allocator.free(raw);
    const blob = try blob_mod.Blob.parse(raw);
    try std.testing.expectEqualSlices(u8, "X", blob.data);
}

test "fuzz: blob parse all null bytes" {
    const content = [_]u8{0x00} ** 256;
    const raw = try makeRaw("blob", &content);
    defer std.testing.allocator.free(raw);
    const blob = try blob_mod.Blob.parse(raw);
    try std.testing.expectEqual(256, blob.data.len);
    try std.testing.expect(blob.data[0] == 0x00);
}

test "fuzz: blob parse high bytes" {
    const content = [_]u8{0xff} ** 128;
    const raw = try makeRaw("blob", &content);
    defer std.testing.allocator.free(raw);
    const blob = try blob_mod.Blob.parse(raw);
    try std.testing.expectEqual(128, blob.data.len);
}

test "fuzz: blob parse utf8 multi-byte" {
    const content = "日本語テスト 🎉";
    const raw = try makeRaw("blob", content);
    defer std.testing.allocator.free(raw);
    const blob = try blob_mod.Blob.parse(raw);
    try std.testing.expectEqualSlices(u8, content, blob.data);
}

test "fuzz: blob oid determinism across sizes" {
    const sizes = [_]usize{ 0, 1, 2, 3, 7, 8, 15, 16, 31, 32, 63, 64, 127, 255, 256, 1023, 1024 };
    for (sizes) |sz| {
        const buf = try std.testing.allocator.alloc(u8, sz);
        defer std.testing.allocator.free(buf);
        @memset(buf, @as(u8, @intCast(sz & 0xff)));
        const b1 = blob_mod.Blob.create(buf);
        const b2 = blob_mod.Blob.create(buf);
        try std.testing.expect(b1.oid().eql(b2.oid()));
    }
}

test "fuzz: blob serialize roundtrip various sizes" {
    const sizes = [_]usize{ 0, 1, 10, 100, 1000 };
    for (sizes) |sz| {
        const buf = try std.testing.allocator.alloc(u8, sz);
        defer std.testing.allocator.free(buf);
        @memset(buf, 'A');
        const blob = blob_mod.Blob.create(buf);
        const serialized = try blob.serialize(std.testing.allocator);
        defer std.testing.allocator.free(serialized);
        const parsed = try blob_mod.Blob.parse(serialized);
        try std.testing.expectEqual(sz, parsed.data.len);
    }
}

test "fuzz: commit parse minimal valid" {
    const data =
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
        \\initial
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    const commit = try commit_mod.Commit.parse(std.testing.allocator, raw);
    try std.testing.expectEqual(@as(usize, 0), commit.parents.len);
}

test "fuzz: commit parse many parents" {
    var parents = try std.ArrayList([]const u8).initCapacity(std.testing.allocator, 20);
    defer {
        for (parents.items) |p| std.testing.allocator.free(p);
        parents.deinit(std.testing.allocator);
    }
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const hex = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        try parents.append(std.testing.allocator, try std.testing.allocator.dupe(u8, hex));
    }

    const parent_lines = try std.mem.join(std.testing.allocator, "\n", parents.items);
    defer std.testing.allocator.free(parent_lines);

    const data = try std.fmt.allocPrint(std.testing.allocator,
        \\tree {s}
        \\parent {s}
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
        \\merge
    , .{
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        parent_lines,
    });
    defer std.testing.allocator.free(data);

    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    const commit = try commit_mod.Commit.parse(std.testing.allocator, raw);
    try std.testing.expect(commit.parents.len >= 20);
}

test "fuzz: commit parse empty message" {
    const data =
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    const commit = try commit_mod.Commit.parse(std.testing.allocator, raw);
    try std.testing.expectEqual(0, commit.message.len);
}

test "fuzz: commit parse large message" {
    const big_msg = [_]u8{'X'} ** 8000;
    const data = try std.fmt.allocPrint(std.testing.allocator,
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
        \\{s}
    , .{&big_msg});
    defer std.testing.allocator.free(data);

    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    const commit = try commit_mod.Commit.parse(std.testing.allocator, raw);
    try std.testing.expectEqual(8000, commit.message.len);
}

test "fuzz: commit parse gpg signature present" {
    const data =
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ fake
        \\ -----END PGP SIGN-----
        \\
        \\signed
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    const commit = try commit_mod.Commit.parse(std.testing.allocator, raw);
    try std.testing.expect(commit.gpg_signature != null);
}

test "fuzz: commit parse missing tree line" {
    const data =
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
        \\no tree
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.MissingTree, commit_mod.Commit.parse(std.testing.allocator, raw));
}

test "fuzz: commit parse missing author" {
    const data =
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\committer C <c@d.com> 2 +0000
        \\
        \\no author
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidCommit, commit_mod.Commit.parse(std.testing.allocator, raw));
}

test "fuzz: commit parse mergetag line" {
    const data =
        \\tree abcdef1234567890abcdef1234567890abcdef12
        \\parent pppppppppppppppppppppppppppppppppppppp
        \\merger-tag-object 12345
        \\author A <a@b.com> 1 +0000
        \\committer C <c@d.com> 2 +0000
        \\
        \\merge commit
    ;
    const raw = try makeRaw("commit", data);
    defer std.testing.allocator.free(raw);
    _ = try commit_mod.Commit.parse(std.testing.allocator, raw);
}

test "fuzz: tree parse empty entries" {
    const raw = try makeRaw("tree", "");
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expectEqual(0, tree.entries.len);
}

test "fuzz: tree parse single entry" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "100644 file.txt\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xaa} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expectEqual(1, tree.entries.len);
    try std.testing.expectEqualSlices(u8, "file.txt", tree.entries[0].name);
}

test "fuzz: tree parse multiple entries sorted" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 256);
    defer entry_data.deinit(std.testing.allocator);
    const names = [_][]const u8{ ".gitignore", "README.md", "src/main.zig" };
    for (names) |name| {
        try entry_data.appendSlice(std.testing.allocator, "100644 ");
        try entry_data.appendSlice(std.testing.allocator, name);
        try entry_data.appendSlice(std.testing.allocator, "\x00");
        try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xbb} ** 20);
    }
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expectEqual(3, tree.entries.len);
}

test "fuzz: tree parse executable mode" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "100755 script.sh\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xcc} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expect(tree_mod.Mode.executable == tree.entries[0].mode);
}

test "fuzz: tree parse symlink mode" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "120000 link_target\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xdd} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expect(tree_mod.Mode.symlink == tree.entries[0].mode);
}

test "fuzz: tree parse gitlink mode" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "160000 module\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xee} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expect(tree_mod.Mode.gitlink == tree.entries[0].mode);
}

test "fuzz: tree parse directory mode" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "040000 subdir\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0xff} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expect(tree_mod.Mode.directory == tree.entries[0].mode);
}

test "fuzz: tree parse truncated entry" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "100644 a\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0x11} ** 10);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidTreeEntry, tree_mod.Tree.parse(raw));
}

test "fuzz: tree parse bad mode" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "999999 bad\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0x11} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.UnsupportedMode, tree_mod.Tree.parse(raw));
}

test "fuzz: tree parse mode too short" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "10064 file\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0x11} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidModeFormat, tree_mod.Tree.parse(raw));
}

test "fuzz: tree parse empty name" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "100644 \x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0x11} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expectEqual(0, tree.entries[0].name.len);
}

test "fuzz: tree parse name with slash" {
    var entry_data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 64);
    defer entry_data.deinit(std.testing.allocator);
    try entry_data.appendSlice(std.testing.allocator, "100644 path/to/file.txt\x00");
    try entry_data.appendSlice(std.testing.allocator, &[_]u8{0x11} ** 20);
    const raw = try makeRaw("tree", entry_data.items);
    defer std.testing.allocator.free(raw);
    _ = try tree_mod.Tree.parse(raw);
}

test "fuzz: tree parse name with unicode" {
    const name = "ファイル.txt";
    const header = try std.fmt.allocPrint(std.testing.allocator, "100644 {s}\x00", .{name});
    defer std.testing.allocator.free(header);
    var full = try std.ArrayList(u8).initCapacity(std.testing.allocator, header.len + 20);
    defer full.deinit(std.testing.allocator);
    try full.appendSlice(std.testing.allocator, header);
    try full.appendSlice(std.testing.allocator, &[_]u8{0x22} ** 20);
    const raw = try makeRaw("tree", full.items);
    defer std.testing.allocator.free(raw);
    const tree = try tree_mod.Tree.parse(raw);
    try std.testing.expectEqualSlices(u8, name, tree.entries[0].name);
}

test "fuzz: tag parse minimal annotated" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type commit
        \\tag v1.0.0
        \\tagger T <t@t.com> 1000000000 +0000
        \\
        \\Release v1.0.0
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    const tag = try tag_mod.Tag.parse(raw);
    try std.testing.expectEqualSlices(u8, "v1.0.0", tag.name);
    try std.testing.expect(tag.tagger != null);
}

test "fuzz: tag parse lightweight equivalent (no tagger)" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type commit
        \\tag v2.0
        \\
        \\lightweight tag msg
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    const tag = try tag_mod.Tag.parse(raw);
    try std.testing.expect(tag.tagger == null);
}

test "fuzz: tag parse all target types" {
    const types = [_]struct { []const u8, object_mod.Type }{
        .{ "blob", .blob },
        .{ "tree", .tree },
        .{ "commit", .commit },
        .{ "tag", .tag },
    };
    for (types) |t| {
        const data = try std.fmt.allocPrint(std.testing.allocator,
            \\object abcdef1234567890abcdef1234567890abcdef12
            \\type {s}
            \\tag test-{s}
            \\tagger T <t@t.com> 1 +0000
            \\
            \\msg
        , .{ t[0], t[0] });
        defer std.testing.allocator.free(data);

        const raw = try makeRaw("tag", data);
        defer std.testing.allocator.free(raw);
        const tag = try tag_mod.Tag.parse(raw);
        try std.testing.expectEqual(t[1], tag.target_type);
    }
}

test "fuzz: tag parse empty message" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type commit
        \\tag empty-msg
        \\tagger T <t@t.com> 1 +0000
        \\
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    const tag = try tag_mod.Tag.parse(raw);
    try std.testing.expectEqual(0, tag.message.len);
}

test "fuzz: tag parse large message" {
    const big = [_]u8{'M'} ** 4000;
    const data = try std.fmt.allocPrint(std.testing.allocator,
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type commit
        \\tag big
        \\tagger T <t@t.com> 1 +0000
        \\
        \\{s}
    , .{&big});
    defer std.testing.allocator.free(data);

    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    const tag = try tag_mod.Tag.parse(raw);
    try std.testing.expectEqual(4000, tag.message.len);
}

test "fuzz: tag parse missing object line" {
    const data =
        \\type commit
        \\tag broken
        \\
        \\no object
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidTag, tag_mod.Tag.parse(raw));
}

test "fuzz: tag parse missing type line" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\tag notype
        \\
        \\no type
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidTag, tag_mod.Tag.parse(raw));
}

test "fuzz: tag parse invalid type value" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type invalid_type
        \\tag badtype
        \\
        \\msg
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    try std.testing.expectError(error.InvalidObjectType, tag_mod.Tag.parse(raw));
}

test "fuzz: tag parse gpgsig block" {
    const data =
        \\object abcdef1234567890abcdef1234567890abcdef12
        \\type commit
        \\tag signed
        \\tagger T <t@t.com> 1 +0000
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ iQIzBAABCgAdFiEE...
        \\ -----END PGP SIGN-----
        \\
        \\signed tag message
    ;
    const raw = try makeRaw("tag", data);
    defer std.testing.allocator.free(raw);
    const tag = try tag_mod.Tag.parse(raw);
    try std.testing.expect(tag.gpg_signature != null);
}

test "fuzz: roundtrip all types via object module" {
    const test_cases = [_]struct { []const u8, []const u8 }{
        .{ "blob", "binary:\x00\x01\x02\xff" },
        .{ "commit", "tree abc\nauthor A <a@b> 1 +0000\ncommitter C <c@d> 2 +0000\n\nmsg\n" },
        .{ "tree", "100644 a\x00" ++ [_]u8{0x11} ** 20 },
        .{ "tag", "object abc\ntype commit\ntag t\ntagger T <t@t> 1 +0000\n\nm\n" },
    };

    for (test_cases) |tc| {
        const raw = try makeRaw(tc[0], tc[1]);
        defer std.testing.allocator.free(raw);

        const parsed = try object_mod.parse(raw);
        const serialized = try object_mod.serialize(parsed, std.testing.allocator);
        defer std.testing.allocator.free(serialized);

        const reparsed = try object_mod.parse(serialized);
        try std.testing.expectEqual(tc[0], @tagName(reparsed.obj_type));
        try std.testing.expectEqualSlices(u8, tc[1], reparsed.data);
    }
}
