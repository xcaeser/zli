const std = @import("std");
const builtin = @import("lib/builtin.zig");
pub const styles = builtin.styles;

const Writer = std.io.GenericWriter(
    std.fs.File,
    std.fs.File.WriteError,
    std.fs.File.write,
);

/// Represents the type of a flag, which can be a boolean, integer, or string.
pub const FlagType = enum {
    Bool,
    Int,
    String,
};

/// Represents the value of a flag, which can be a boolean, integer, or string.
/// The type of the value is determined by the associated `FlagType`.
pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i32,
    String: []const u8,
};

/// Represents a command-line flag, such as `--verbose` or `-v`.
/// Flags can have a name, an optional shortcut, a description, a type, a default value, and visibility settings.
pub const Flag = struct {
    name: []const u8,
    shortcut: ?[]const u8 = null,
    description: []const u8,
    type: FlagType,
    default_value: FlagValue,
    hidden: bool = false,

    /// Evaluates the given value against the flag's type and returns the corresponding `FlagValue`.
    /// Returns an error if the value is invalid for the flag's type.
    fn evaluateValueType(self: *const Flag, value: []const u8) !FlagValue {
        return switch (self.type) {
            .Bool => {
                if (std.mem.eql(u8, value, "true")) return FlagValue{ .Bool = true };
                if (std.mem.eql(u8, value, "false")) return FlagValue{ .Bool = false };
                return error.InvalidBooleanValue;
            },
            .Int => FlagValue{ .Int = try std.fmt.parseInt(i32, value, 10) },
            .String => FlagValue{ .String = value },
        };
    }

    /// Safely evaluates the given value against the flag's type, mapping any errors to `InvalidFlagValue`.
    fn safeEvaluate(self: *const Flag, value: []const u8) !FlagValue {
        return self.evaluateValueType(value) catch {
            return error.InvalidFlagValue;
        };
    }
};

/// Represents a positional argument for a command, such as a file name or a target.
/// Positional arguments are specified in the order they appear in the command-line input.
pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false,
};

/// Represents the context of a command execution, providing access to the command, its parent, flags, arguments, and additional data.
pub const CommandContext = struct {
    root: *Command,
    direct_parent: *Command,
    command: *Command,
    allocator: std.mem.Allocator,
    positional_args: []const []const u8,
    data: ?*anyopaque = null,

    /// Retrieves the value of a flag by its name and casts it to the specified type `T`.
    /// Falls back to the flag's default value if it is not explicitly set.
    pub fn flag(self: *const CommandContext, flag_name: []const u8, comptime T: type) T {
        if (self.command.flag_values.get(flag_name)) |val| {
            return switch (val) {
                .Bool => |b| if (T == bool) b else getDefaultValue(T),
                .Int => |i| if (@typeInfo(T) == .int) @as(T, @intCast(i)) else getDefaultValue(T),
                .String => |s| if (T == []const u8) s else getDefaultValue(T),
            };
        }

        if (self.command.findFlag(flag_name)) |found_flag| {
            return switch (found_flag.default_value) {
                .Bool => |b| if (T == bool) b else getDefaultValue(T),
                .Int => |i| if (@typeInfo(T) == .int) @as(T, @intCast(i)) else getDefaultValue(T),
                .String => |s| if (T == []const u8) s else getDefaultValue(T),
            };
        }

        // Should be unreachable if all flags have defaults and validation is correct.
        unreachable;
    }

    /// Retrieves the value of a positional argument by its name.
    /// Returns `null` if the argument is not provided or not defined.
    pub fn getArg(self: *const CommandContext, name: []const u8) ?[]const u8 {
        const spec = self.command.positional_args.items;
        for (spec, 0..) |arg, i| {
            if (std.mem.eql(u8, arg.name, name)) {
                if (i < self.positional_args.len) return self.positional_args[i];
                return null; // not provided
            }
        }
        return null; // not defined
    }

    /// Retrieves the context-specific data and casts it to the specified type `T`.
    pub fn getContextData(self: *const CommandContext, comptime T: type) *T {
        return @alignCast(@ptrCast(self.data.?));
    }
};

/// ExecFn is the type of function that is executed when the command is executed.
const ExecFn = *const fn (ctx: CommandContext) anyerror!void;

/// This is needed to fool the compiler that we are not doing dependency loop
/// common error would error: dependency loop detected if this function is not passed to the init function.
const ExecFnToPass = *const fn (ctx: CommandContext) anyerror!void;

/// Represents the metadata for a command, such as its name, description, version, and additional options.
pub const CommandOptions = struct {
    section_title: []const u8 = "General",
    name: []const u8,
    description: []const u8,
    version: ?std.SemanticVersion = null,
    commands_title: []const u8 = "Available commands",
    shortcut: ?[]const u8 = null,
    aliases: ?[]const []const u8 = null,
    short_description: ?[]const u8 = null,
    help: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    deprecated: bool = false,
    replaced_by: ?[]const u8 = null,
};

/// Represents a single command in the CLI, such as `run` or `version`.
/// Commands can have flags, positional arguments, subcommands, and an execution function.
pub const Command = struct {
    options: CommandOptions,

    flags_by_name: std.StringHashMap(Flag),
    flags_by_shortcut: std.StringHashMap(Flag),
    flag_values: std.StringHashMap(FlagValue),

    positional_args: std.ArrayList(PositionalArg),

    execFn: ExecFn,

    commands_by_name: std.StringHashMap(*Command),
    commands_by_shortcut: std.StringHashMap(*Command),
    command_by_aliases: std.StringHashMap(*Command),

    parent: ?*Command = null,
    allocator: std.mem.Allocator,
    stdout: Writer = std.io.getStdOut().writer(),
    stderr: Writer = std.io.getStdErr().writer(),

    /// Initializes a new command with the given options and execution function.
    /// Automatically adds a default `--help` flag to the command.
    pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFnToPass) !*Command {
        const cmd = try allocator.create(Command);
        cmd.* = Command{
            .options = options,
            .positional_args = std.ArrayList(PositionalArg).init(allocator),
            .execFn = execFn,
            .flags_by_name = std.StringHashMap(Flag).init(allocator),
            .flags_by_shortcut = std.StringHashMap(Flag).init(allocator),
            .flag_values = std.StringHashMap(FlagValue).init(allocator),
            .commands_by_name = std.StringHashMap(*Command).init(allocator),
            .commands_by_shortcut = std.StringHashMap(*Command).init(allocator),
            .command_by_aliases = std.StringHashMap(*Command).init(allocator),
            .allocator = allocator,
        };

        const helpFlag: Flag = .{
            .name = "help",
            .description = "Shows the help for a command",
            .shortcut = "h",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        };

        try cmd.addFlag(helpFlag);

        return cmd;
    }

    /// Deinitializes the command, freeing all associated resources.
    pub fn deinit(self: *Command) void {
        self.positional_args.deinit();

        self.flags_by_name.deinit();
        self.flags_by_shortcut.deinit();
        self.flag_values.deinit();

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            const cmd = entry.value_ptr.*;
            cmd.deinit();
        }
        self.commands_by_name.deinit();
        self.commands_by_shortcut.deinit();
        self.command_by_aliases.deinit();
        self.allocator.destroy(self);
    }

    /// Lists all subcommands of the current command, sorted alphabetically by name.
    pub fn listCommands(self: *const Command) !void {
        if (self.commands_by_name.count() == 0) {
            return;
        }

        try self.stdout.print("{s}:\n", .{self.options.commands_title});

        var commands = std.ArrayList(*Command).init(self.allocator);
        defer commands.deinit();

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            try commands.append(entry.value_ptr.*);
        }

        std.sort.insertion(*Command, commands.items, {}, struct {
            pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                return std.mem.order(u8, a.options.name, b.options.name) == .lt;
            }
        }.lessThan);

        try printAlignedCommands(commands.items);
    }

    /// Lists all subcommands grouped by their section titles.
    pub fn listCommandsBySection(self: *const Command) !void {
        if (self.commands_by_name.count() == 0) {
            return;
        }

        var section_map = std.StringHashMap(std.ArrayList(*Command)).init(self.allocator);
        defer {
            var it = section_map.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            section_map.deinit();
        }

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            const cmd = entry.value_ptr.*;
            const section = cmd.options.section_title;

            const list = try section_map.getOrPut(section);
            if (!list.found_existing) {
                list.value_ptr.* = std.ArrayList(*Command).init(self.allocator);
            }
            try list.value_ptr.*.append(cmd);
        }

        var sit = section_map.iterator();
        while (sit.next()) |entry| {
            const section = entry.key_ptr.*;
            const cmds = entry.value_ptr.*;

            try self.stdout.print("{s}:\n", .{section});

            std.sort.insertion(*Command, cmds.items, {}, struct {
                pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                    return std.mem.order(u8, a.options.name, b.options.name) == .lt;
                }
            }.lessThan);

            try printAlignedCommands(cmds.items);
            try self.stdout.print("\n", .{});
        }
    }

    /// Lists all flags of the current command, excluding hidden flags.
    pub fn listFlags(self: *const Command) !void {
        if (self.flags_by_name.count() == 0) {
            return;
        }

        try self.stdout.print("Flags:\n", .{});

        // Collect all flags into a list for processing
        var flags = std.ArrayList(Flag).init(self.allocator);
        defer flags.deinit();

        var it = self.flags_by_name.iterator();
        while (it.next()) |entry| {
            const flag = entry.value_ptr.*;
            if (!flag.hidden) {
                try flags.append(flag);
            }
        }

        try printAlignedFlags(flags.items);
    }

    /// Lists all positional arguments of the current command, including their descriptions and requirements.
    pub fn listPositionalArgs(self: *const Command) !void {
        if (self.positional_args.items.len == 0) return;

        try self.stdout.print("Arguments:\n", .{});

        var max_width: usize = 0;
        for (self.positional_args.items) |arg| {
            const name_len = arg.name.len;
            if (name_len > max_width) max_width = name_len;
        }

        for (self.positional_args.items) |arg| {
            const padding = max_width - arg.name.len;
            try self.stdout.print("  {s}", .{arg.name});
            try self.stdout.writeByteNTimes(' ', padding + 4); // Align to column
            try self.stdout.print("{s}", .{arg.description});
            if (arg.required) {
                try self.stdout.print(" (required)", .{});
            }
            if (arg.variadic) {
                try self.stdout.print(" (variadic)", .{});
            }
            try self.stdout.print("\n", .{});
        }

        try self.stdout.print("\n", .{});
    }

    /// Prints the usage line for the current command, including its flags and positional arguments.
    pub fn printUsageLine(self: *Command) !void {
        const parents = try self.getParents(self.allocator);
        defer parents.deinit();

        try self.stdout.print("Usage: ", .{});

        for (parents.items) |p| {
            try self.stdout.print("{s} ", .{p.options.name});
        }

        try self.stdout.print("{s} [options]", .{self.options.name});

        for (self.positional_args.items) |arg| {
            if (arg.required) {
                try self.stdout.print(" <{s}>", .{arg.name});
            } else {
                try self.stdout.print(" [{s}]", .{arg.name});
            }
            if (arg.variadic) {
                try self.stdout.print("...", .{});
            }
        }
    }

    /// Executes the command, parsing flags and arguments, and invoking the associated execution function.
    pub fn execute(self: *Command, context: struct { data: ?*anyopaque = null }) !void {
        var bw = std.io.bufferedWriter(self.stdout);
        defer bw.flush() catch {};

        var input = try std.process.argsWithAllocator(self.allocator);
        defer input.deinit();
        _ = input.skip(); // skip program name

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (input.next()) |arg| {
            try args.append(arg);
        }

        var pos_args = std.ArrayList([]const u8).init(self.allocator);
        defer pos_args.deinit();

        var cmd = self.findLeaf(&args) catch |err| {
            if (err == error.UnknownCommand) {
                std.process.exit(1);
            }
            return err;
        };

        cmd.checkDeprecated() catch std.process.exit(1);

        try cmd.parseArgsAndFlags(&args, &pos_args);
        cmd.parsePositionalArgs(&pos_args) catch std.process.exit(1);

        const root = self;
        const ctx = CommandContext{
            .root = root,
            .direct_parent = cmd.parent orelse root,
            .command = cmd,
            .allocator = cmd.allocator,
            .positional_args = pos_args.items,
            .data = context.data,
        };

        try cmd.execFn(ctx);
    }

    /// Displays the command error, suggesting the correct usage.
    fn displayCommandError(self: *Command) !void {
        const parents = try self.getParents(self.allocator);
        defer parents.deinit();

        try self.stderr.print("\nRun: '", .{});
        for (parents.items) |p| {
            try self.stderr.print("{s} ", .{p.options.name});
        }
        try self.stderr.print("{s} --help'\n", .{self.options.name});
    }
};

/// Progress indicator for long running operations
pub const Spinner = struct {};

// HELPER FUNCTIONS

/// Prints a list of commands aligned to the maximum width of the commands.
fn printAlignedCommands(commands: []*Command) !void {
    // Step 1: determine the maximum width of name + shortcut
    var max_width: usize = 0;
    for (commands) |cmd| {
        const name_len = cmd.options.name.len;
        const shortcut_len = if (cmd.options.shortcut) |s| s.len + 3 else 0; // " ({s})"
        const total_len = name_len + shortcut_len;
        if (total_len > max_width) max_width = total_len;
    }

    // Step 2: print each command with aligned description
    for (commands) |cmd| {
        const desc = cmd.options.short_description orelse cmd.options.description;

        // Print name
        try cmd.stdout.print("   {s}", .{cmd.options.name});

        // Print shortcut directly if exists
        if (cmd.options.shortcut) |s| {
            try cmd.stdout.print(" ({s})", .{s});
        }

        // Compute padding
        const name_len = cmd.options.name.len;
        var shortcut_len: usize = 0;
        var extra_parens: usize = 0;

        if (cmd.options.shortcut) |s| {
            shortcut_len = s.len;
            extra_parens = 3; // space + parentheses
        }

        const printed_width = name_len + shortcut_len + extra_parens;

        const padding = max_width - printed_width;

        try cmd.stdout.writeByteNTimes(' ', padding + 4); // 4-space gap between name and desc
        try cmd.stdout.print("{s}\n", .{desc});
    }
}

/// Prints a list of flags aligned to the maximum width of the flags.
fn printAlignedFlags(flags: []const Flag) !void {
    if (flags.len == 0) return;

    // Get stdout from the first flag's command context
    const stdout = std.io.getStdOut().writer();

    // Calculate maximum width for the flag name + shortcut part
    var max_width: usize = 0;
    for (flags) |flag| {
        var flag_width: usize = 0;

        // Add shortcut width if present: " -x, "
        if (flag.shortcut) |shortcut| {
            flag_width += 1 + shortcut.len + 2; // " -" + shortcut + ", "
        } else {
            flag_width += 5; // "     " (5 spaces for alignment)
        }

        // Add flag name width: "--flagname"
        flag_width += 2 + flag.name.len; // "--" + name

        if (flag_width > max_width) {
            max_width = flag_width;
        }
    }

    // Print each flag with proper alignment
    for (flags) |flag| {
        var current_width: usize = 0;

        // Print shortcut if available
        if (flag.shortcut) |shortcut| {
            try stdout.print(" -{s}, ", .{shortcut});
            current_width += 1 + shortcut.len + 2;
        } else {
            try stdout.print("     ", .{});
            current_width += 5;
        }

        // Print flag name
        try stdout.print("--{s}", .{flag.name});
        current_width += 2 + flag.name.len;

        // Calculate and add padding
        const padding = max_width - current_width;
        try stdout.writeByteNTimes(' ', padding + 4); // 4-space gap

        // Print description and type
        try stdout.print("{s} [{s}]", .{
            flag.description,
            @tagName(flag.type),
        });

        // Print default value
        switch (flag.type) {
            .Bool => try stdout.print(" (default: {s})", .{if (flag.default_value.Bool) "true" else "false"}),
            .Int => try stdout.print(" (default: {})", .{flag.default_value.Int}),
            .String => if (flag.default_value.String.len > 0) {
                try stdout.print(" (default: \"{s}\")", .{flag.default_value.String});
            },
        }
        try stdout.print("\n", .{});
    }
}

/// Pop the first element from the list and shift the rest
fn popFront(comptime T: type, list: *std.ArrayList(T)) !T {
    if (list.items.len == 0) return error.Empty;
    const first = list.items[0];
    // Shift remaining elements
    for (list.items[1..], 0..) |item, i| {
        list.items[i] = item;
    }
    _ = list.pop(); // remove the last (now duplicate) element
    return first;
}

// Test suite for CLI library
const testing = std.testing;

// HELPER FUNCTIONS TESTS
test "popFront: shifts elements correctly" {
    const allocator = testing.allocator;
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.appendSlice(&[_]i32{ 1, 2, 3, 4 });

    const first = try popFront(i32, &list);
    try testing.expectEqual(@as(i32, 1), first);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqualSlices(i32, &[_]i32{ 2, 3, 4 }, list.items);
}

test "popFront: single element" {
    const allocator = testing.allocator;
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(42);

    const first = try popFront(i32, &list);
    try testing.expectEqual(@as(i32, 42), first);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "popFront: empty list returns error" {
    const allocator = testing.allocator;
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();

    try testing.expectError(error.Empty, popFront(i32, &list));
}

// FLAG VALUE EVALUATION TESTS
test "Flag.evaluateValueType: boolean values" {
    const flag = Flag{
        .name = "verbose",
        .description = "Enable verbose output",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    };

    // Test valid boolean values
    const val_true = try flag.evaluateValueType("true");
    try testing.expect(val_true == .Bool and val_true.Bool == true);

    const val_false = try flag.evaluateValueType("false");
    try testing.expect(val_false == .Bool and val_false.Bool == false);

    // Test invalid boolean values
    try testing.expectError(error.InvalidBooleanValue, flag.evaluateValueType("yes"));
    try testing.expectError(error.InvalidBooleanValue, flag.evaluateValueType("1"));
    try testing.expectError(error.InvalidBooleanValue, flag.evaluateValueType("True"));
    try testing.expectError(error.InvalidBooleanValue, flag.evaluateValueType(""));
}

test "Flag.evaluateValueType: integer values" {
    const flag = Flag{
        .name = "port",
        .description = "Port number",
        .type = .Int,
        .default_value = .{ .Int = 8080 },
    };

    // Test valid integers
    const positive = try flag.evaluateValueType("1234");
    try testing.expectEqual(@as(i32, 1234), positive.Int);

    const negative = try flag.evaluateValueType("-42");
    try testing.expectEqual(@as(i32, -42), negative.Int);

    const zero = try flag.evaluateValueType("0");
    try testing.expectEqual(@as(i32, 0), zero.Int);

    // Test invalid integers
    try testing.expectError(error.InvalidCharacter, flag.evaluateValueType("abc"));
    try testing.expectError(error.InvalidCharacter, flag.evaluateValueType("12.34"));
    try testing.expectError(error.InvalidCharacter, flag.evaluateValueType(""));
}

test "Flag.evaluateValueType: string values" {
    const flag = Flag{
        .name = "output",
        .description = "Output file",
        .type = .String,
        .default_value = .{ .String = "output.txt" },
    };

    // Test various string values
    const normal = try flag.evaluateValueType("hello");
    try testing.expectEqualStrings("hello", normal.String);

    const empty = try flag.evaluateValueType("");
    try testing.expectEqualStrings("", empty.String);

    const with_spaces = try flag.evaluateValueType("hello world");
    try testing.expectEqualStrings("hello world", with_spaces.String);

    const special_chars = try flag.evaluateValueType("test@#$%");
    try testing.expectEqualStrings("test@#$%", special_chars.String);
}

test "Flag.safeEvaluate: error handling" {
    const int_flag = Flag{
        .name = "count",
        .description = "Count value",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    };

    // Should map specific errors to InvalidFlagValue
    try testing.expectError(error.InvalidFlagValue, int_flag.safeEvaluate("not_a_number"));
    try testing.expectError(error.InvalidFlagValue, int_flag.safeEvaluate("12.34"));

    // Valid values should work
    const valid = try int_flag.safeEvaluate("123");
    try testing.expectEqual(@as(i32, 123), valid.Int);
}

// COMMAND INITIALIZATION TESTS
test "Command.init: creates command with default help flag" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test-cmd",
        .description = "Test command",
    }, dummyExec);
    defer cmd.deinit();

    // Should have help flag by default
    try testing.expect(cmd.findFlag("help") != null);
    try testing.expect(cmd.findFlag("h") != null);

    const help_flag = cmd.findFlag("help").?;
    try testing.expectEqualStrings("help", help_flag.name);
    try testing.expect(help_flag.type == .Bool);
    try testing.expect(help_flag.default_value.Bool == false);
}

test "Command.init: proper initialization of all fields" {
    const allocator = testing.allocator;
    const options = CommandOptions{
        .name = "mycmd",
        .description = "My command",
        .version = std.SemanticVersion{ .major = 1, .minor = 0, .patch = 0 },
        .shortcut = "mc",
    };

    const cmd = try Command.init(allocator, options, dummyExec);
    defer cmd.deinit();

    try testing.expectEqualStrings("mycmd", cmd.options.name);
    try testing.expectEqualStrings("My command", cmd.options.description);
    try testing.expect(cmd.options.version != null);
    try testing.expectEqualStrings("mc", cmd.options.shortcut.?);
    try testing.expect(cmd.parent == null);
    try testing.expectEqual(@as(usize, 0), cmd.positional_args.items.len);
}

// FLAG MANAGEMENT TESTS
test "Command.addFlag: adds flag correctly" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    const flag = Flag{
        .name = "verbose",
        .shortcut = "v",
        .description = "Enable verbose output",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    };

    try cmd.addFlag(flag);

    // Should be findable by name and shortcut
    const by_name = cmd.findFlag("verbose");
    try testing.expect(by_name != null);
    try testing.expectEqualStrings("verbose", by_name.?.name);

    const by_shortcut = cmd.findFlag("v");
    try testing.expect(by_shortcut != null);
    try testing.expectEqualStrings("verbose", by_shortcut.?.name);

    // Should have default value set
    const default_val = cmd.flag_values.get("verbose");
    try testing.expect(default_val != null);
    try testing.expect(default_val.?.Bool == false);
}

test "Command.addFlag: flag without shortcut" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    const flag = Flag{
        .name = "no-shortcut",
        .shortcut = null,
        .description = "Flag without shortcut",
        .type = .String,
        .default_value = .{ .String = "default" },
    };

    try cmd.addFlag(flag);

    try testing.expect(cmd.findFlag("no-shortcut") != null);
    // Shortcut lookup should return null since there's no shortcut
    try testing.expect(cmd.flags_by_shortcut.count() == 1); // only 'h' from help
}

test "Command.addFlags: adds multiple flags" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    const flags = [_]Flag{
        .{
            .name = "flag1",
            .shortcut = "1",
            .description = "First flag",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "flag2",
            .shortcut = "2",
            .description = "Second flag",
            .type = .Int,
            .default_value = .{ .Int = 42 },
        },
    };

    try cmd.addFlags(&flags);

    try testing.expect(cmd.findFlag("flag1") != null);
    try testing.expect(cmd.findFlag("flag2") != null);
    try testing.expect(cmd.findFlag("1") != null);
    try testing.expect(cmd.findFlag("2") != null);
}

// POSITIONAL ARGUMENT TESTS
test "Command.addPositionalArg: adds argument correctly" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    const arg = PositionalArg{
        .name = "input",
        .description = "Input file",
        .required = true,
    };

    try cmd.addPositionalArg(arg);

    try testing.expectEqual(@as(usize, 1), cmd.positional_args.items.len);
    try testing.expectEqualStrings("input", cmd.positional_args.items[0].name);
    try testing.expect(cmd.positional_args.items[0].required);
}

test "Command.addPositionalArg: variadic arg validation" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    // Add regular arg first
    try cmd.addPositionalArg(.{
        .name = "input",
        .description = "Input file",
        .required = true,
    });

    // Add variadic arg
    try cmd.addPositionalArg(.{
        .name = "files",
        .description = "Multiple files",
        .required = false,
        .variadic = true,
    });

    // This should fail in actual implementation - testing error case would need process.exit handling
    // For now, just verify the args were added
    try testing.expectEqual(@as(usize, 2), cmd.positional_args.items.len);
}

// COMMAND HIERARCHY TESTS
test "Command.addCommand: establishes parent-child relationship" {
    const allocator = testing.allocator;
    const root = try Command.init(allocator, .{
        .name = "root",
        .description = "Root command",
    }, dummyExec);
    defer root.deinit();

    const child = try Command.init(allocator, .{
        .name = "child",
        .description = "Child command",
        .shortcut = "c",
    }, dummyExec);

    try root.addCommand(child);

    // Child should have parent set
    try testing.expect(child.parent == root);

    // Root should be able to find child
    try testing.expect(root.findCommand("child") == child);
    try testing.expect(root.findCommand("c") == child);
}

test "Command.addCommand: with aliases" {
    const allocator = testing.allocator;
    const root = try Command.init(allocator, .{
        .name = "root",
        .description = "Root",
    }, dummyExec);
    defer root.deinit();

    const aliases = [_][]const u8{ "alias1", "alias2", "alias3" };
    const child = try Command.init(allocator, .{
        .name = "child",
        .description = "Child with aliases",
        .aliases = &aliases,
    }, dummyExec);

    try root.addCommand(child);

    // Should be findable by all aliases
    for (aliases) |alias| {
        try testing.expect(root.findCommand(alias) == child);
    }
}

test "Command.findLeaf: traverses command hierarchy" {
    const allocator = testing.allocator;
    const root = try Command.init(allocator, .{
        .name = "root",
        .description = "Root",
    }, dummyExec);
    defer root.deinit();

    const level1 = try Command.init(allocator, .{
        .name = "level1",
        .description = "Level 1",
    }, dummyExec);

    const level2 = try Command.init(allocator, .{
        .name = "level2",
        .description = "Level 2",
    }, dummyExec);

    try root.addCommand(level1);
    try level1.addCommand(level2);

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&[_][]const u8{ "level1", "level2" });

    const leaf = try root.findLeaf(&args);
    try testing.expect(leaf == level2);

    // Args should be consumed
    try testing.expectEqual(@as(usize, 0), args.items.len);
}

test "Command.findLeaf: stops at unknown command" {
    const allocator = testing.allocator;
    const root = try Command.init(allocator, .{
        .name = "root",
        .description = "Root",
    }, dummyExec);
    defer root.deinit();

    const child = try Command.init(allocator, .{
        .name = "child",
        .description = "Child",
    }, dummyExec);

    try root.addCommand(child);

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&[_][]const u8{ "child", "unknown" });

    const result = root.findLeaf(&args);
    try testing.expectError(error.UnknownCommand, result);
}

// FLAG PARSING TESTS
test "parseArgsAndFlags: long flag with equals" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "output",
        .description = "Output file",
        .type = .String,
        .default_value = .{ .String = "" },
    });

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("--output=file.txt");

    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    try cmd.parseArgsAndFlags(&args, &positionals);

    const value = cmd.flag_values.get("output").?;
    try testing.expectEqualStrings("file.txt", value.String);
    try testing.expectEqual(@as(usize, 0), positionals.items.len);
}

test "parseArgsAndFlags: boolean flag variations" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlags(&[_]Flag{
        .{
            .name = "verbose",
            .shortcut = "v",
            .description = "Verbose",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "quiet",
            .description = "Quiet",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
    });

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&[_][]const u8{ "--verbose", "--quiet=true", "-v" });

    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    try cmd.parseArgsAndFlags(&args, &positionals);

    try testing.expect(cmd.flag_values.get("verbose").?.Bool);
    try testing.expect(cmd.flag_values.get("quiet").?.Bool);
}

test "parseArgsAndFlags: short flag grouping" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlags(&[_]Flag{
        .{
            .name = "all",
            .shortcut = "a",
            .description = "All",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "long",
            .shortcut = "l",
            .description = "Long",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "human",
            .shortcut = "h",
            .description = "Human readable",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
    });

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("-alh");

    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    try cmd.parseArgsAndFlags(&args, &positionals);

    try testing.expect(cmd.flag_values.get("all").?.Bool);
    try testing.expect(cmd.flag_values.get("long").?.Bool);
    // Note: 'h' conflicts with help flag, this test shows the issue
}

test "parseArgsAndFlags: mixed flags and positionals" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "count",
        .shortcut = "c",
        .description = "Count",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    });

    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.appendSlice(&[_][]const u8{ "file1", "--count", "5", "file2" });

    var positionals = std.ArrayList([]const u8).init(allocator);
    defer positionals.deinit();

    try cmd.parseArgsAndFlags(&args, &positionals);

    try testing.expectEqual(@as(i32, 5), cmd.flag_values.get("count").?.Int);
    try testing.expectEqual(@as(usize, 2), positionals.items.len);
    try testing.expectEqualStrings("file1", positionals.items[0]);
    try testing.expectEqualStrings("file2", positionals.items[1]);
}

// COMMAND CONTEXT TESTS
test "CommandContext.flag: retrieves set flag value" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "port",
        .description = "Port number",
        .type = .Int,
        .default_value = .{ .Int = 8080 },
    });

    // Simulate setting a flag value
    try cmd.flag_values.put("port", .{ .Int = 3000 });

    const ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &[_][]const u8{},
    };

    try testing.expectEqual(@as(i32, 3000), ctx.flag("port", i32));
}

test "CommandContext.flag: fallback to default value" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addFlag(.{
        .name = "debug",
        .description = "Debug mode",
        .type = .Bool,
        .default_value = .{ .Bool = true },
    });

    const ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &[_][]const u8{},
    };

    // Should return default since flag_values doesn't have "debug" set to a different value
    try testing.expect(ctx.flag("debug", bool));
}

test "CommandContext.getArg: retrieves positional argument" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addPositionalArg(.{
        .name = "username",
        .description = "Username",
        .required = true,
    });

    try cmd.addPositionalArg(.{
        .name = "password",
        .description = "Password",
        .required = false,
    });

    const args = [_][]const u8{ "john", "secret123" };
    const ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &args,
    };

    try testing.expectEqualStrings("john", ctx.getArg("username").?);
    try testing.expectEqualStrings("secret123", ctx.getArg("password").?);
    try testing.expect(ctx.getArg("nonexistent") == null);
}

test "CommandContext.getArg: missing optional argument" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    try cmd.addPositionalArg(.{
        .name = "required",
        .description = "Required arg",
        .required = true,
    });

    try cmd.addPositionalArg(.{
        .name = "optional",
        .description = "Optional arg",
        .required = false,
    });

    const args = [_][]const u8{"onlyRequired"};
    const ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &args,
    };

    try testing.expectEqualStrings("onlyRequired", ctx.getArg("required").?);
    try testing.expect(ctx.getArg("optional") == null);
}

test "CommandContext.getContextData: type casting" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    const TestData = struct {
        value: i32,
        name: []const u8,
    };

    var data = TestData{ .value = 42, .name = "test" };

    const ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &[_][]const u8{},
        .data = &data,
    };

    const retrieved = ctx.getContextData(TestData);
    try testing.expectEqual(@as(i32, 42), retrieved.value);
    try testing.expectEqualStrings("test", retrieved.name);
}

// INTEGRATION TESTS
test "full command parsing workflow" {
    const allocator = testing.allocator;

    // Create root command
    const root = try Command.init(allocator, .{
        .name = "myapp",
        .description = "My application",
        .version = std.SemanticVersion{ .major = 1, .minor = 2, .patch = 3 },
    }, dummyExec);
    defer root.deinit();

    // Add flags to root
    try root.addFlags(&[_]Flag{
        .{
            .name = "verbose",
            .shortcut = "v",
            .description = "Verbose output",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "config",
            .shortcut = "c",
            .description = "Config file",
            .type = .String,
            .default_value = .{ .String = "config.json" },
        },
    });

    // Create subcommand
    const deploy_cmd = try Command.init(allocator, .{
        .name = "deploy",
        .description = "Deploy application",
        .shortcut = "d",
    }, dummyExec);

    try deploy_cmd.addPositionalArg(.{
        .name = "environment",
        .description = "Target environment",
        .required = true,
    });

    try deploy_cmd.addFlag(.{
        .name = "force",
        .shortcut = "f",
        .description = "Force deployment",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });

    try root.addCommand(deploy_cmd);

    // Test command finding
    try testing.expect(root.findCommand("deploy") == deploy_cmd);
    try testing.expect(root.findCommand("d") == deploy_cmd);

    // Test flag inheritance and parsing would need more complex setup
    // This demonstrates the structure for integration testing
}

// ERROR HANDLING TESTS
test "error handling: unknown flag" {
    const allocator = testing.allocator;
    const cmd = try Command.init(allocator, .{
        .name = "test",
        .description = "Test",
    }, dummyExec);
    defer cmd.deinit();

    // In a real scenario, this would trigger process.exit(1)
    // For testing, we'd need to capture stderr or modify the error handling
    try testing.expect(cmd.findFlag("nonexistent") == null);
}

test "error handling: invalid flag value type" {
    const int_flag = Flag{
        .name = "count",
        .description = "Count",
        .type = .Int,
        .default_value = .{ .Int = 0 },
    };

    try testing.expectError(error.InvalidFlagValue, int_flag.safeEvaluate("not_a_number"));
}

// UTILITY FUNCTIONS FOR TESTS
fn dummyExec(_: CommandContext) !void {
    // Do nothing - just for testing
}
