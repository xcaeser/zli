//! Tests that drive zli the way an app does: build a command tree, feed it a
//! fake argv, and check what ran and what got printed.
//!
//! Run with `zig build test`, or one test with `zig build test -Dtest-filter="greet"`.
//! To try something out, copy a test, change `argv`, and run it.

const std = @import("std");
const testing = std.testing;
const zli = @import("zli");

/// Captures everything the CLI prints and owns the command tree.
const Harness = struct {
    out: std.Io.Writer.Allocating,
    in: std.Io.Reader,
    root: *zli.Command = undefined,

    fn init(self: *Harness) void {
        self.* = .{ .out = .init(testing.allocator), .in = .fixed("") };
    }

    fn deinit(self: *Harness) void {
        self.root.deinit();
        self.out.deinit();
    }

    fn options(self: *Harness) zli.InitOptions {
        return .{
            .allocator = testing.allocator,
            .io = testing.io,
            .writer = &self.out.writer,
            .reader = &self.in,
        };
    }

    /// Runs the CLI with `argv` (argv[0] is the program name) and flushes output.
    fn run(self: *Harness, argv: []const [*:0]const u8, data: ?*anyopaque) !void {
        var it = (std.process.Args{ .vector = argv }).iterate();
        defer self.out.writer.flush() catch {};
        try self.root.execute(&it, .{ .data = data });
    }

    fn output(self: *Harness) []const u8 {
        return self.out.written();
    }
};

/// Same tree as the README quick start, plus a few extras to poke at.
fn buildCli(h: *Harness) !void {
    const opts = h.options();

    h.root = try zli.Command.init(opts, .{
        .name = "hello",
        .description = "A tiny zli app",
        .version = .{ .major = 0, .minor = 1, .patch = 0, .pre = null, .build = null },
    }, showHelp);

    try h.root.addFlag(.{
        .name = "verbose",
        .shortcut = "v",
        .description = "Print more details",
        .type = .Bool,
        .default_value = .{ .Bool = false },
        .persistent = true,
    });

    const greet = try zli.Command.init(opts, .{
        .name = "greet",
        .shortcut = "g",
        .aliases = &.{"hi"},
        .description = "Greet someone",
    }, greetSomeone);
    try greet.addPositionalArg(.{ .name = "name", .description = "Who to greet", .required = true });
    try greet.addFlags(&.{
        .{ .name = "times", .shortcut = "t", .description = "Repeat", .type = .Int, .default_value = .{ .Int = 1 } },
        .{ .name = "greeting", .description = "Word to use", .type = .String, .default_value = .{ .String = "Hello" } },
        .{ .name = "debug", .description = "Internal", .type = .Bool, .default_value = .{ .Bool = false }, .hidden = true },
    });

    const echo = try zli.Command.init(opts, .{ .name = "echo", .description = "Print words" }, echoWords);
    try echo.addPositionalArg(.{ .name = "words", .description = "Words", .required = false, .variadic = true });
    try echo.addFlag(.{ .name = "no-brackets", .description = "Print words bare", .type = .Bool, .default_value = .{ .Bool = false } });

    const old = try zli.Command.init(opts, .{
        .name = "old",
        .description = "Old command",
        .deprecated = true,
        .replaced_by = "greet",
    }, showHelp);

    const count = try zli.Command.init(opts, .{ .name = "count", .description = "Count calls" }, countCalls);

    try h.root.addCommands(&.{ greet, echo, old, count });
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

fn greetSomeone(ctx: zli.CommandContext) !void {
    const name = ctx.getArg("name") orelse "friend";
    if (ctx.flag("verbose", bool)) try ctx.writer.print("Preparing greeting for {s}\n", .{name});
    for (0..ctx.flag("times", u32)) |_| {
        try ctx.writer.print("{s}, {s}!\n", .{ ctx.flag("greeting", []const u8), name });
    }
}

fn echoWords(ctx: zli.CommandContext) !void {
    const bare = ctx.flag("no-brackets", bool);
    for (ctx.positional_args) |w| {
        if (bare) try ctx.writer.writeAll(w) else try ctx.writer.print("[{s}]", .{w});
    }
}

fn countCalls(ctx: zli.CommandContext) !void {
    ctx.getContextData(u32).* += 1;
}

fn expectRun(argv: []const [*:0]const u8, expected: []const u8) !void {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(argv, null);
    try testing.expectEqualStrings(expected, h.output());
}

fn expectRunError(argv: []const [*:0]const u8, err: anyerror, expected_substring: []const u8) !void {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try testing.expectError(err, h.run(argv, null));
    if (std.mem.indexOf(u8, h.output(), expected_substring) == null) {
        std.debug.print("output was:\n{s}\n", .{h.output()});
        return error.TestUnexpectedOutput;
    }
}

test "greet with a required positional arg" {
    try expectRun(&.{ "hello", "greet", "Ada" }, "Hello, Ada!\n");
}

test "subcommand shortcut and alias" {
    try expectRun(&.{ "hello", "g", "Ada" }, "Hello, Ada!\n");
    try expectRun(&.{ "hello", "hi", "Ada" }, "Hello, Ada!\n");
}

test "persistent bool flag after the subcommand" {
    try expectRun(&.{ "hello", "greet", "Ada", "--verbose" }, "Preparing greeting for Ada\nHello, Ada!\n");
    try expectRun(&.{ "hello", "greet", "-v", "Ada" }, "Preparing greeting for Ada\nHello, Ada!\n");
}

test "persistent bool flag before the subcommand" {
    try expectRun(&.{ "hello", "--verbose", "greet", "Ada" }, "Preparing greeting for Ada\nHello, Ada!\n");
    try expectRun(&.{ "hello", "-v", "greet", "Ada", "--no-verbose" }, "Hello, Ada!\n");
}

test "negated bool flag" {
    try expectRun(&.{ "hello", "greet", "Ada", "--verbose", "--no-verbose" }, "Hello, Ada!\n");
}

test "int and string flag forms" {
    const two = "Hey, Ada!\nHey, Ada!\n";
    try expectRun(&.{ "hello", "greet", "Ada", "--times=2", "--greeting=Hey" }, two);
    try expectRun(&.{ "hello", "greet", "Ada", "--times", "2", "--greeting", "Hey" }, two);
    try expectRun(&.{ "hello", "greet", "Ada", "-t", "2", "--greeting=Hey" }, two);
}

test "int flag out of range for the read type saturates" {
    // greet reads --times as u32, so -1 saturates to 0 repeats instead of panicking.
    try expectRun(&.{ "hello", "greet", "Ada", "--times=-1" }, "");
}

test "grouped short flags, value flag last" {
    try expectRun(&.{ "hello", "greet", "Ada", "-vt", "2" }, "Preparing greeting for Ada\nHello, Ada!\nHello, Ada!\n");
}

test "variadic args and -- separator" {
    try expectRun(&.{ "hello", "echo", "a", "b", "c" }, "[a][b][c]");
    try expectRun(&.{ "hello", "echo", "--", "--not-a-flag", "-x" }, "[--not-a-flag][-x]");
    try expectRun(&.{ "hello", "echo" }, "");
}

test "negative numbers are positional, not flags" {
    try expectRun(&.{ "hello", "echo", "-5", "-12" }, "[-5][-12]");
    try expectRun(&.{ "hello", "echo", "-1.5", "-9999999999" }, "[-1.5][-9999999999]");
}

test "empty argument is a positional, not a crash" {
    try expectRun(&.{ "hello", "echo", "" }, "[]");
}

test "help flags after -- are positional" {
    try expectRun(&.{ "hello", "echo", "--", "-h", "--help", "-vh" }, "[-h][--help][-vh]");
}

test "flag whose name starts with no-" {
    try expectRun(&.{ "hello", "echo", "--no-brackets", "a", "b" }, "ab");
}

test "long form of a shortcut sets the flag" {
    const two = "Hello, Ada!\nHello, Ada!\n";
    try expectRun(&.{ "hello", "greet", "Ada", "--t=2" }, two);
    try expectRun(&.{ "hello", "greet", "Ada", "--t", "2" }, two);
}

test "reading a flag by its shortcut gets the parsed value" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.root = try zli.Command.init(h.options(), .{ .name = "app", .description = "App" }, printTimes);
    try h.root.addFlag(.{ .name = "times", .shortcut = "t", .description = "Repeat", .type = .Int, .default_value = .{ .Int = 1 } });
    try h.run(&.{ "app", "-t", "3" }, null);
    try testing.expectEqualStrings("3", h.output());
}

fn printTimes(ctx: zli.CommandContext) !void {
    try ctx.writer.print("{d}", .{ctx.flag("t", i32)});
}

test "unknown subcommand is an error, not a silent run of the parent" {
    try expectRunError(&.{ "hello", "grreet", "Ada" }, error.UnknownCommand, "Unknown command: 'grreet'");
}

test "empty argv runs the root command" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(&.{}, null);
    try testing.expect(std.mem.indexOf(u8, h.output(), "A tiny zli app") != null);
}

test "help flag prints help and skips the command" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(&.{ "hello", "greet", "--help" }, null);
    const out = h.output();
    try testing.expect(std.mem.indexOf(u8, out, "Usage: hello greet [options] <name>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--times") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--debug") == null); // hidden
    try testing.expect(std.mem.indexOf(u8, out, "Hello, ") == null);
}

test "root help: commands and flags sorted, descriptions in one column, deprecated hidden" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(&.{ "hello", "--help" }, null);
    // `old` is deprecated, so it's left out (it still runs and prints its deprecation notice).
    try expectPlain(
        \\A tiny zli app
        \\v0.1.0
        \\
        \\Usage: hello [options]
        \\
        \\Available commands:
        \\   count             Count calls
        \\   echo              Print words
        \\   greet (g)         Greet someone
        \\
        \\Flags:
        \\   -h, --help        Shows the help for a command [Bool] (default: false)
        \\   -v, --verbose     Print more details [Bool] (default: false)
        \\
        \\
    , h.output());
}

test "structured help with a custom usage line" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const opts = h.options();
    h.root = try zli.Command.init(opts, .{ .name = "app", .description = "App", .usage = "app <command>" }, showStructuredHelp);
    try h.root.addCommands(&.{
        try zli.Command.init(opts, .{ .name = "run", .description = "Run it" }, showHelp),
        try zli.Command.init(opts, .{ .name = "build", .description = "Build it", .section_title = "Build" }, showHelp),
    });
    try h.run(&.{"app"}, null);
    try expectPlain(
        \\App
        \\
        \\Usage: app <command>
        \\
        \\Build:
        \\   build          Build it
        \\
        \\General:
        \\   run            Run it
        \\
        \\Flags:
        \\   -h, --help     Shows the help for a command [Bool] (default: false)
        \\
        \\
    , h.output());
}

test "help pieces can be printed on their own" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const opts = h.options();
    h.root = try zli.Command.init(opts, .{ .name = "app", .description = "App" }, printPieces);
    try h.root.addPositionalArg(.{ .name = "file", .description = "Input", .required = false });
    try h.root.addCommand(try zli.Command.init(opts, .{ .name = "run", .description = "Run it" }, showHelp));
    try h.run(&.{"app"}, null);
    try expectPlain(
        \\Available commands:
        \\   run            Run it
        \\Flags:
        \\   -h, --help     Shows the help for a command [Bool] (default: false)
        \\Arguments:
        \\   file           Input
        \\
        \\
    , h.output());
}

test "multi-line descriptions stay aligned (issue #14)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const opts = h.options();
    h.root = try zli.Command.init(opts, .{ .name = "app", .description = "App" }, printPieces);
    try h.root.addFlag(.{ .name = "force", .shortcut = "f", .description = "Overwrite files.\nNever use with --dry-run.", .type = .Bool, .default_value = .{ .Bool = false } });
    try h.root.addPositionalArg(.{ .name = "file", .description = "Input file.\n\nUse - for stdin.", .required = true });
    try h.root.addCommand(try zli.Command.init(opts, .{ .name = "run", .description = "Run it.\nTwice if needed." }, showHelp));
    try h.run(&.{ "app", "in.txt" }, null);
    try expectPlain(
        \\Available commands:
        \\   run             Run it.
        \\                   Twice if needed.
        \\Flags:
        \\   -f, --force     Overwrite files.
        \\                   Never use with --dry-run. [Bool] (default: false)
        \\   -h, --help      Shows the help for a command [Bool] (default: false)
        \\Arguments:
        \\   file            Input file.
        \\
        \\                   Use - for stdin. (required)
        \\
        \\
    , h.output());
}

fn showStructuredHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printStructuredHelp();
}

fn printPieces(ctx: zli.CommandContext) !void {
    try ctx.command.printCommands();
    try ctx.command.printFlags();
    try ctx.command.printPositionalArgs();
}

/// Like `expectEqualStrings`, but ignores the ANSI style codes in `actual`.
fn expectPlain(expected: []const u8, actual: []const u8) !void {
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(testing.allocator);
    var i: usize = 0;
    while (i < actual.len) : (i += 1) {
        if (actual[i] == 0x1b) {
            i = std.mem.indexOfScalarPos(u8, actual, i, 'm').?;
        } else {
            try plain.append(testing.allocator, actual[i]);
        }
    }
    try testing.expectEqualStrings(expected, plain.items);
}

test "error output is flushed even when the caller skips its flush" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer.Discarding = .init(&buf);
    var in: std.Io.Reader = .fixed("");
    const root = try zli.Command.init(.{ .allocator = testing.allocator, .io = testing.io, .writer = &out.writer, .reader = &in }, .{ .name = "app", .description = "App" }, showHelp);
    defer root.deinit();
    var it = (std.process.Args{ .vector = &.{ "app", "extra" } }).iterate();
    try testing.expectError(error.UnknownCommand, root.execute(&it, .{}));
    try testing.expectEqual(0, out.writer.buffered().len);
}

test "run prints errors from the command once and returns the exit code" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.root = try zli.Command.init(h.options(), .{ .name = "app", .description = "App" }, failOnArg);
    try h.root.addPositionalArg(.{ .name = "what", .description = "", .required = false });

    var ok = (std.process.Args{ .vector = &.{"app"} }).iterate();
    try testing.expectEqual(0, h.root.run(&ok, .{}));
    try testing.expectEqualStrings("", h.output());

    var failing = (std.process.Args{ .vector = &.{ "app", "fail" } }).iterate();
    try testing.expectEqual(1, h.root.run(&failing, .{}));
    try testing.expectEqualStrings("error: DiskFull\n", h.output());

    // Parse errors already explain themselves, so no extra "error:" line.
    h.out.clearRetainingCapacity();
    var bad_flag = (std.process.Args{ .vector = &.{ "app", "--nope" } }).iterate();
    try testing.expectEqual(1, h.root.run(&bad_flag, .{}));
    try testing.expectEqualStrings("Unknown flag: --nope\n\nRun: 'app --help'\n", h.output());
}

fn failOnArg(ctx: zli.CommandContext) !void {
    if (ctx.getArg("what")) |_| return error.DiskFull;
}

test "Command._max_len is gone (v6)" {
    try testing.expect(!@hasField(zli.Command, "_max_len"));
}

test "Command.init frees everything when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, initAndDeinit, .{});
}

fn initAndDeinit(allocator: std.mem.Allocator) !void {
    var out: std.Io.Writer.Discarding = .init(&.{});
    var in: std.Io.Reader = .fixed("");
    const cmd = try zli.Command.init(.{ .allocator = allocator, .io = testing.io, .writer = &out.writer, .reader = &in }, .{ .name = "app", .description = "App" }, showHelp);
    cmd.deinit();
}

test "help flag before the subcommand shows the subcommand's help" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(&.{ "hello", "--help", "greet" }, null);
    try testing.expect(std.mem.indexOf(u8, h.output(), "Usage: hello greet [options] <name>") != null);
}

test "root without args runs root exec (help)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    try h.run(&.{"hello"}, null);
    const out = h.output();
    try testing.expect(std.mem.indexOf(u8, out, "A tiny zli app") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Greet someone") != null);
}

test "context data reaches the command" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    var calls: u32 = 0;
    try h.run(&.{ "hello", "count" }, &calls);
    try testing.expectEqual(1, calls);
}

test "errors" {
    try expectRunError(&.{ "hello", "greet" }, error.MissingArgs, "Missing 1 positional argument(s).");
    try expectRunError(&.{ "hello", "greet", "Ada", "Bob" }, error.TooManyArgs, "Expected at most 1, got 2");
    try expectRunError(&.{ "hello", "greet", "Ada", "--nope" }, error.UnknownFlag, "Unknown flag: --nope");
    try expectRunError(&.{ "hello", "greet", "Ada", "-x" }, error.UnknownFlag, "Unknown flag shortcut: -x");
    try expectRunError(&.{ "hello", "greet", "Ada", "--times=abc" }, error.InvalidFlagValue, "Invalid value for flag --times");
    try expectRunError(&.{ "hello", "greet", "Ada", "--times" }, error.MissingFlagValue, "Missing value for flag --times");
    try expectRunError(&.{ "hello", "greet", "Ada", "-tv", "2" }, error.InvalidFlagShortcut, "must be last in group");
    try expectRunError(&.{ "hello", "greet", "Ada", "--no-times" }, error.InvalidFlagNegation, "does not accept negation");
    try expectRunError(&.{ "hello", "count", "extra" }, error.UnknownCommand, "Unknown command: 'extra'");
    try expectRunError(&.{ "hello", "old" }, error.CommandDeprecated, "Use 'greet' instead.");
}

test "variadic positional must be last" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try buildCli(&h);
    const cmd = h.root.findCommand("echo").?;
    try testing.expectError(error.InvalidPositionalArgOrder, cmd.addPositionalArg(.{ .name = "x", .description = "", .required = false }));
}

test "spinner without a terminal prints only finished lines" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var spinner = zli.Spinner.init(testing.io, &out.writer, testing.allocator, .{});
    defer spinner.deinit();

    try spinner.succeed("no start needed", .{});
    try spinner.start("step {d}", .{1});
    try spinner.updateMessage("still step {d}", .{1});
    try spinner.print("log\n", .{});
    try spinner.fail("step {d} {s}", .{ 1, "failed" });
    try spinner.start("step 2", .{});
    try spinner.warn("careful", .{});

    try testing.expectEqualStrings("✔ no start needed\nlog\n✖ step 1 failed\n⚠ careful\n", out.written());
}
