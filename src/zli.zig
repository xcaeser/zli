const std = @import("std");
const builtin = @import("lib/builtin.zig");
const styles = builtin.styles;

const Writer = std.io.GenericWriter(
    std.fs.File,
    std.fs.File.WriteError,
    std.fs.File.write,
);

pub const FlagType = enum {
    Bool,
    Int,
    String,
};

pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i32,
    String: []const u8,
};

pub const Flag = struct {
    name: []const u8,
    shortcut: ?[]const u8 = null,
    description: []const u8,
    type: FlagType,
    default_value: FlagValue,
    hidden: bool = false,

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

    fn safeEvaluate(self: *const Flag, value: []const u8) !FlagValue {
        return self.evaluateValueType(value) catch {
            return error.InvalidFlagValue;
        };
    }
};

pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false,
};

pub const CommandContext = struct {
    root: *const Command,
    direct_parent: *const Command,
    command: *Command,
    allocator: std.mem.Allocator,
    positional_args: []const []const u8,
    data: ?*anyopaque = null,

    // TODO: fix panic: integer cast truncated bits - later im tired
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

    fn getDefaultValue(comptime T: type) T {
        return switch (@typeInfo(T)) {
            .bool => false,
            .int => 0,
            .pointer => |ptr_info| if (ptr_info.child == u8) "" else @compileError("Unsupported pointer type"),
            else => @compileError("Unsupported type for flag"),
        };
    }

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

    pub fn getContextData(self: *const CommandContext, comptime T: type) *T {
        return @alignCast(@ptrCast(self.data.?));
    }
};

const ExecFn = *const fn (ctx: CommandContext) anyerror!void;

/// This is needed to fool the compiler that we are not doing dependency loop
/// common error would error: dependency loop detected if this function is not passed to the init function.
const ExecFnToPass = *const fn (ctx: CommandContext) anyerror!void;

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
    stdout: Writer,
    stderr: Writer,

    pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFnToPass) !*Command {
        const cmd = try allocator.create(Command);
        cmd.* = Command{
            .stdout = std.io.getStdOut().writer(),
            .stderr = std.io.getStdErr().writer(),
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

    pub fn listFlags(self: *const Command) !void {
        if (self.flags_by_name.count() == 0) {
            return;
        }

        try self.stdout.print("Flags:\n", .{});
        var it = self.flags_by_name.iterator();
        while (it.next()) |entry| {
            const flag = entry.value_ptr.*;
            if (flag.hidden == true) {
                continue;
            }
            // Print shortcut if available
            if (flag.shortcut) |shortcut| {
                try self.stdout.print(" -{s}, ", .{shortcut});
            } else {
                try self.stdout.print("     ", .{});
            }
            // Print flag name and description
            try self.stdout.print("--{s}\t{s} [{s}]", .{
                flag.name,
                flag.description,
                @tagName(flag.type),
            });
            // Print default value
            switch (flag.type) {
                .Bool => try self.stdout.print(" (default: {s})", .{if (flag.default_value.Bool) "true" else "false"}),
                .Int => try self.stdout.print(" (default: {})", .{flag.default_value.Int}),
                .String => if (flag.default_value.String.len > 0) {
                    try self.stdout.print(" (default: \"{s}\")", .{flag.default_value.String});
                },
            }
            try self.stdout.print("\n", .{});
        }
    }

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

    pub fn listAliases(self: *Command) !void {
        if (self.options.aliases) |aliases| {
            if (aliases.len == 0) return;
            try self.stdout.print("Aliases: ", .{});
            for (aliases, 0..) |alias, i| {
                try self.stdout.print("{s}", .{alias});
                if (i < aliases.len - 1) {
                    try self.stdout.print(", ", .{});
                }
            }
        }
    }

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

    pub fn showInfo(self: *const Command) !void {
        try self.stdout.print("{s}{s}{s}\n", .{ styles.BOLD, self.options.description, styles.RESET });
        if (self.options.version) |version| try self.stdout.print("{s}v{}{s}\n", .{ styles.DIM, version, styles.RESET });
    }

    pub fn showVersion(self: *const Command) !void {
        if (self.options.version) |version| try self.stdout.print("{}\n", .{version});
    }

    pub fn printHelp(self: *Command) !void {
        try self.checkDeprecated();
        if (!self.options.deprecated) {
            try self.showInfo();
            try self.stdout.print("\n", .{});

            if (self.options.help) |help| {
                try self.stdout.print("{s}\n\n", .{help});
            }

            const parents = try self.getParents(self.allocator);
            defer parents.deinit();

            // Usage
            if (self.options.usage) |usage| {
                try self.stdout.print("Usage: {s}\n", .{usage});
            } else {
                try self.printUsageLine();
            }

            if (self.options.aliases) |aliases| {
                if (aliases.len > 0) {
                    try self.stdout.print("\n\n", .{});
                }
            }

            // Aliases
            try self.listAliases();

            // Sub commands
            try self.stdout.print("\n", .{});

            if (self.commands_by_name.count() > 0) try self.stdout.print("\n", .{});
            try self.listCommands();
            try self.stdout.print("\n", .{});

            // Flags
            try self.listFlags();
            if (self.flags_by_name.count() > 0) try self.stdout.print("\n", .{});

            // Arguments
            try self.listPositionalArgs();

            const has_subcommands = self.commands_by_name.count() > 0;

            try self.stdout.print("Use \"", .{});
            for (parents.items) |p| {
                try self.stdout.print("{s} ", .{p.options.name});
            }
            try self.stdout.print("{s}", .{self.options.name});

            if (has_subcommands) {
                try self.stdout.print(" [command]", .{});
            }
            try self.stdout.print(" --help\" for more information.\n", .{});
        }
    }

    pub fn getParents(self: *Command, allocator: std.mem.Allocator) !std.ArrayList(*Command) {
        var list = std.ArrayList(*Command).init(allocator);

        var cmd = self;
        while (cmd.parent) |p| {
            try list.append(p);
            cmd = p;
        }

        std.mem.reverse(*Command, list.items);
        return list;
    }

    pub fn addCommand(self: *Command, command: *Command) !void {
        command.parent = self;
        try self.commands_by_name.put(command.options.name, command);
        if (command.options.aliases) |aliases| {
            for (aliases) |alias| {
                try self.command_by_aliases.put(alias, command);
            }
        }
        if (command.options.shortcut) |shortcut| try self.commands_by_shortcut.put(shortcut, command);
    }

    pub fn addCommands(self: *Command, commands: []const *Command) !void {
        for (commands) |cmd| try self.addCommand(cmd);
    }

    pub fn addPositionalArg(self: *Command, pos_arg: PositionalArg) !void {
        if (self.positional_args.items.len > 0) {
            const last_arg = self.positional_args.items[self.positional_args.items.len - 1];
            if (last_arg.variadic) {
                try self.stderr.print("Variadic args should only appear at the end.\n", .{});
                std.process.exit(1);
            }
        }
        try self.positional_args.append(pos_arg);
    }

    pub fn addFlag(self: *Command, flag: Flag) !void {
        try self.flags_by_name.put(flag.name, flag);
        if (flag.shortcut) |shortcut| try self.flags_by_shortcut.put(shortcut, flag);

        try self.flag_values.put(flag.name, flag.default_value);
    }

    pub fn addFlags(self: *Command, flags: []const Flag) !void {
        for (flags) |flag| {
            try self.addFlag(flag);
        }
    }

    // cli run --faas pp --me --op=77 -p -abc xxxx yyyy zzzz
    fn parseArgsAndFlags(self: *Command, args: *std.ArrayList([]const u8), out_positionals: *std.ArrayList([]const u8)) !void {
        while (args.items.len > 0) {
            const arg = args.items[0];

            if (args.items.len > 0 and
                (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")))
            {
                try self.printHelp();
                std.process.exit(0);
            }

            // Handle flags (all the existing parseFlags logic)
            if (std.mem.startsWith(u8, arg, "--")) {
                // --flag=value
                if (std.mem.indexOf(u8, arg[2..], "=")) |eql_index| {
                    const flag_name = arg[2..][0..eql_index];
                    const value = arg[2 + eql_index + 1 ..];
                    const flag = self.findFlag(flag_name);
                    if (flag == null) {
                        try self.stderr.print("Unknown flag: --{s}\n", .{flag_name});
                        try self.displayCommandError();
                        std.process.exit(1);
                    }
                    const flag_value = flag.?.safeEvaluate(value) catch {
                        try self.stderr.print("Invalid value for flag --{s}: '{s}'\n", .{ flag_name, value });
                        try self.stderr.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
                        try self.displayCommandError();
                        std.process.exit(1);
                    };
                    try self.flag_values.put(flag.?.name, flag_value);
                    _ = try popFront([]const u8, args);
                }
                // --flag [value] or boolean
                else {
                    const flag_name = arg[2..];
                    const flag = self.findFlag(flag_name);
                    if (flag == null) {
                        try self.stderr.print("Unknown flag: --{s}\n", .{flag_name});
                        try self.displayCommandError();
                        std.process.exit(1);
                    }
                    const has_next = args.items.len > 1;
                    const next_value = if (has_next) args.items[1] else null;

                    if (flag.?.type == .Bool) {
                        if (next_value) |val| {
                            const is_true = std.mem.eql(u8, val, "true");
                            const is_false = std.mem.eql(u8, val, "false");
                            if (is_true or is_false) {
                                try self.flag_values.put(flag.?.name, .{ .Bool = is_true });
                                _ = try popFront([]const u8, args); // --flag
                                _ = try popFront([]const u8, args); // true/false
                                continue;
                            }
                        }
                        try self.flag_values.put(flag.?.name, .{ .Bool = true });
                        _ = try popFront([]const u8, args);
                    } else {
                        if (!has_next) {
                            try self.stderr.print("Missing value for flag --{s}\n", .{flag_name});
                            try self.displayCommandError();
                            std.process.exit(1);
                        }
                        const value = args.items[1];
                        const flag_value = flag.?.safeEvaluate(value) catch {
                            try self.stderr.print("Invalid value for flag --{s}: '{s}'\n", .{ flag_name, value });
                            try self.stderr.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
                            try self.displayCommandError();
                            std.process.exit(1);
                        };
                        try self.flag_values.put(flag.?.name, flag_value);
                        _ = try popFront([]const u8, args); // --flag
                        _ = try popFront([]const u8, args); // value
                    }
                }
            }
            // -abc short flags
            else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.eql(u8, arg, "-")) {
                const shortcuts = arg[1..];
                var j: usize = 0;
                while (j < shortcuts.len) : (j += 1) {
                    const shortcut = shortcuts[j .. j + 1];
                    const flag = self.findFlag(shortcut);
                    if (flag == null) {
                        try self.stderr.print("Unknown flag: -{c}\n", .{shortcuts[j]});
                        std.process.exit(1);
                    }
                    if (flag.?.type == .Bool) {
                        try self.flag_values.put(flag.?.name, .{ .Bool = true });
                    } else {
                        if (j < shortcuts.len - 1) {
                            try self.stderr.print("Flag -{c} ({s}) must be last in group since it expects a value\n", .{ shortcuts[j], flag.?.name });
                            std.process.exit(1);
                        }
                        if (args.items.len < 2) {
                            try self.stderr.print("Missing value for flag -{c} ({s})\n", .{ shortcuts[j], flag.?.name });
                            std.process.exit(1);
                        }
                        const value = args.items[1];
                        const flag_value = flag.?.safeEvaluate(value) catch {
                            try self.stderr.print("Invalid value for flag -{c} ({s}): '{s}'\n", .{ shortcuts[j], flag.?.name, value });
                            try self.stderr.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
                            std.process.exit(1);
                        };
                        try self.flag_values.put(flag.?.name, flag_value);
                        _ = try popFront([]const u8, args); // value
                    }
                }
                _ = try popFront([]const u8, args); // -abc
            }
            // Positional argument
            else {
                const val = try popFront([]const u8, args);
                try out_positionals.append(val);
            }
        }
    }

    fn findFlag(self: *Command, name_or_shortcut: []const u8) ?Flag {
        if (self.flags_by_name.get(name_or_shortcut)) |flag| return flag;
        if (self.flags_by_shortcut.get(name_or_shortcut)) |flag| return flag;
        return null;
    }

    fn parsePositionalArgs(self: *Command, args: *std.ArrayList([]const u8)) !void {
        const expected = self.positional_args.items;

        var required_count: u8 = 0;
        for (expected) |value| {
            if (value.required) required_count += 1;
        }

        if (args.items.len < required_count) {
            try self.stderr.print("Missing {d} positional argument(s).\n\nExpected: ", .{required_count});

            var first = true;
            for (expected) |arg| {
                if (arg.required) {
                    if (!first) try self.stderr.print(", ", .{});
                    try self.stderr.print("{s}", .{arg.name});
                    first = false;
                }
            }

            try self.stderr.print("\n", .{});
            try self.displayCommandError();
            std.process.exit(1);
        }

        if (expected.len > 0) {
            const last_arg = expected[expected.len - 1];
            if (!last_arg.variadic and args.items.len > expected.len) {
                try self.stderr.print("Too many positional arguments. Expected at most {}.\n", .{expected.len});
                try self.displayCommandError();
                std.process.exit(1);
            }
        }
    }

    pub fn findCommand(self: *const Command, name_or_shortcut: []const u8) ?*Command {
        if (self.commands_by_name.get(name_or_shortcut)) |cmd| return cmd;
        if (self.command_by_aliases.get(name_or_shortcut)) |cmd| return cmd;
        if (self.commands_by_shortcut.get(name_or_shortcut)) |cmd| return cmd;
        return null;
    }

    fn checkDeprecated(self: *const Command) !void {
        if (self.options.deprecated) {
            if (self.options.version) |version| {
                try self.stdout.print("'{s}' v{} is deprecated\n", .{ self.options.name, version });
            } else {
                try self.stdout.print("'{s}' is deprecated\n", .{self.options.name});
            }

            if (self.options.replaced_by) |new_cmd_name| {
                try self.stdout.print("\nUse '{s}' instead.\n", .{new_cmd_name});
            }

            if (self.parent) |parent| {
                try self.stdout.print("\nRun '{s} [command] --help' for more information about a command.\n", .{parent.options.name});
            }

            std.process.exit(1);
        }
    }

    // Traverse the commands to find the last one in the user input
    fn findLeaf(self: *Command, args: *std.ArrayList([]const u8)) !*Command {
        var current = self;

        while (args.items.len > 0 and !std.mem.startsWith(u8, args.items[0], "-")) {
            const name = args.items[0];
            const maybe_next = current.findCommand(name);

            if (maybe_next == null) {
                // Check if the current command expects positional arguments
                const expects_pos_args = current.positional_args.items.len > 0;
                if (!expects_pos_args) {
                    try current.stderr.print("Unknown command: '{s}'\n", .{name});
                    try current.displayCommandError();
                    std.process.exit(1);
                }
                break;
            }

            _ = try popFront([]const u8, args);
            current = maybe_next.?;
        }

        return current;
    }

    // Need to make find command, parse flags and parse pos_args execution in parallel
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

        var cmd = try self.findLeaf(&args);

        try cmd.checkDeprecated();

        try cmd.parseArgsAndFlags(&args, &pos_args);
        try cmd.parsePositionalArgs(&pos_args);

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

// HELPER FUNCTIONS

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

// Print a human-friendly error message for flag errors
fn printError(err: anyerror, flag_name: []const u8, value: ?[]const u8) !void {
    const stderr = std.io.getStdErr().writer();

    switch (err) {
        error.MissingValueForFlag => {
            try stderr.print("{s}Error:{s} Missing value for flag '--{s}'\n", .{ styles.BOLD, styles.RESET, flag_name });
        },
        error.InvalidBooleanValue => {
            if (value) |val| {
                try stderr.print("{s}Error:{s} Invalid boolean value '{s}' for flag '--{s}'\n", .{ styles.BOLD, styles.RESET, val, flag_name });
                try stderr.print("Boolean flags accept only 'true' or 'false' values\n", .{});
            } else {
                try stderr.print("{s}Error:{s} Invalid boolean value for flag '--{s}'\n", .{ styles.BOLD, styles.RESET, flag_name });
            }
        },
        error.InvalidIntegerValue => {
            if (value) |val| {
                try stderr.print("{s}Error:{s} Invalid integer value '{s}' for flag '--{s}'\n", .{ styles.BOLD, styles.RESET, val, flag_name });
                try stderr.print("Integer flags require a numeric value\n", .{});
            } else {
                try stderr.print("{s}Error:{s} Invalid integer value for flag '--{s}'\n", .{ styles.BOLD, styles.RESET, flag_name });
            }
        },
        error.UnknownFlag => {
            try stderr.print("{s}Error:{s} Unknown flag: '--{s}'\n", .{ styles.BOLD, styles.RESET, flag_name });
        },
        error.InvalidFlagCombination => {
            try stderr.print("{s}Error:{s} Invalid flag combination involving '--{s}'\n", .{ styles.BOLD, styles.RESET, flag_name });
        },
        else => {
            try stderr.print("{s}Error:{s} {s} with flag '--{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), flag_name });
        },
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

test "popFront shifts list" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();
    try list.append(1);
    try list.append(2);
    try list.append(3);
    const first = try popFront(i32, &list);
    try std.testing.expect(first == 1);
    try std.testing.expect(list.items.len == 2);
    try std.testing.expect(list.items[0] == 2);
    try std.testing.expect(list.items[1] == 3);
}

test "popFront empty returns error Empty" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(i32).init(allocator);
    defer list.deinit();
    const err = popFront(i32, &list) catch |e| e;
    try std.testing.expect(err == error.Empty);
}

test "evaluateValueType Bool and Int and String" {
    var flag_bool = Flag{
        .name = "b",
        .shortcut = null,
        .description = "",
        .type = .Bool,
        .default_value = FlagValue{ .Bool = false },
    };
    const val_true = try flag_bool.evaluateValueType("true");
    try std.testing.expect(val_true.Bool);
    const val_false = try flag_bool.evaluateValueType("false");
    try std.testing.expect(!val_false.Bool);

    var flag_int = Flag{
        .name = "i",
        .shortcut = null,
        .description = "",
        .type = .Int,
        .default_value = FlagValue{ .Int = 0 },
    };
    const val = try flag_int.evaluateValueType("123");
    try std.testing.expect(val.Int == 123);

    var flag_str = Flag{
        .name = "s",
        .shortcut = null,
        .description = "",
        .type = .String,
        .default_value = FlagValue{ .String = "" },
    };
    const sval = try flag_str.evaluateValueType("hello");
    try std.testing.expect(std.mem.eql(u8, sval.String, "hello"));
}

test "safeEvaluate maps errors to InvalidFlagValue" {
    var flag_int = Flag{
        .name = "i",
        .shortcut = null,
        .description = "",
        .type = .Int,
        .default_value = FlagValue{ .Int = 0 },
    };
    const err = flag_int.safeEvaluate("not_int") catch |e| e;
    try std.testing.expect(err == error.InvalidFlagValue);
}

test "addFlag and findFlag and flag_values default" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, CommandOptions{ .name = "test", .description = "" }, dummyExec);

    defer cmd.deinit();
    const flag = Flag{
        .name = "foo",
        .shortcut = "f",
        .description = "",
        .type = .Bool,
        .default_value = FlagValue{ .Bool = true },
    };
    try cmd.addFlag(flag);
    const byName = cmd.findFlag("foo");
    try std.testing.expect(std.mem.eql(u8, byName.?.name, "foo"));
    try std.testing.expect(byName.?.type == .Bool);
    const stored = cmd.flag_values.get("foo").?;
    try std.testing.expect(stored.Bool);
    const byShort = cmd.findFlag("f");
    try std.testing.expect(std.mem.eql(u8, byShort.?.name, "foo"));
}

test "parseFlags with --foo and --bar=5" {
    const allocator = std.testing.allocator;

    var cmd = try Command.init(allocator, CommandOptions{ .name = "test", .description = "" }, dummyExec);

    defer cmd.deinit();
    const flag1 = Flag{ .name = "foo", .shortcut = "f", .description = "", .type = .Bool, .default_value = FlagValue{ .Bool = false } };
    const flag2 = Flag{ .name = "bar", .shortcut = "b", .description = "", .type = .Int, .default_value = FlagValue{ .Int = 0 } };
    try cmd.addFlags(&.{ flag1, flag2 });
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("--foo");
    try args.append("--bar=5");
    try cmd.parseFlags(&args);
    try std.testing.expect(cmd.flag_values.get("foo").?.Bool);
    try std.testing.expect(cmd.flag_values.get("bar").?.Int == 5);
}

test "parseFlags short flags grouping and value" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, CommandOptions{ .name = "test", .description = "" }, dummyExec);

    defer cmd.deinit();
    const f1 = Flag{ .name = "a", .shortcut = "a", .description = "", .type = .Bool, .default_value = FlagValue{ .Bool = false } };
    const f2 = Flag{ .name = "b", .shortcut = "b", .description = "", .type = .Bool, .default_value = FlagValue{ .Bool = false } };
    const f3 = Flag{ .name = "n", .shortcut = "n", .description = "", .type = .Int, .default_value = FlagValue{ .Int = 0 } };
    try cmd.addFlags(&.{ f1, f2, f3 });
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();
    try args.append("-abn");
    try args.append("42");
    try cmd.parseFlags(&args);
    try std.testing.expect(cmd.flag_values.get("a").?.Bool);
    try std.testing.expect(cmd.flag_values.get("b").?.Bool);
    try std.testing.expect(cmd.flag_values.get("n").?.Int == 42);
}

test "findCommand and findLeaf" {
    const allocator = std.testing.allocator;
    var root = try Command.init(allocator, CommandOptions{ .name = "root", .description = "" }, dummyExec);
    defer root.deinit();
    const child = try Command.init(allocator, CommandOptions{ .name = "child", .description = "" }, dummyExec);

    try root.addCommand(child);
    const byName = root.findCommand("child");
    try std.testing.expect(byName.? == child);
    var args2 = std.ArrayList([]const u8).init(allocator);
    defer args2.deinit();
    try args2.append("child");
    const leaf = try root.findLeaf(&args2);
    try std.testing.expect(leaf == child);
}

test "getContextData returns typed data" {
    const allocator = std.testing.allocator;
    var cmd = try Command.init(allocator, CommandOptions{ .name = "cmd", .description = "" }, dummyExec);
    defer cmd.deinit();
    const Data = struct { a: i32 };
    var d = Data{ .a = 7 };
    var ctx = CommandContext{
        .root = cmd,
        .direct_parent = cmd,
        .command = cmd,
        .allocator = allocator,
        .positional_args = &[_][]const u8{},
        .data = &d,
    };
    const dp = ctx.getContextData(Data);
    try std.testing.expect(dp.a == 7);
}

fn dummyExec(_: CommandContext) !void {
    return;
}
