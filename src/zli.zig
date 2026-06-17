//! Zli - Build modular, ergonomic, and high-performance CLIs with ease.
//! Batteries included.
//!
//! For more info, visit: https://github.com/xcaeser/zli

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;

const builtin = @import("lib/builtin.zig");
pub const styles = builtin.styles;
pub const Spinner = @import("lib/spinner.zig");
pub const SpinnerStyles = Spinner.SpinnerStyles;

/// Errors returned by command parsing, validation, and execution helpers.
pub const CommandErrors = error{
    InvalidBooleanValue,
    InvalidFlagValue,
    InvalidFlagNegation,
    InvalidFlagShortcut,
    InvalidPositionalArgOrder,
    MissingArgs,
    MissingFlagValue,
    TooManyArgs,
    UnknownCommand,
    UnknownFlag,
    CommandDeprecated,
};

/// Errors returned while rendering command output.
pub const CommandPrintErrors = Io.Writer.Error || Allocator.Error;

/// Errors returned while building a command tree.
pub const CommandSetupErrors = CommandErrors || Io.Writer.Error || Allocator.Error;

/// Errors returned while parsing and validating command input.
pub const CommandParseErrors = CommandErrors || Io.Writer.Error || Allocator.Error;

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

/// Flag represents a flag for a command, example: "--verbose".
///
/// Can be used such as `--verbose true` or `--verbose=22`, or just `--verbose`.
pub const Flag = struct {
    name: []const u8,
    shortcut: ?[]const u8 = null,
    description: []const u8,
    type: FlagType,
    default_value: FlagValue,
    hidden: bool = false,
    persistent: bool = false,

    pub fn evaluateValue(self: *const Flag, value: []const u8) CommandErrors!FlagValue {
        return switch (self.type) {
            .Bool => {
                if (std.mem.eql(u8, value, "true")) return FlagValue{ .Bool = true };
                if (std.mem.eql(u8, value, "false")) return FlagValue{ .Bool = false };
                return CommandErrors.InvalidBooleanValue;
            },
            .Int => FlagValue{ .Int = std.fmt.parseInt(i32, value, 10) catch return CommandErrors.InvalidFlagValue },
            .String => FlagValue{ .String = value },
        };
    }
};

/// PositionalArg represents a positional argument for a command
///
/// example: `cli open file.txt`.
pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false,
};

const DataContext = struct {
    data: ?*anyopaque = null,
};

/// CommandContext represents the context of a command execution.
pub const CommandContext = struct {
    root: *Command,
    direct_parent: *Command,
    command: *Command,
    allocator: Allocator,
    io: Io,
    writer: *Io.Writer,
    reader: *Io.Reader,
    positional_args: []const []const u8,
    spinner: *Spinner,
    data: ?*anyopaque = null,

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

pub const InitOptions = struct {
    io: Io,
    writer: *Io.Writer,
    reader: *Io.Reader,
    allocator: Allocator,
};

/// Represents a single command in the Command Line Interface (CLI),
/// such as "run", "version", or any other user-invoked operation.
/// Each command encapsulates specific functionality or behavior
/// that the CLI can execute.
pub const Command = struct {
    cmd_options: CommandOptions,
    init_options: InitOptions,

    flags_by_name: StringHashMap(Flag),
    flags_by_shortcut: StringHashMap(Flag),
    flag_values: StringHashMap(FlagValue),

    positional_args: ArrayList(PositionalArg),

    execFn: ExecFn,

    commands_by_name: StringHashMap(*Command),
    commands_by_shortcut: StringHashMap(*Command),
    command_by_aliases: StringHashMap(*Command),

    parent: ?*Command = null,

    /// Automatically calculated, do not change.
    _max_len: usize = 0,

    /// Set to 5, you can change this
    _general_padding: usize = 5,

    pub fn init(init_opts: InitOptions, cmd_options: CommandOptions, execFn: ExecFn) Allocator.Error!*Command {
        const cmd = try init_opts.allocator.create(Command);
        errdefer init_opts.allocator.destroy(cmd);
        cmd.* = Command{
            .init_options = init_opts,
            .cmd_options = cmd_options,
            .positional_args = ArrayList(PositionalArg).empty,
            .execFn = execFn,
            .flags_by_name = StringHashMap(Flag).init(init_opts.allocator),
            .flags_by_shortcut = StringHashMap(Flag).init(init_opts.allocator),
            .flag_values = StringHashMap(FlagValue).init(init_opts.allocator),
            .commands_by_name = StringHashMap(*Command).init(init_opts.allocator),
            .commands_by_shortcut = StringHashMap(*Command).init(init_opts.allocator),
            .command_by_aliases = StringHashMap(*Command).init(init_opts.allocator),
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
        self.positional_args.deinit(self.init_options.allocator);

        self.flags_by_name.deinit();
        self.flags_by_shortcut.deinit();
        self.flag_values.deinit();

        var it = self.commands_by_name.valueIterator();
        while (it.next()) |cmd| {
            cmd.*.deinit();
        }
        self.commands_by_name.deinit();
        self.commands_by_shortcut.deinit();
        self.command_by_aliases.deinit();
        self.init_options.allocator.destroy(self);
    }

    pub fn printCommands(self: *const Command) CommandPrintErrors!void {
        if (self.commands_by_name.count() == 0) {
            return;
        }

        try self.init_options.writer.print("{s}:\n", .{self.cmd_options.commands_title});

        var commands = ArrayList(*Command).empty;
        defer commands.deinit(self.init_options.allocator);

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            try commands.append(self.init_options.allocator, entry.value_ptr.*);
        }

        std.sort.insertion(*Command, commands.items, {}, struct {
            pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                return std.mem.order(u8, a.cmd_options.name, b.cmd_options.name) == .lt;
            }
        }.lessThan);

        try printAlignedCommands(commands.items, self._general_padding, self._max_len);
    }

    pub fn printCommandsBySection(self: *const Command) CommandPrintErrors!void {
        if (self.commands_by_name.count() == 0) {
            return;
        }

        // Map to group commands by their section title.
        var section_map = StringHashMap(ArrayList(*Command)).init(self.init_options.allocator);
        defer {
            var it = section_map.valueIterator();
            while (it.next()) |list| {
                list.deinit(self.init_options.allocator);
            }
            section_map.deinit();
        }

        var it = self.commands_by_name.valueIterator();
        while (it.next()) |cmd| {
            const section = cmd.*.cmd_options.section_title;

            const list = try section_map.getOrPut(section);
            if (!list.found_existing) {
                list.value_ptr.* = ArrayList(*Command).empty;
            }
            try list.value_ptr.*.append(self.init_options.allocator, cmd.*);
        }

        var section_keys = ArrayList([]const u8).empty;
        defer section_keys.deinit(self.init_options.allocator);

        var key_it = section_map.keyIterator();
        while (key_it.next()) |key| {
            try section_keys.append(self.init_options.allocator, key.*);
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

            try self.init_options.writer.print("{s}{s}{s}:\n", .{ styles.BOLD, section_name, styles.RESET });

            std.sort.insertion(*Command, cmds_list.items, {}, struct {
                pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                    return std.mem.order(u8, a.cmd_options.name, b.cmd_options.name) == .lt;
                }
            }.lessThan);

            try printAlignedCommands(cmds_list.items, self._general_padding, self._max_len);
            try self.init_options.writer.print("\n", .{});
        }
    }

    pub fn printFlags(self: *const Command) Io.Writer.Error!void {
        if (self.flags_by_name.count() == 0) {
            return;
        }

        try self.init_options.writer.print("Flags:\n", .{});

        var it = self.flags_by_name.valueIterator();

        while (it.next()) |flag| {
            if (flag.shortcut) |shortcut| {
                try self.init_options.writer.print("   {s}-{s}, ", .{ styles.BOLD, shortcut });
            } else {
                try self.init_options.writer.print("   {s}", .{styles.BOLD});
            }

            try self.init_options.writer.print("--{s}{s}", .{ flag.name, styles.RESET });

            const flag_name_len = flag.name.len + 2; // "--" + name
            const flag_shortcut_len = if (flag.shortcut) |s| s.len + 3 else 0; // account for 3 "-" + shortcut + ", "
            const flag_total_len = flag_name_len + flag_shortcut_len;

            try self.init_options.writer.splatByteAll(' ', self._general_padding + self._max_len - flag_total_len);

            try self.init_options.writer.print("{s} [{t}]", .{
                flag.description,
                flag.type,
            });

            switch (flag.type) {
                .Bool => try self.init_options.writer.print(" (default: {s})", .{if (flag.default_value.Bool) "true" else "false"}),
                .Int => try self.init_options.writer.print(" (default: {})", .{flag.default_value.Int}),
                .String => if (flag.default_value.String.len > 0) {
                    try self.init_options.writer.print(" (default: \"{s}\")", .{flag.default_value.String});
                },
            }
            try self.init_options.writer.print("\n", .{});
        }
    }

    pub fn printPositionalArgs(self: *const Command) Io.Writer.Error!void {
        if (self.positional_args.items.len == 0) return;

        try self.init_options.writer.print("Arguments:\n", .{});

        for (self.positional_args.items) |arg| {
            try self.init_options.writer.print("   {s}{s}{s}", .{ styles.BOLD, arg.name, styles.RESET });

            const width = self._general_padding + self._max_len - arg.name.len;
            try self.init_options.writer.splatByteAll(' ', width);
            try self.init_options.writer.print("{s}", .{arg.description});
            if (arg.required) {
                try self.init_options.writer.print(" (required)", .{});
            }
            if (arg.variadic) {
                try self.init_options.writer.print(" (variadic)", .{});
            }
            try self.init_options.writer.print("\n", .{});
        }

        try self.init_options.writer.print("\n", .{});
    }

    pub fn printAliases(self: *Command) Io.Writer.Error!void {
        if (self.cmd_options.aliases) |aliases| {
            if (aliases.len == 0) return;
            try self.init_options.writer.print("Aliases: ", .{});
            for (aliases, 0..) |alias, i| {
                try self.init_options.writer.print("{s}", .{alias});
                if (i < aliases.len - 1) {
                    try self.init_options.writer.print(", ", .{});
                }
            }
        }
    }

    pub fn printUsageLine(self: *Command) CommandPrintErrors!void {
        var parents = try self.getParents(self.init_options.allocator);
        defer parents.deinit(self.init_options.allocator);

        try self.init_options.writer.print("Usage: ", .{});

        for (parents.items) |p| {
            try self.init_options.writer.print("{s} ", .{p.cmd_options.name});
        }

        try self.init_options.writer.print("{s} [options]", .{self.cmd_options.name});

        for (self.positional_args.items) |arg| {
            if (arg.required) {
                try self.init_options.writer.print(" <{s}>", .{arg.name});
            } else {
                try self.init_options.writer.print(" [{s}]", .{arg.name});
            }
            if (arg.variadic) {
                try self.init_options.writer.print("...", .{});
            }
        }
    }

    pub fn printInfo(self: *const Command) Io.Writer.Error!void {
        try self.init_options.writer.print("{s}{s}{s}\n", .{ styles.BOLD, self.cmd_options.description, styles.RESET });
        if (self.cmd_options.version) |version| try self.init_options.writer.print("{s}v{f}{s}\n", .{ styles.DIM, version, styles.RESET });
    }

    pub fn printVersion(self: *const Command) Io.Writer.Error!void {
        if (self.cmd_options.version) |version| {
            try self.init_options.writer.print("{f}\n", .{version});
            try self.init_options.writer.flush();
        }
    }

    /// Prints traditional help with commands NOT organized by sections
    pub fn printHelp(self: *Command) CommandPrintErrors!void {
        if (!self.cmd_options.deprecated) {
            self.calculateMaxLenForWriter();

            try self.printInfo();
            try self.init_options.writer.print("\n", .{});

            if (self.cmd_options.help) |help| {
                try self.init_options.writer.print("{s}\n\n", .{help});
            }

            var parents = try self.getParents(self.init_options.allocator);
            defer parents.deinit(self.init_options.allocator);

            // Usage
            if (self.cmd_options.usage) |usage| {
                try self.init_options.writer.print("Usage: {s}\n", .{usage});
            } else {
                try self.printUsageLine();
            }

            if (self.cmd_options.aliases) |aliases| {
                if (aliases.len > 0) {
                    try self.init_options.writer.print("\n\n", .{});
                }
            }

            // Aliases
            try self.printAliases();

            // Sub commands
            try self.init_options.writer.print("\n", .{});

            if (self.commands_by_name.count() > 0) try self.init_options.writer.print("\n", .{});
            try self.printCommands();
            try self.init_options.writer.print("\n", .{});

            // Flags
            try self.printFlags();
            if (self.flags_by_name.count() > 0) try self.init_options.writer.print("\n", .{});

            // Arguments
            try self.printPositionalArgs();
        }
    }

    /// Prints help with commands organized by sections
    pub fn printStructuredHelp(self: *Command) CommandPrintErrors!void {
        if (!self.cmd_options.deprecated) {
            self.calculateMaxLenForWriter();

            try self.printInfo();
            try self.init_options.writer.print("\n", .{});

            if (self.cmd_options.help) |help| {
                try self.init_options.writer.print("{s}\n\n", .{help});
            }

            var parents = try self.getParents(self.init_options.allocator);
            defer parents.deinit(self.init_options.allocator);

            // Usage
            if (self.cmd_options.usage) |usage| {
                try self.init_options.writer.print("Usage: {s}\n", .{usage});
            } else {
                try self.printUsageLine();
            }

            if (self.cmd_options.aliases) |aliases| {
                if (aliases.len > 0) {
                    try self.init_options.writer.print("\n\n", .{});
                }
            }

            // Aliases
            try self.printAliases();

            // Sub commands
            try self.init_options.writer.print("\n", .{});

            if (self.commands_by_name.count() > 0) try self.init_options.writer.print("\n", .{});
            try self.printCommandsBySection();
            try self.init_options.writer.print("\n", .{});

            // Flags
            try self.printFlags();
            if (self.flags_by_name.count() > 0) try self.init_options.writer.print("\n", .{});

            // Arguments
            try self.printPositionalArgs();

            const has_subcommands = self.commands_by_name.count() > 0;

            try self.init_options.writer.print("Use \"", .{});
            for (parents.items) |p| {
                try self.init_options.writer.print("{s} ", .{p.cmd_options.name});
            }
            try self.init_options.writer.print("{s}", .{self.cmd_options.name});

            if (has_subcommands) {
                try self.init_options.writer.print(" [command]", .{});
            }
            try self.init_options.writer.print(" --help\" for more information.\n", .{});
        }
    }

    pub fn getParents(self: *Command, allocator: Allocator) Allocator.Error!ArrayList(*Command) {
        var list = ArrayList(*Command).empty;

        var cmd = self;
        while (cmd.parent) |p| {
            try list.append(allocator, p);
            cmd = p;
        }

        std.mem.reverse(*Command, list.items);
        return list;
    }

    pub fn addCommand(self: *Command, command: *Command) Allocator.Error!void {
        command.parent = self;

        // add persistent flags
        if (self.flags_by_name.count() > 0) {
            var flag_it = self.flags_by_name.valueIterator();
            while (flag_it.next()) |f| {
                if (f.persistent) {
                    try command.addFlag(f.*);
                }
            }
        }

        try self.commands_by_name.put(command.cmd_options.name, command);
        if (command.cmd_options.aliases) |aliases| {
            for (aliases) |alias| {
                try self.command_by_aliases.put(alias, command);
            }
        }
        if (command.cmd_options.shortcut) |shortcut| try self.commands_by_shortcut.put(shortcut, command);
    }

    pub fn addCommands(self: *Command, commands: []const *Command) Allocator.Error!void {
        for (commands) |cmd| try self.addCommand(cmd);
    }

    pub fn addPositionalArg(self: *Command, pos_arg: PositionalArg) CommandSetupErrors!void {
        if (self.positional_args.items.len > 0) {
            const last_arg = self.positional_args.items[self.positional_args.items.len - 1];
            if (last_arg.variadic) {
                try self.init_options.writer.print("Variadic args should only appear at the end.\n", .{});
                try self.init_options.writer.flush();
                return CommandErrors.InvalidPositionalArgOrder;
            }
        }
        try self.positional_args.append(self.init_options.allocator, pos_arg);
    }

    pub fn addFlag(self: *Command, flag: Flag) Allocator.Error!void {
        try self.flags_by_name.put(flag.name, flag);

        // add persistent flags
        if (flag.persistent and self.commands_by_name.count() > 0) {
            var cmd_it = self.commands_by_name.valueIterator();
            while (cmd_it.next()) |c| {
                try c.*.addFlag(flag);
            }
        }
        if (flag.shortcut) |shortcut| if (shortcut.len == 1) try self.flags_by_shortcut.put(shortcut, flag) else @panic("Flag shortcut must be 1 char");

        try self.flag_values.put(flag.name, flag.default_value);
    }

    pub fn addFlags(self: *Command, flags: []const Flag) Allocator.Error!void {
        for (flags) |flag| {
            try self.addFlag(flag);
        }
    }

    fn findFlag(self: *Command, name_or_shortcut: []const u8) ?Flag {
        if (self.flags_by_name.get(name_or_shortcut)) |flag| return flag;
        if (self.flags_by_shortcut.get(name_or_shortcut)) |flag| return flag;
        return null;
    }

    fn parsePositionalArgs(self: *Command, args: []const []const u8) CommandParseErrors!void {
        const expected = self.positional_args.items;

        if (expected.len == 0) {
            if (args.len > 0) {
                try self.init_options.writer.print(
                    "Too many positional arguments. Expected 0, got {}.\n",
                    .{args.len},
                );
                try self.displayCommandError();
                return CommandErrors.TooManyArgs;
            }

            return;
        }

        var required_count: usize = 0;
        for (expected) |value| {
            if (value.required) required_count += 1;
        }

        if (args.len < required_count) {
            const missing_count = required_count - args.len;

            try self.init_options.writer.print(
                "Missing {} positional argument(s).\n\nExpected: ",
                .{missing_count},
            );

            var first = true;
            for (expected) |arg| {
                if (arg.required) {
                    if (!first) try self.init_options.writer.print(", ", .{});
                    try self.init_options.writer.print("{s}", .{arg.name});
                    first = false;
                }
            }

            try self.init_options.writer.print("\n", .{});
            try self.displayCommandError();
            return CommandErrors.MissingArgs;
        }

        const last_arg = expected[expected.len - 1];

        if (!last_arg.variadic and args.len > expected.len) {
            try self.init_options.writer.print(
                "Too many positional arguments. Expected at most {}, got {}.\n",
                .{ expected.len, args.len },
            );
            try self.displayCommandError();
            return CommandErrors.TooManyArgs;
        }
    }

    pub fn findCommand(self: *const Command, name_or_shortcut: []const u8) ?*Command {
        if (self.commands_by_name.get(name_or_shortcut)) |cmd| return cmd;
        if (self.command_by_aliases.get(name_or_shortcut)) |cmd| return cmd;
        if (self.commands_by_shortcut.get(name_or_shortcut)) |cmd| return cmd;
        return null;
    }

    fn checkDeprecated(self: *const Command) CommandParseErrors!void {
        if (self.cmd_options.deprecated) {
            if (self.cmd_options.version) |version| {
                try self.init_options.writer.print("'{s}' v{f} is deprecated\n", .{ self.cmd_options.name, version });
            } else {
                try self.init_options.writer.print("'{s}' is deprecated\n", .{self.cmd_options.name});
            }

            if (self.cmd_options.replaced_by) |new_cmd_name| {
                try self.init_options.writer.print("\nUse '{s}' instead.\n", .{new_cmd_name});
            }

            return CommandErrors.CommandDeprecated;
        }
    }

    /// Executes the command by handling all positional args, subcommands, flags etc...
    ///
    /// Caller needs to flush the writer after calling this fn. Use `runAndExit`
    /// in CLI entrypoints that should terminate the process with an exit code.
    /// ```zig
    ///  const root = try cli.build(&writer, allocator);
    ///  defer root.deinit();
    ///  try root.execute(.{});
    ///  try writer.flush();
    /// ```
    pub fn execute(self: *Command, argsIterator: *std.process.Args.Iterator, context: DataContext) anyerror!void {
        const parsedOutput = try parseArgs(self, argsIterator);
        defer parsedOutput.deinit(self.init_options.allocator);

        const cmd = parsedOutput.command;
        if (!parsedOutput.should_execute) return;

        var spinner = Spinner.init(cmd.init_options.io, cmd.init_options.writer, cmd.init_options.reader, cmd.init_options.allocator, .{});
        defer spinner.deinit();

        const ctx = CommandContext{
            .root = self,
            .direct_parent = cmd.parent orelse self,
            .command = cmd,
            .allocator = cmd.init_options.allocator,
            .io = cmd.init_options.io,
            .writer = cmd.init_options.writer,
            .reader = cmd.init_options.reader,
            .positional_args = parsedOutput.remaining_args,
            .spinner = &spinner,
            .data = context.data,
        };

        try cmd.execFn(ctx);
    }

    /// Runs the command as a full CLI application and exits the process.
    ///
    /// This is the convenient entrypoint for binaries. Use `execute` when you
    /// need library-friendly behavior for tests, embedding, or custom error
    /// handling.
    pub fn runAndExit(self: *Command, argsIterator: *std.process.Args.Iterator, context: DataContext) noreturn {
        self.execute(argsIterator, context) catch {
            self.init_options.writer.flush() catch {};
            std.process.exit(1);
        };

        self.init_options.writer.flush() catch {};
        std.process.exit(0);
    }

    fn displayCommandError(self: *Command) CommandPrintErrors!void {
        var parents = try self.getParents(self.init_options.allocator);
        defer parents.deinit(self.init_options.allocator);

        try self.init_options.writer.print("\nRun: '", .{});
        for (parents.items) |p| {
            try self.init_options.writer.print("{s} ", .{p.cmd_options.name});
        }
        try self.init_options.writer.print("{s} --help'\n", .{self.cmd_options.name});
    }

    fn calculateMaxLenForWriter(self: *Command) void {
        var commands_it = self.commands_by_name.valueIterator();
        var flags_it = self.flags_by_name.valueIterator();
        const args = self.positional_args.items;

        while (commands_it.next()) |cmd| {
            const cmd_name_len = cmd.*.cmd_options.name.len;
            const cmd_shortcut_len = if (cmd.*.cmd_options.shortcut) |s| s.len + 3 else 0; // account for 3 = " ()"
            const cmd_total_len = cmd_name_len + cmd_shortcut_len;
            self._max_len = @max(self._max_len, cmd_total_len);
        }

        while (flags_it.next()) |flag| {
            const flag_name_len = flag.*.name.len + 2; // "--" + name
            const flag_shortcut_len = if (flag.*.shortcut) |s| s.len + 3 else 0; // account for 3 "-" + shortcut + ", "
            const flag_total_len = flag_name_len + flag_shortcut_len;

            self._max_len = @max(self._max_len, flag_total_len);
        }
        for (args) |arg| {
            const arg_len = arg.name.len;

            self._max_len = @max(self._max_len, arg_len);
        }
    }
};

// HELPER FUNCTIONS

/// Prints a list of commands aligned to the maximum width of the commands.
fn printAlignedCommands(commands: []*Command, padding: usize, max_len: usize) Io.Writer.Error!void {
    for (commands) |cmd| {
        const desc = cmd.cmd_options.short_description orelse cmd.cmd_options.description;

        try cmd.init_options.writer.print("  {s}{s}{s}", .{ styles.BOLD, cmd.cmd_options.name, styles.RESET });

        if (cmd.cmd_options.shortcut) |s| {
            try cmd.init_options.writer.print(" ({s})", .{s});
        }

        const cmd_name_len = cmd.cmd_options.name.len;
        const cmd_shortcut_len = if (cmd.cmd_options.shortcut) |s| s.len + 3 else 0; // account for 3 = " ()"
        const cmd_total_len = cmd_name_len + cmd_shortcut_len;

        const width = padding + max_len - cmd_total_len;
        try cmd.init_options.writer.splatByteAll(' ', width);

        try cmd.init_options.writer.print("{s}\n", .{desc});
    }
}

const PType = enum {
    WORD, // Command or Pos Arg
    LONG_FLAG_WITH_VALUE,
    LONG_FLAG,
    GROUP_FLAG,
    NEGATED_FLAG,
};

const ParserOutput = struct {
    program_name: []const u8,
    command: *Command,
    remaining_args: []const []const u8,
    should_execute: bool = true,

    pub fn deinit(self: ParserOutput, allocator: Allocator) void {
        if (self.remaining_args.len > 0) {
            allocator.free(self.remaining_args);
        }
    }
};

fn parseArgs(self: *Command, argsIterator: *std.process.Args.Iterator) CommandParseErrors!ParserOutput { // needs to give back a cmd context
    var current_cmd = self;
    const allocator = current_cmd.init_options.allocator;

    const prog_name = argsIterator.next() orelse unreachable; // always the program name as first arg

    var remaining_args: []const []const u8 = &.{};

    var is_flag: bool = false;

    outer: while (argsIterator.next()) |arg| {
        try current_cmd.init_options.writer.flush();
        const reverse_idx = argsIterator.inner.remaining.len;

        const arg_type = assessArgType(arg);

        switch (arg_type) {
            .WORD => {
                // Any word related to a flag is not treated here as the iterator is advanced automatically when is_flag=true
                if (!is_flag) {
                    if (current_cmd.commands_by_name.count() == 0) {
                        if (current_cmd.positional_args.items.len == 0) {
                            try current_cmd.init_options.writer.print("Unknown command: '{s}'\n", .{arg});
                            try current_cmd.displayCommandError();
                            return CommandErrors.UnknownCommand;
                        }
                    } else if (current_cmd.findCommand(arg)) |found_cmd| {
                        found_cmd.checkDeprecated() catch |err| {
                            try self.init_options.writer.flush();
                            return err;
                        };
                        current_cmd = found_cmd;
                        continue :outer;
                    }
                    is_flag = true;
                }

                if (current_cmd.positional_args.items.len > 0) {
                    const rest = argsIterator.inner.remaining;

                    var converted = try allocator.alloc([]const u8, rest.len + 1);
                    errdefer allocator.free(converted);

                    converted[0] = arg;

                    for (rest, 0..) |item, i| {
                        converted[i + 1] = std.mem.span(item);
                    }

                    remaining_args = converted;
                }

                break;
            },
            .LONG_FLAG_WITH_VALUE => {
                is_flag = true;

                const idx = std.mem.find(u8, arg, "=") orelse unreachable;
                const flag_name = arg[2..idx];
                const value = arg[idx + 1 ..];

                if (current_cmd.findFlag(flag_name)) |flag| {
                    const flag_value = flag.evaluateValue(value) catch {
                        try current_cmd.init_options.writer.print(
                            \\Invalid value for flag --{s}: '{s}'
                            \\Expected a value of type: {t}
                        , .{ flag_name, value, flag.type });
                        try current_cmd.displayCommandError();
                        try current_cmd.init_options.writer.flush();
                        return CommandErrors.InvalidFlagValue;
                    };
                    try current_cmd.flag_values.put(flag_name, flag_value);

                    continue :outer;
                } else {
                    try current_cmd.init_options.writer.print("Unknown flag: --{s}\n", .{flag_name});
                    try current_cmd.displayCommandError();
                    try current_cmd.init_options.writer.flush();
                    return CommandErrors.UnknownFlag;
                }
            },
            .LONG_FLAG => {
                is_flag = true;

                const flag_name = arg[2..];
                const any_remaining_args = reverse_idx > 0;

                if (current_cmd.findFlag(flag_name)) |flag| {
                    if (flag.type == .Bool) {
                        try current_cmd.flag_values.put(flag_name, .{ .Bool = true });
                        continue :outer;
                    }

                    if (!any_remaining_args) {
                        try current_cmd.init_options.writer.print("Missing value for flag --{s} of type: {t}\n", .{ flag_name, flag.type });
                        try current_cmd.displayCommandError();
                        try current_cmd.init_options.writer.flush();
                        return CommandErrors.MissingFlagValue;
                    }

                    const next_arg = argsIterator.next() orelse "";

                    const flag_value = flag.evaluateValue(next_arg) catch {
                        try current_cmd.init_options.writer.print(
                            \\Invalid value for flag --{s}: '{s}'
                            \\Expected a value of type: {t}
                        , .{ flag_name, next_arg, flag.type });
                        try current_cmd.displayCommandError();
                        try current_cmd.init_options.writer.flush();
                        return CommandErrors.InvalidFlagValue;
                    };
                    try current_cmd.flag_values.put(flag_name, flag_value);
                    continue :outer;
                } else {
                    try current_cmd.init_options.writer.print("Unknown flag: --{s}\n", .{flag_name});
                    try current_cmd.displayCommandError();
                    try current_cmd.init_options.writer.flush();
                    return CommandErrors.UnknownFlag;
                }
            },
            .GROUP_FLAG => {
                is_flag = true;

                const shortcuts = arg[1..];

                var i: usize = 0;
                inner: while (i < shortcuts.len) : (i += 1) {
                    const short = shortcuts[i .. i + 1];
                    if (current_cmd.findFlag(short)) |flag| {
                        if (flag.type == .Bool) {
                            try current_cmd.flag_values.put(flag.name, .{ .Bool = true });
                            continue :inner;
                        }

                        if (i < shortcuts.len - 1) {
                            try current_cmd.init_options.writer.print("Flag -{c} ({s}) must be last in group since it expects a value of type: {t}\n", .{ shortcuts[i], flag.name, flag.type });
                            try current_cmd.init_options.writer.flush();
                            return CommandErrors.InvalidFlagShortcut;
                        }

                        const any_remaining_args = reverse_idx > 0;
                        if (!any_remaining_args) {
                            try current_cmd.init_options.writer.print("Missing value for flag -{c} ({s}) of type: {t}\n", .{ shortcuts[i], flag.name, flag.type });
                            try current_cmd.displayCommandError();
                            try current_cmd.init_options.writer.flush();
                            return CommandErrors.MissingFlagValue;
                        }

                        const next_arg = argsIterator.next() orelse "";

                        const flag_value = flag.evaluateValue(next_arg) catch {
                            try current_cmd.init_options.writer.print(
                                \\Invalid value for flag --{s}: '{s}'
                                \\Expected a value of type: {t}
                            , .{ flag.name, next_arg, flag.type });
                            try current_cmd.displayCommandError();
                            try current_cmd.init_options.writer.flush();
                            return CommandErrors.InvalidFlagValue;
                        };

                        try current_cmd.flag_values.put(flag.name, flag_value);
                        continue :outer;
                    } else {
                        try current_cmd.init_options.writer.print("Unknown flag shortcut: -{s}\n", .{short});
                        try current_cmd.displayCommandError();
                        try current_cmd.init_options.writer.flush();
                        return CommandErrors.UnknownFlag;
                    }
                }
            },
            .NEGATED_FLAG => {
                is_flag = true;
                const no_len = "--no-".len;
                const flag_name = arg[no_len..];
                if (current_cmd.findFlag(flag_name)) |flag| {
                    if (flag.type == .Bool) {
                        try current_cmd.flag_values.put(flag.name, .{ .Bool = false });
                        continue :outer;
                    }
                    try current_cmd.init_options.writer.print("Flag --{s} does not accept negation as it expects type: {t}\n", .{ flag.name, flag.type });
                    try current_cmd.init_options.writer.flush();
                    return CommandErrors.InvalidFlagNegation;
                }
                try current_cmd.init_options.writer.print("Unknown flag: --no-{s}\n", .{flag_name});
                try current_cmd.displayCommandError();
                try current_cmd.init_options.writer.flush();
                return CommandErrors.UnknownFlag;
            },
        }
    }

    const help_requested = blk: {
        if (current_cmd.flag_values.get("help")) |flagValue| {
            if (flagValue.Bool == true) break :blk true;
        }
        break :blk argsContainHelpFlag(remaining_args);
    };

    if (help_requested) {
        try current_cmd.printHelp();
        try current_cmd.init_options.writer.flush();
        return .{
            .program_name = prog_name,
            .command = current_cmd,
            .remaining_args = remaining_args,
            .should_execute = false,
        };
    }

    current_cmd.parsePositionalArgs(remaining_args) catch |err| {
        try current_cmd.init_options.writer.flush();
        return err;
    };

    return .{
        .program_name = prog_name,
        .command = current_cmd,
        .remaining_args = remaining_args,
    };
}

fn assessArgType(arg: []const u8) PType {
    // Precondition: arg.len > 0

    if (arg[0] != '-' or arg.len == 1) return .WORD;

    if (std.fmt.parseInt(i32, arg, 10)) |_| return .WORD else |_| {}

    if (arg[1] != '-') return .GROUP_FLAG;

    const body = arg[2..];

    if (body.len == 0) return .WORD;

    if (std.mem.startsWith(u8, body, "no-") and body.len > "no-".len) {
        return .NEGATED_FLAG;
    }

    if (std.mem.indexOfScalar(u8, body, '=') != null) {
        return .LONG_FLAG_WITH_VALUE;
    }

    return .LONG_FLAG;
}

fn argsContainHelpFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return true;
        }

        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |shortcut| {
                if (shortcut == 'h') return true;
            }
        }
    }

    return false;
}
