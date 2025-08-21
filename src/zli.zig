const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

const builtin = @import("lib/builtin.zig");
pub const styles = builtin.styles;
const Spinner = @import("lib/spin.zig");
pub const SpinnerStyles = Spinner.SpinnerStyles;

/// FlagType represents the type of a flag, can be a boolean, integer, or string.
pub const FlagType = enum {
    Bool,
    Int,
    String,
};

/// FlagValue represents the value of a flag, can be a boolean, integer, or string.
pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i32,
    String: []const u8,
};

/// Flag represents a flag for a command, example: "--verbose". Can be used such as "--verbose true" or "--verbose=22", or just "--verbose".
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

/// PositionalArg represents a positional argument for a command, example:"cli open file.txt".
pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false,
};

/// CommandContext represents the context of a command execution. Powerful!
pub const CommandContext = struct {
    root: *Command,
    direct_parent: *Command,
    command: *Command,
    allocator: Allocator,
    positional_args: []const []const u8,
    spinner: *Spinner,
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
        return @ptrCast(@alignCast(self.data.?));
    }
};

/// ExecFn is the type of function that is executed when the command is executed.
const ExecFn = *const fn (ctx: CommandContext) anyerror!void;

/// This is needed to fool the compiler that we are not doing dependency loop
/// common error would error: dependency loop detected if this function is not passed to the init function.
const ExecFnToPass = *const fn (ctx: CommandContext) anyerror!void;

/// CommandOptions represents the metadata for a command, such as the name, description, version, and more.
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

/// Represents a single command in the Command Line Interface (CLI),
/// such as "run", "version", or any other user-invoked operation.
/// Each command encapsulates specific functionality or behavior
/// that the CLI can execute.
pub const Command = struct {
    options: CommandOptions,

    flags_by_name: StringHashMap(Flag),
    flags_by_shortcut: StringHashMap(Flag),
    flag_values: StringHashMap(FlagValue),

    positional_args: ArrayList(PositionalArg),

    execFn: ExecFn,

    commands_by_name: StringHashMap(*Command),
    commands_by_shortcut: StringHashMap(*Command),
    command_by_aliases: StringHashMap(*Command),

    parent: ?*Command = null,
    allocator: Allocator,
    writer: *Writer,

    pub fn init(writer: *Writer, allocator: Allocator, options: CommandOptions, execFn: ExecFnToPass) !*Command {
        const cmd = try allocator.create(Command);
        cmd.* = Command{
            .writer = writer,
            .allocator = allocator,
            .options = options,
            .positional_args = ArrayList(PositionalArg).empty,
            .execFn = execFn,
            .flags_by_name = StringHashMap(Flag).init(allocator),
            .flags_by_shortcut = StringHashMap(Flag).init(allocator),
            .flag_values = StringHashMap(FlagValue).init(allocator),
            .commands_by_name = StringHashMap(*Command).init(allocator),
            .commands_by_shortcut = StringHashMap(*Command).init(allocator),
            .command_by_aliases = StringHashMap(*Command).init(allocator),
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
        self.positional_args.deinit(self.allocator);

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

        try self.writer.print("{s}:\n", .{self.options.commands_title});

        var commands = ArrayList(*Command).empty;
        defer commands.deinit(self.allocator);

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            try commands.append(self.allocator, entry.value_ptr.*);
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

        // Map to group commands by their section title.
        var section_map = StringHashMap(ArrayList(*Command)).init(self.allocator);
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
                list.value_ptr.* = ArrayList(*Command).init(self.allocator);
            }
            try list.value_ptr.*.append(cmd);
        }

        var section_keys = ArrayList([]const u8).init(self.allocator);
        defer section_keys.deinit();

        var key_it = section_map.keyIterator();
        while (key_it.next()) |key| {
            try section_keys.append(key.*);
        }

        std.sort.insertion([]const u8, section_keys.items, {}, struct {
            pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                // Sort by command name, not section title
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (section_keys.items) |section_name| {
            // We know the key exists, so we can use .?
            const cmds_list = section_map.get(section_name).?;

            try self.writer.print("{s}{s}{s}:\n", .{ styles.BOLD, section_name, styles.RESET });

            std.sort.insertion(*Command, cmds_list.items, {}, struct {
                pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                    return std.mem.order(u8, a.options.name, b.options.name) == .lt;
                }
            }.lessThan);

            try printAlignedCommands(cmds_list.items);
            try self.writer.print("\n", .{});
        }
    }

    pub fn listFlags(self: *const Command) !void {
        if (self.flags_by_name.count() == 0) {
            return;
        }

        try self.writer.print("Flags:\n", .{});

        // Collect all flags into a list for processing
        var flags = ArrayList(Flag).empty;
        defer flags.deinit(self.allocator);

        var it = self.flags_by_name.iterator();
        while (it.next()) |entry| {
            const flag = entry.value_ptr.*;
            if (!flag.hidden) {
                try flags.append(self.allocator, flag);
            }
        }

        try printAlignedFlags(self.writer, flags.items);
    }

    pub fn listPositionalArgs(self: *const Command) !void {
        if (self.positional_args.items.len == 0) return;

        try self.writer.print("Arguments:\n", .{});

        var max_width: usize = 0;
        for (self.positional_args.items) |arg| {
            const name_len = arg.name.len;
            if (name_len > max_width) max_width = name_len;
        }

        for (self.positional_args.items) |arg| {
            const padding = max_width - arg.name.len;
            try self.writer.print("  {s}", .{arg.name});

            try self.writer.splatByteAll(' ', padding + 4);
            try self.writer.print("{s}", .{arg.description});
            if (arg.required) {
                try self.writer.print(" (required)", .{});
            }
            if (arg.variadic) {
                try self.writer.print(" (variadic)", .{});
            }
            try self.writer.print("\n", .{});
        }

        try self.writer.print("\n", .{});
    }

    pub fn listAliases(self: *Command) !void {
        if (self.options.aliases) |aliases| {
            if (aliases.len == 0) return;
            try self.writer.print("Aliases: ", .{});
            for (aliases, 0..) |alias, i| {
                try self.writer.print("{s}", .{alias});
                if (i < aliases.len - 1) {
                    try self.writer.print(", ", .{});
                }
            }
        }
    }

    pub fn printUsageLine(self: *Command) !void {
        var parents = try self.getParents(self.allocator);
        defer parents.deinit(self.allocator);

        try self.writer.print("Usage: ", .{});

        for (parents.items) |p| {
            try self.writer.print("{s} ", .{p.options.name});
        }

        try self.writer.print("{s} [options]", .{self.options.name});

        for (self.positional_args.items) |arg| {
            if (arg.required) {
                try self.writer.print(" <{s}>", .{arg.name});
            } else {
                try self.writer.print(" [{s}]", .{arg.name});
            }
            if (arg.variadic) {
                try self.writer.print("...", .{});
            }
        }
    }

    pub fn showInfo(self: *const Command) !void {
        try self.writer.print("{s}{s}{s}\n", .{ styles.BOLD, self.options.description, styles.RESET });
        if (self.options.version) |version| try self.writer.print("{s}v{f}{s}\n", .{ styles.DIM, version, styles.RESET });
    }

    pub fn showVersion(self: *const Command) !void {
        if (self.options.version) |version| try self.writer.print("{f}\n", .{version});
    }

    /// Prints traditional help with commands NOT organized by sections
    pub fn printHelp(self: *Command) !void {
        if (!self.options.deprecated) {
            try self.showInfo();
            try self.writer.print("\n", .{});

            if (self.options.help) |help| {
                try self.writer.print("{s}\n\n", .{help});
            }

            var parents = try self.getParents(self.allocator);
            defer parents.deinit(self.allocator);

            // Usage
            if (self.options.usage) |usage| {
                try self.writer.print("Usage: {s}\n", .{usage});
            } else {
                try self.printUsageLine();
            }

            if (self.options.aliases) |aliases| {
                if (aliases.len > 0) {
                    try self.writer.print("\n\n", .{});
                }
            }

            // Aliases
            try self.listAliases();

            // Sub commands
            try self.writer.print("\n", .{});

            if (self.commands_by_name.count() > 0) try self.writer.print("\n", .{});
            try self.listCommands();
            try self.writer.print("\n", .{});

            // Flags
            try self.listFlags();
            if (self.flags_by_name.count() > 0) try self.writer.print("\n", .{});

            // Arguments
            try self.listPositionalArgs();

            const has_subcommands = self.commands_by_name.count() > 0;

            try self.writer.print("Use \"", .{});
            for (parents.items) |p| {
                try self.writer.print("{s} ", .{p.options.name});
            }
            try self.writer.print("{s}", .{self.options.name});

            if (has_subcommands) {
                try self.writer.print(" [command]", .{});
            }
            try self.writer.print(" --help\" for more information.\n", .{});
        }
    }

    /// Prints help with commands organized by sections
    pub fn printStructuredHelp(self: *Command) !void {
        if (!self.options.deprecated) {
            try self.showInfo();
            try self.writer.print("\n", .{});

            if (self.options.help) |help| {
                try self.writer.print("{s}\n\n", .{help});
            }

            const parents = try self.getParents(self.allocator);
            defer parents.deinit();

            // Usage
            if (self.options.usage) |usage| {
                try self.writer.print("Usage: {s}\n", .{usage});
            } else {
                try self.printUsageLine();
            }

            if (self.options.aliases) |aliases| {
                if (aliases.len > 0) {
                    try self.writer.print("\n\n", .{});
                }
            }

            // Aliases
            try self.listAliases();

            // Sub commands
            try self.writer.print("\n", .{});

            if (self.commands_by_name.count() > 0) try self.writer.print("\n", .{});
            try self.listCommandsBySection();
            try self.writer.print("\n", .{});

            // Flags
            try self.listFlags();
            if (self.flags_by_name.count() > 0) try self.writer.print("\n", .{});

            // Arguments
            try self.listPositionalArgs();

            const has_subcommands = self.commands_by_name.count() > 0;

            try self.writer.print("Use \"", .{});
            for (parents.items) |p| {
                try self.writer.print("{s} ", .{p.options.name});
            }
            try self.writer.print("{s}", .{self.options.name});

            if (has_subcommands) {
                try self.writer.print(" [command]", .{});
            }
            try self.writer.print(" --help\" for more information.\n", .{});
        }
    }

    pub fn getParents(self: *Command, allocator: Allocator) !ArrayList(*Command) {
        var list = ArrayList(*Command).empty;

        var cmd = self;
        while (cmd.parent) |p| {
            try list.append(allocator, p);
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
                try self.writer.print("Variadic args should only appear at the end.\n", .{});
                std.process.exit(1);
            }
        }
        try self.positional_args.append(self.allocator, pos_arg);
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
    fn parseArgsAndFlags(self: *Command, args: *ArrayList([]const u8), out_positionals: *ArrayList([]const u8)) !void {
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
                        try self.writer.print("Unknown flag: --{s}\n", .{flag_name});
                        try self.displayCommandError();
                        std.process.exit(1);
                    }
                    const flag_value = flag.?.safeEvaluate(value) catch {
                        try self.writer.print("Invalid value for flag --{s}: '{s}'\n", .{ flag_name, value });
                        try self.writer.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
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
                        try self.writer.print("Unknown flag: --{s}\n", .{flag_name});
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
                            try self.writer.print("Missing value for flag --{s}\n", .{flag_name});
                            try self.displayCommandError();
                            std.process.exit(1);
                        }
                        const value = args.items[1];
                        const flag_value = flag.?.safeEvaluate(value) catch {
                            try self.writer.print("Invalid value for flag --{s}: '{s}'\n", .{ flag_name, value });
                            try self.writer.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
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
                        try self.writer.print("Unknown flag: -{c}\n", .{shortcuts[j]});
                        std.process.exit(1);
                    }
                    if (flag.?.type == .Bool) {
                        try self.flag_values.put(flag.?.name, .{ .Bool = true });
                    } else {
                        if (j < shortcuts.len - 1) {
                            try self.writer.print("Flag -{c} ({s}) must be last in group since it expects a value\n", .{ shortcuts[j], flag.?.name });
                            std.process.exit(1);
                        }
                        if (args.items.len < 2) {
                            try self.writer.print("Missing value for flag -{c} ({s})\n", .{ shortcuts[j], flag.?.name });
                            std.process.exit(1);
                        }
                        const value = args.items[1];
                        const flag_value = flag.?.safeEvaluate(value) catch {
                            try self.writer.print("Invalid value for flag -{c} ({s}): '{s}'\n", .{ shortcuts[j], flag.?.name, value });
                            try self.writer.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
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
                try out_positionals.append(self.allocator, val);
            }
        }
    }

    fn findFlag(self: *Command, name_or_shortcut: []const u8) ?Flag {
        if (self.flags_by_name.get(name_or_shortcut)) |flag| return flag;
        if (self.flags_by_shortcut.get(name_or_shortcut)) |flag| return flag;
        return null;
    }

    fn parsePositionalArgs(self: *Command, args: *ArrayList([]const u8)) !void {
        const expected = self.positional_args.items;

        var required_count: u8 = 0;
        for (expected) |value| {
            if (value.required) required_count += 1;
        }

        if (args.items.len < required_count) {
            try self.writer.print("Missing {d} positional argument(s).\n\nExpected: ", .{required_count});

            var first = true;
            for (expected) |arg| {
                if (arg.required) {
                    if (!first) try self.writer.print(", ", .{});
                    try self.writer.print("{s}", .{arg.name});
                    first = false;
                }
            }

            try self.writer.print("\n", .{});
            try self.displayCommandError();
            return error.MissingArgs;
        }

        if (expected.len > 0) {
            const last_arg = expected[expected.len - 1];
            if (!last_arg.variadic and args.items.len > expected.len) {
                try self.writer.print("Too many positional arguments. Expected at most {}.\n", .{expected.len});
                try self.displayCommandError();
                return error.TooManyArgs;
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
                try self.writer.print("'{s}' v{f} is deprecated\n", .{ self.options.name, version });
            } else {
                try self.writer.print("'{s}' is deprecated\n", .{self.options.name});
            }

            if (self.options.replaced_by) |new_cmd_name| {
                try self.writer.print("\nUse '{s}' instead.\n", .{new_cmd_name});
            }

            return error.CommandDeprecated;
        }
    }

    // Traverse the commands to find the last one in the user input
    fn findLeaf(self: *Command, args: *ArrayList([]const u8)) !*Command {
        var current = self;

        while (args.items.len > 0 and !std.mem.startsWith(u8, args.items[0], "-")) {
            const name = args.items[0];
            const maybe_next = current.findCommand(name);

            if (maybe_next == null) {
                // Check if the current command expects positional arguments
                const expects_pos_args = current.positional_args.items.len > 0;
                if (!expects_pos_args) {
                    try current.writer.print("Unknown command: '{s}'\n", .{name});
                    try current.displayCommandError();
                    return error.UnknownCommand;
                }
                break;
            }

            _ = try popFront([]const u8, args);
            current = maybe_next.?;
        }

        return current;
    }

    // Need to make find command, parse flags and parse pos_args execution in parallel
    /// Executes the command by handling all positional args, subcommands, flags etc...
    ///
    /// Caller needs to flush the writer after calling this fn.
    /// ```zig
    ///  const root = try cli.build(&writer, allocator);
    ///  defer root.deinit();
    ///  try root.execute(.{});
    ///  try writer.flush();
    /// ```
    pub fn execute(self: *Command, context: struct { data: ?*anyopaque = null }) !void {
        errdefer self.writer.flush() catch {};
        var input = try std.process.argsWithAllocator(self.allocator);
        defer input.deinit();
        _ = input.skip(); // skip program name

        var args = ArrayList([]const u8).empty;
        defer args.deinit(self.allocator);
        while (input.next()) |arg| {
            try args.append(self.allocator, arg);
        }

        var pos_args = ArrayList([]const u8).empty;
        defer pos_args.deinit(self.allocator);

        var cmd = self.findLeaf(&args) catch |err| {
            if (err == error.UnknownCommand) {
                std.process.exit(1);
            }
            return err;
        };

        cmd.checkDeprecated() catch std.process.exit(1);

        try cmd.parseArgsAndFlags(&args, &pos_args);
        cmd.parsePositionalArgs(&pos_args) catch std.process.exit(1);

        const spinner = try Spinner.init(cmd.writer, cmd.allocator, .{});
        defer spinner.deinit();

        const ctx = CommandContext{
            .root = self,
            .direct_parent = cmd.parent orelse self,
            .command = cmd,
            .allocator = cmd.allocator,
            .positional_args = pos_args.items,
            .spinner = spinner,
            .data = context.data,
        };

        try cmd.execFn(ctx);
    }

    fn displayCommandError(self: *Command) !void {
        var parents = try self.getParents(self.allocator);
        defer parents.deinit(self.allocator);

        try self.writer.print("\nRun: '", .{});
        for (parents.items) |p| {
            try self.writer.print("{s} ", .{p.options.name});
        }
        try self.writer.print("{s} --help'\n", .{self.options.name});
    }
};

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
        try cmd.writer.print("   {s}", .{cmd.options.name});

        // Print shortcut directly if exists
        if (cmd.options.shortcut) |s| {
            try cmd.writer.print(" ({s})", .{s});
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

        try cmd.writer.splatByteAll(' ', padding + 4);

        try cmd.writer.print("{s}\n", .{desc});
    }
}

/// Prints a list of flags aligned to the maximum width of the flags.
fn printAlignedFlags(writer: *Writer, flags: []const Flag) !void {
    if (flags.len == 0) return;

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
            try writer.print(" -{s}, ", .{shortcut});
            current_width += 1 + shortcut.len + 2;
        } else {
            try writer.print("     ", .{});
            current_width += 5;
        }

        // Print flag name
        try writer.print("--{s}", .{flag.name});
        current_width += 2 + flag.name.len;

        // Calculate and add padding
        const padding = max_width - current_width;
        try writer.splatByteAll(' ', padding + 4);

        // Print description and type
        try writer.print("{s} [{s}]", .{
            flag.description,
            @tagName(flag.type),
        });

        // Print default value
        switch (flag.type) {
            .Bool => try writer.print(" (default: {s})", .{if (flag.default_value.Bool) "true" else "false"}),
            .Int => try writer.print(" (default: {})", .{flag.default_value.Int}),
            .String => if (flag.default_value.String.len > 0) {
                try writer.print(" (default: \"{s}\")", .{flag.default_value.String});
            },
        }
        try writer.print("\n", .{});
    }
}

/// Pop the first element from the list and shift the rest
// A more efficient popFront
fn popFront(comptime T: type, list: *ArrayList(T)) !T {
    if (list.items.len == 0) return error.Empty;
    return list.orderedRemove(0);
}
