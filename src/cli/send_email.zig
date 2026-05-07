//! Git Send-Email - Format and send patches via email (SMTP)
const std = @import("std");
const Io = std.Io;
const Output = @import("output.zig").Output;
const OutputStyle = @import("output.zig").OutputStyle;

pub const SendEmailOptions = struct {
    to: ?[]const u8 = null,
    cc: ?[]const u8 = null,
    bcc: ?[]const u8 = null,
    from: ?[]const u8 = null,
    smtp_server: ?[]const u8 = null,
    smtp_port: u16 = 587,
    smtp_user: ?[]const u8 = null,
    smtp_pass: ?[]const u8 = null,
    in_reply_to: ?[]const u8 = null,
    subject_prefix: ?[]const u8 = null,
    thread: bool = true,
    chain_reply_to: bool = true,
    signed_off_by: bool = true,
    annotate: bool = false,
    compose: bool = false,
    quiet: bool = false,
    dry_run: bool = false,
    format_patch_args: []const []const u8 = &.{},
};

pub const EmailMessage = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    from: ?[]const u8 = null,
    cc: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    in_reply_to: ?[]const u8 = null,
    references: ?[]const u8 = null,
};

pub const SendEmail = struct {
    allocator: std.mem.Allocator,
    io: Io,
    output: Output,
    options: SendEmailOptions,

    pub fn init(allocator: std.mem.Allocator, io: Io, writer: *Io.Writer, style: OutputStyle) SendEmail {
        return .{
            .allocator = allocator,
            .io = io,
            .output = Output.init(writer, style, allocator),
            .options = .{},
        };
    }

    pub fn run(self: *SendEmail, args: []const []const u8) !void {
        self.parseArgs(args);

        if (self.options.to == null) {
            try self.output.errorMessage("No recipients specified. Use --to to specify recipient.", .{});
            try self.output.infoMessage("Usage: hoz send-email --to <email> [<patch-file>...]", .{});
            return error.NoRecipients;
        }

        const cwd = Io.Dir.cwd();
        const git_dir = cwd.openDir(self.io, ".git", .{}) catch {
            try self.output.errorMessage("Not a git repository (or any of the parent directories): .git", .{});
            return error.NotAGitRepository;
        };
        defer git_dir.close(self.io);

        var patch_files = try self.resolvePatchFiles(args);
        defer {
            for (patch_files.items) |f| self.allocator.free(f);
            patch_files.deinit(self.allocator);
        }

        if (patch_files.items.len == 0) {
            try self.output.infoMessage("No patch files specified. Generating patches from recent commits...", .{});

            patch_files = try self.generatePatchesFromCommits(&cwd);
            defer {
                for (patch_files.items) |f| self.allocator.free(f);
                patch_files.deinit(self.allocator);
            }
        }

        if (patch_files.items.len == 0) {
            try self.output.errorMessage("No patches to send", .{});
            return;
        }

        try self.output.section("Send Email Summary");
        try self.output.item("To", self.options.to.?);
        if (self.options.cc) |cc| try self.output.item("CC", cc);
        try self.output.item("Patches", try std.fmt.allocPrint(self.allocator, "{d}", .{patch_files.items.len}));
        try self.output.item("SMTP Server", self.options.smtp_server orelse "localhost");

        var messages = try self.buildEmailMessages(patch_files.items);
        defer {
            for (messages.items) |msg| {
                self.allocator.free(msg.subject);
                self.allocator.free(msg.body);
                if (msg.from) |f| self.allocator.free(f);
                if (msg.cc) |c| self.allocator.free(c);
                if (msg.message_id) |m| self.allocator.free(m);
                if (msg.in_reply_to) |r| self.allocator.free(r);
                if (msg.references) |r| self.allocator.free(r);
            }
            messages.deinit(self.allocator);
        }

        if (self.options.dry_run) {
            try self.printDryRun(messages.items);
        } else {
            try self.sendMessages(messages.items);
        }

        try self.output.successMessage("Prepared {d} email(s) for sending", .{messages.items.len});
    }

    fn parseArgs(self: *SendEmail, args: []const []const u8) void {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--to") and i + 1 < args.len) {
                i += 1;
                self.options.to = args[i];
            } else if (std.mem.eql(u8, arg, "--cc") and i + 1 < args.len) {
                i += 1;
                self.options.cc = args[i];
            } else if (std.mem.eql(u8, arg, "--bcc") and i + 1 < args.len) {
                i += 1;
                self.options.bcc = args[i];
            } else if (std.mem.eql(u8, arg, "--from") and i + 1 < args.len) {
                i += 1;
                self.options.from = args[i];
            } else if (std.mem.eql(u8, arg, "--smtp-server") and i + 1 < args.len) {
                i += 1;
                self.options.smtp_server = args[i];
            } else if (std.mem.eql(u8, arg, "--smtp-port") and i + 1 < args.len) {
                i += 1;
                self.options.smtp_port = std.fmt.parseInt(u16, args[i], 10) catch 587;
            } else if (std.mem.eql(u8, arg, "--smtp-user") and i + 1 < args.len) {
                i += 1;
                self.options.smtp_user = args[i];
            } else if (std.mem.eql(u8, arg, "--smtp-pass") and i + 1 < args.len) {
                i += 1;
                self.options.smtp_pass = args[i];
            } else if (std.mem.eql(u8, arg, "--in-reply-to") and i + 1 < args.len) {
                i += 1;
                self.options.in_reply_to = args[i];
            } else if (std.mem.eql(u8, arg, "--subject-prefix") and i + 1 < args.len) {
                i += 1;
                self.options.subject_prefix = args[i];
            } else if (std.mem.eql(u8, arg, "--no-thread")) {
                self.options.thread = false;
            } else if (std.mem.eql(u8, arg, "--no-chain-reply-to")) {
                self.options.chain_reply_to = false;
            } else if (std.mem.eql(u8, arg, "--no-signed-off-by")) {
                self.options.signed_off_by = false;
            } else if (std.mem.eql(u8, arg, "--annotate")) {
                self.options.annotate = true;
            } else if (std.mem.eql(u8, arg, "--compose")) {
                self.options.compose = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                self.options.quiet = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                self.options.dry_run = true;
            }
        }
    }

    fn resolvePatchFiles(self: *SendEmail, args: []const []const u8) !std.ArrayList([]const u8) {
        var files = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);

        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-") and std.mem.endsWith(u8, arg, ".patch")) {
                const copy = try self.allocator.dupe(u8, arg);
                try files.append(self.allocator, copy);
            }
        }

        return files;
    }

    fn generatePatchesFromCommits(self: *SendEmail, cwd: *const Io.Dir) !std.ArrayList([]const u8) {
        var files = try std.ArrayList([]const u8).initCapacity(self.allocator, 16);

        const git_dir = cwd.openDir(self.io, ".git", .{}) catch return files;
        defer git_dir.close(self.io);

        const output_dir = "hoz-email-patches";

        var fmt_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 8) catch return files;
        defer fmt_argv.deinit(self.allocator);
        if (self.options.subject_prefix) |prefix| {
            fmt_argv.appendSlice(self.allocator, &.{ "git", "format-patch", "-o", output_dir, "--subject-prefix", prefix }) catch {};
        } else {
            fmt_argv.appendSlice(self.allocator, &.{ "git", "format-patch", "-o", output_dir }) catch {};
        }

        for (self.options.format_patch_args) |arg| {
            fmt_argv.append(self.allocator, arg) catch {};
        }
        fmt_argv.appendSlice(self.allocator, &.{ "-n", "HEAD" }) catch {};

        var child = std.process.spawn(self.io, .{
            .argv = fmt_argv.items,
            .stdin = .close,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch {
            try self.output.errorMessage("Failed to run git format-patch", .{});
            return files;
        };

        const term = child.wait(self.io) catch {
            try self.output.errorMessage("git format-patch failed", .{});
            return files;
        };
        if (child.stdout) |stdout| stdout.close(self.io);
        if (child.stderr) |stderr| stderr.close(self.io);

        if (term != .exited or term.exited != 0) {
            try self.output.errorMessage("git format-patch failed", .{});
            return files;
        }

        const patches_dir = Io.Dir.cwd().openDir(self.io, output_dir, .{}) catch {
            try self.output.infoMessage("No patches generated (no commits to export)", .{});
            return files;
        };
        defer patches_dir.close(self.io);

        var walker = patches_dir.walk(self.allocator) catch {
            return files;
        };
        defer walker.deinit();

        while (true) {
            const entry = walker.next(self.io) catch break;
            if (entry == null) break;
            const e = entry.?;
            if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".patch")) {
                const full_path = try std.fs.path.join(self.allocator, &.{ output_dir, e.basename });
                try files.append(self.allocator, full_path);
            }
        }

        return files;
    }

    fn buildEmailMessages(self: *SendEmail, patch_files: []const []const u8) !std.ArrayList(EmailMessage) {
        var messages = try std.ArrayList(EmailMessage).initCapacity(self.allocator, patch_files.len);

        var prev_message_id: ?[]u8 = null;

        for (patch_files, 0..) |patch_file, index| {
            const content = Io.Dir.cwd().readFileAlloc(self.io, patch_file, self.allocator, .limited(1024 * 1024)) catch {
                try self.output.errorMessage("Failed to read patch file: {s}", .{patch_file});
                continue;
            };

            const subject = self.extractSubject(content);
            const body = self.formatEmailBody(content, index, patch_files.len);
            const message_id = self.generateMessageId(index);
            const from_addr = try self.resolveFromAddress();

            var msg = EmailMessage{
                .to = self.options.to.?,
                .subject = subject,
                .body = body,
                .from = from_addr,
                .cc = self.options.cc,
                .message_id = message_id,
                .in_reply_to = null,
                .references = null,
            };

            if (self.options.thread and prev_message_id != null) {
                if (index > 0 or self.options.in_reply_to != null) {
                    msg.in_reply_to = if (index == 0 and self.options.in_reply_to != null)
                        try self.allocator.dupe(u8, self.options.in_reply_to.?)
                    else
                        prev_message_id;

                    if (self.options.chain_reply_to) {
                        msg.references = prev_message_id;
                    }
                }
            }

            prev_message_id = try self.allocator.dupe(u8, message_id);
            try messages.append(self.allocator, msg);
        }

        if (prev_message_id) |p| self.allocator.free(p);

        return messages;
    }

    fn extractSubject(self: *SendEmail, patch_content: []const u8) []const u8 {
        var lines = std.mem.tokenizeAny(u8, patch_content, "\n\r");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Subject: ")) {
                const subject = line[9..];

                if (self.options.subject_prefix) |prefix| {
                    if (!std.mem.startsWith(u8, subject, prefix)) {
                        var new_subject = std.ArrayList(u8).initCapacity(self.allocator, subject.len + prefix.len + 2) catch return subject;
                        new_subject.appendSlice(self.allocator, prefix) catch {};
                        new_subject.appendSlice(self.allocator, " ") catch {};
                        new_subject.appendSlice(self.allocator, subject) catch {};
                        const result = new_subject.toOwnedSlice(self.allocator) catch return subject;
                        return result;
                    }
                }

                return self.allocator.dupe(u8, subject) catch subject;
            }
        }
        return self.allocator.dupe(u8, "[PATCH] No subject") catch return "[PATCH] No subject";
    }

    fn formatEmailBody(self: *SendEmail, patch_content: []const u8, index: usize, total: usize) []const u8 {
        var body = std.ArrayList(u8).initCapacity(self.allocator, patch_content.len + 256) catch return &[_]u8{};

        body.appendSlice(self.allocator, "\n") catch {};

        if (self.options.compose) {
            body.appendSlice(self.allocator, "---\n") catch {};
            body.appendSlice(self.allocator, "An introductory message can be placed here.\n") catch {};
            body.appendSlice(self.allocator, "\n") catch {};
            if (self.options.annotate) {
                body.appendSlice(self.allocator, "Please review the following patches for inclusion.\n") catch {};
            }
            body.appendSlice(self.allocator, "\n") catch {};
        }

        var in_header = true;
        var lines = std.mem.tokenizeAny(u8, patch_content, "\n\r");
        while (lines.next()) |line| {
            if (in_header and line.len == 0) {
                in_header = false;
                continue;
            }

            if (!in_header) {
                body.appendSlice(self.allocator, line) catch {};
                body.appendSlice(self.allocator, "\n") catch {};
            }
        }

        if (body.items.len == 0) {
            body.appendSlice(self.allocator, patch_content) catch {};
        }

        if (total > 1) {
            var prefixed = std.ArrayList(u8).initCapacity(self.allocator, body.items.len + 32) catch return patch_content;
            errdefer prefixed.deinit(self.allocator);
            var prefix_buf: [64]u8 = undefined;
            const prefix = std.fmt.bufPrint(&prefix_buf, "[{d}/{d}] ", .{ index + 1, total }) catch "[0/0] ";
            prefixed.appendSlice(self.allocator, prefix) catch return patch_content;
            prefixed.appendSlice(self.allocator, body.items) catch return patch_content;
            return prefixed.toOwnedSlice(self.allocator) catch return patch_content;
        }

        const result = body.toOwnedSlice(self.allocator) catch return patch_content;
        return result;
    }

    fn generateMessageId(self: *SendEmail, index: usize) []u8 {
        var buf: [64]u8 = undefined;

        const now = Io.Timestamp.now(self.io, .real);
        const timestamp = @divTrunc(now.nanoseconds, std.time.ns_per_s);

        var random_bytes: [4]u8 = undefined;
        self.io.randomSecure(&random_bytes) catch {
            @memset(&random_bytes, 0);
            const ns = now.nanoseconds;
            random_bytes[0] = @intCast(ns & 0xFF);
            random_bytes[1] = @intCast((ns >> 8) & 0xFF);
            random_bytes[2] = @intCast((ns >> 16) & 0xFF);
            random_bytes[3] = @intCast((ns >> 24) & 0xFF);
        };

        const rand_val: u32 = (@as(u32, random_bytes[0]) << 24) | (@as(u32, random_bytes[1]) << 16) | (@as(u32, random_bytes[2]) << 8) | @as(u32, random_bytes[3]);

        const id = std.fmt.bufPrint(&buf, "<hoz.{d}.{d}.{d}.patch@local>", .{ timestamp, index, rand_val }) catch {
            return self.allocator.dupe(u8, "<patch@local>") catch {
                return &[_]u8{};
            };
        };

        return self.allocator.dupe(u8, id) catch {
            return &[_]u8{};
        };
    }

    fn resolveFromAddress(self: *SendEmail) ![]u8 {
        if (self.options.from) |f| {
            return try self.allocator.dupe(u8, f);
        }

        const name_env = std.c.getenv("GIT_AUTHOR_NAME");
        const email_env = std.c.getenv("GIT_AUTHOR_EMAIL");

        const name = if (name_env) |n| n else "Author";
        const email = if (email_env) |e| e else "author@example.com";

        var addr = try std.ArrayList(u8).initCapacity(self.allocator, @as(usize, std.mem.len(name)) + @as(usize, std.mem.len(email)) + 4);
        try addr.appendSlice(self.allocator, name[0..std.mem.len(name)]);
        try addr.appendSlice(self.allocator, " <");
        try addr.appendSlice(self.allocator, email[0..std.mem.len(email)]);
        try addr.appendSlice(self.allocator, ">");

        return try addr.toOwnedSlice(self.allocator);
    }

    fn printDryRun(self: *SendEmail, messages: []const EmailMessage) !void {
        try self.output.section("Dry Run - Emails to be sent");
        try self.output.infoMessage("Total emails: {d}", .{messages.len});

        for (messages, 0..) |msg, i| {
            try self.output.infoMessage("\n--- Email {d} ---", .{i + 1});
            try self.output.item("To", msg.to);
            if (msg.from) |f| try self.output.item("From", f);
            if (msg.cc) |cc| try self.output.item("CC", cc);
            try self.output.item("Subject", msg.subject);
            if (msg.message_id) |mid| try self.output.item("Message-ID", mid);
            if (msg.in_reply_to) |irt| try self.output.item("In-Reply-To", irt);
            try self.output.infoMessage("Body preview (first 200 chars):", .{});
            const preview_len = @min(msg.body.len, 200);
            try self.output.infoMessage("{s}", .{msg.body[0..preview_len]});
        }
    }

    fn sendMessages(self: *SendEmail, messages: []const EmailMessage) !void {
        const smtp_server = self.options.smtp_server orelse "localhost";

        try self.output.infoMessage("Connecting to SMTP server: {s}:{d}", .{ smtp_server, self.options.smtp_port });

        for (messages, 0..) |msg, i| {
            const email_data = try self.buildRawEmail(msg);
            defer self.allocator.free(email_data);

            var sendmail_argv = std.ArrayList([]const u8).initCapacity(self.allocator, 4) catch {
                try self.output.errorMessage("Failed to allocate memory for sendmail args", .{});
                continue;
            };
            defer sendmail_argv.deinit(self.allocator);

            if (self.options.smtp_server != null) {
                const smtp_arg = try std.fmt.allocPrint(self.allocator, "-S", .{});
                defer self.allocator.free(smtp_arg);
                sendmail_argv.appendSlice(self.allocator, &.{ "sendmail", "-t", smtp_arg }) catch {};
            } else {
                sendmail_argv.appendSlice(self.allocator, &.{ "sendmail", "-t" }) catch {};
            }

            var child = std.process.spawn(self.io, .{
                .argv = sendmail_argv.items,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .pipe,
            }) catch {
                try self.output.errorMessage("Failed to spawn sendmail for email {d}/{d}", .{ i + 1, messages.len });
                continue;
            };

            if (child.stdin) |stdin| {
                stdin.writeStreamingAll(self.io, email_data) catch {
                    try self.output.errorMessage("Failed to write email data for email {d}/{d}", .{ i + 1, messages.len });
                };
                stdin.close(self.io);
            }

            const term = child.wait(self.io) catch {
                try self.output.errorMessage("Failed to wait for sendmail", .{});
                continue;
            };
            if (child.stdout) |stdout| stdout.close(self.io);
            if (child.stderr) |stderr| stderr.close(self.io);

            if (term == .exited and term.exited == 0) {
                try self.output.infoMessage("Sent email {d}/{d}: {s}", .{ i + 1, messages.len, msg.subject });
            } else {
                try self.output.errorMessage("Failed to send email {d}/{d} (exit code: {?})", .{ i + 1, messages.len, if (term == .exited) term.exited else null });
            }
        }

        try self.output.successMessage("All emails processed", .{});
    }

    fn buildRawEmail(self: *SendEmail, msg: EmailMessage) ![]u8 {
        var raw = try std.ArrayList(u8).initCapacity(self.allocator, msg.body.len + 1024);
        errdefer raw.deinit(self.allocator);

        const from_addr = msg.from orelse "hoz-noreply@local";

        try raw.appendSlice(self.allocator, "From: ");
        try raw.appendSlice(self.allocator, from_addr);
        try raw.appendSlice(self.allocator, "\n");

        try raw.appendSlice(self.allocator, "To: ");
        try raw.appendSlice(self.allocator, msg.to);
        try raw.appendSlice(self.allocator, "\n");

        if (msg.cc) |cc| {
            try raw.appendSlice(self.allocator, "Cc: ");
            try raw.appendSlice(self.allocator, cc);
            try raw.appendSlice(self.allocator, "\n");
        }

        try raw.appendSlice(self.allocator, "Subject: ");
        try raw.appendSlice(self.allocator, msg.subject);
        try raw.appendSlice(self.allocator, "\n");

        if (msg.message_id) |mid| {
            try raw.appendSlice(self.allocator, "Message-ID: ");
            try raw.appendSlice(self.allocator, mid);
            try raw.appendSlice(self.allocator, "\n");
        }

        if (msg.in_reply_to) |irt| {
            try raw.appendSlice(self.allocator, "In-Reply-To: ");
            try raw.appendSlice(self.allocator, irt);
            try raw.appendSlice(self.allocator, "\n");
        }

        if (msg.references) |refs| {
            try raw.appendSlice(self.allocator, "References: ");
            try raw.appendSlice(self.allocator, refs);
            try raw.appendSlice(self.allocator, "\n");
        }

        try raw.appendSlice(self.allocator, "MIME-Version: 1.0\n");
        try raw.appendSlice(self.allocator, "Content-Type: text/plain; charset=utf-8\n");
        try raw.appendSlice(self.allocator, "Content-Transfer-Encoding: 8bit\n");
        try raw.appendSlice(self.allocator, "\n");
        try raw.appendSlice(self.allocator, msg.body);

        return raw.toOwnedSlice(self.allocator);
    }
};
