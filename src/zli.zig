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
/// Set as `--name value`, `--name=value` or `-s value`. Bool flags take no
/// separate value: `--verbose`, `--no-verbose` or `--verbose=false`.
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

    /// Returns the flag's value as `T`. Ints out of range for `T` saturate (e.g. -1 as u32 is 0); an undefined flag name panics.
    pub fn flag(self: *const CommandContext, flag_name: []const u8, comptime T: type) T {
        const found = self.command.findFlag(flag_name) orelse
            std.debug.panic("zli: flag '{s}' is not defined on command '{s}'", .{ flag_name, self.command.cmd_options.name });

        // Every flag gets its default in `flag_values` when added, keyed by name.
        return switch (self.command.flag_values.get(found.name).?) {
            .Bool => |b| if (T == bool) b else getDefaultValue(T),
            .Int => |i| if (@typeInfo(T) == .int) std.math.lossyCast(T, i) else getDefaultValue(T),
            .String => |s| if (T == []const u8) s else getDefaultValue(T),
        };
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

    /// Set to 5, you can change this
    _general_padding: usize = 5,

    pub fn init(init_opts: InitOptions, cmd_options: CommandOptions, execFn: ExecFn) Allocator.Error!*Command {
        const cmd = try init_opts.allocator.create(Command);
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
        errdefer cmd.deinit();

        const helpFlag: Flag = .{
            .name = "help",
            .description = "Shows the help for a command",
            .shortcut = "h",
            .type = .Bool,
            .default_value = .{ .Bool = false },
            .persistent = true, // `app --help sub` shows sub's help
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
        var sorted = try self.sortedCommands(false);
        defer sorted.deinit(self.init_options.allocator);
        if (sorted.items.len == 0) return;

        try self.init_options.writer.print("{s}:\n", .{self.cmd_options.commands_title});
        try self.printAlignedCommands(sorted.items);
    }

    pub fn printCommandsBySection(self: *const Command) CommandPrintErrors!void {
        var sorted = try self.sortedCommands(true);
        defer sorted.deinit(self.init_options.allocator);
        const commands = sorted.items;

        var start: usize = 0;
        while (start < commands.len) {
            const section = commands[start].cmd_options.section_title;
            var end = start + 1;
            while (end < commands.len and std.mem.eql(u8, commands[end].cmd_options.section_title, section)) end += 1;

            if (start > 0) try self.init_options.writer.writeByte('\n');
            try self.init_options.writer.print("{s}{s}{s}:\n", .{ styles.BOLD, section, styles.RESET });
            try self.printAlignedCommands(commands[start..end]);
            start = end;
        }
    }

    /// Prints the visible flags, sorted by name.
    pub fn printFlags(self: *const Command) Io.Writer.Error!void {
        const w = self.init_options.writer;
        const column = self.descriptionColumn();

        // ponytail: O(n²) selection sort, since this error set has no OutOfMemory to allocate with; fine for a help screen.
        var last: ?[]const u8 = null;
        while (true) {
            var next: ?*const Flag = null;
            var it = self.flags_by_name.valueIterator();
            while (it.next()) |f| {
                if (f.hidden) continue;
                if (last != null and !std.mem.lessThan(u8, last.?, f.name)) continue;
                if (next == null or std.mem.lessThan(u8, f.name, next.?.name)) next = f;
            }
            const flag = next orelse return;
            if (last == null) try w.writeAll("Flags:\n");
            last = flag.name;

            try w.writeAll("   " ++ styles.BOLD);
            if (flag.shortcut) |shortcut| try w.print("-{s}, ", .{shortcut});
            try w.print("--{s}" ++ styles.RESET, .{flag.name});
            try printDescription(w, column, flagWidth(flag.*), flag.description);
            try w.print(" [{t}]", .{flag.type});
            switch (flag.default_value) {
                .Bool => |b| try w.print(" (default: {})", .{b}),
                .Int => |i| try w.print(" (default: {d})", .{i}),
                .String => |s| if (s.len > 0) try w.print(" (default: \"{s}\")", .{s}),
            }
            try w.writeByte('\n');
        }
    }

    pub fn printPositionalArgs(self: *const Command) Io.Writer.Error!void {
        if (self.positional_args.items.len == 0) return;

        const w = self.init_options.writer;
        const column = self.descriptionColumn();
        try w.writeAll("Arguments:\n");
        for (self.positional_args.items) |arg| {
            try w.print("   {s}{s}{s}", .{ styles.BOLD, arg.name, styles.RESET });
            try printDescription(w, column, arg.name.len, arg.description);
            if (arg.required) try w.writeAll(" (required)");
            if (arg.variadic) try w.writeAll(" (variadic)");
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }

    pub fn printAliases(self: *const Command) Io.Writer.Error!void {
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

    pub fn printUsageLine(self: *const Command) CommandPrintErrors!void {
        const w = self.init_options.writer;
        try w.writeAll("Usage: ");
        try self.printPath(w);
        try w.writeAll(" [options]");

        for (self.positional_args.items) |arg| {
            if (arg.required) {
                try w.print(" <{s}>", .{arg.name});
            } else {
                try w.print(" [{s}]", .{arg.name});
            }
            if (arg.variadic) try w.writeAll("...");
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
    pub fn printHelp(self: *const Command) CommandPrintErrors!void {
        return self.printFullHelp(false);
    }

    /// Prints help with commands organized by sections
    pub fn printStructuredHelp(self: *const Command) CommandPrintErrors!void {
        return self.printFullHelp(true);
    }

    fn printFullHelp(self: *const Command, by_section: bool) CommandPrintErrors!void {
        if (self.cmd_options.deprecated) return;
        const w = self.init_options.writer;

        try self.printInfo();
        try w.writeByte('\n');

        if (self.cmd_options.help) |help| try w.print("{s}\n\n", .{help});

        if (self.cmd_options.usage) |usage| try w.print("Usage: {s}", .{usage}) else try self.printUsageLine();
        try w.writeByte('\n');

        const aliases: []const []const u8 = self.cmd_options.aliases orelse &.{};
        if (aliases.len > 0) {
            try w.writeByte('\n');
            try self.printAliases();
            try w.writeByte('\n');
        }

        var cmd_it = self.commands_by_name.valueIterator();
        const has_commands = while (cmd_it.next()) |cmd| {
            if (!cmd.*.cmd_options.deprecated) break true;
        } else false;
        if (has_commands) {
            try w.writeByte('\n');
            if (by_section) try self.printCommandsBySection() else try self.printCommands();
        }
        try w.writeByte('\n');

        try self.printFlags();
        if (self.flags_by_name.count() > 0) try w.writeByte('\n');

        try self.printPositionalArgs();
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
        var flag_it = self.flags_by_name.valueIterator();
        while (flag_it.next()) |f| {
            if (f.persistent) try command.addFlag(f.*);
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
        if (flag.persistent) {
            var cmd_it = self.commands_by_name.valueIterator();
            while (cmd_it.next()) |c| try c.*.addFlag(flag);
        }
        if (flag.shortcut) |shortcut| if (shortcut.len == 1) try self.flags_by_shortcut.put(shortcut, flag) else @panic("Flag shortcut must be 1 char");

        try self.flag_values.put(flag.name, flag.default_value);
    }

    pub fn addFlags(self: *Command, flags: []const Flag) Allocator.Error!void {
        for (flags) |flag| {
            try self.addFlag(flag);
        }
    }

    fn findFlag(self: *const Command, name_or_shortcut: []const u8) ?Flag {
        if (self.flags_by_name.get(name_or_shortcut)) |flag| return flag;
        if (self.flags_by_shortcut.get(name_or_shortcut)) |flag| return flag;
        return null;
    }

    fn setFlagValue(self: *Command, flag: Flag, value: []const u8) CommandParseErrors!void {
        const flag_value = flag.evaluateValue(value) catch {
            try self.init_options.writer.print("Invalid value for flag --{s}: '{s}'\nExpected a value of type: {t}\n", .{ flag.name, value, flag.type });
            try self.displayCommandError();
            return CommandErrors.InvalidFlagValue;
        };
        try self.flag_values.put(flag.name, flag_value);
    }

    fn parsePositionalArgs(self: *Command, args: []const []const u8) CommandParseErrors!void {
        const expected = self.positional_args.items;

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

        const variadic = expected.len > 0 and expected[expected.len - 1].variadic;
        if (!variadic and args.len > expected.len) {
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
    ///  const root = try cli.build(init_options);
    ///  defer root.deinit();
    ///  try root.execute(&args_iter, .{});
    ///  try writer.flush();
    /// ```
    pub fn execute(self: *Command, argsIterator: *std.process.Args.Iterator, context: DataContext) anyerror!void {
        const parsedOutput = try parseArgs(self, argsIterator);
        defer parsedOutput.deinit(self.init_options.allocator);

        const cmd = parsedOutput.command;
        if (!parsedOutput.should_execute) return;

        var spinner = Spinner.init(cmd.init_options.io, cmd.init_options.writer, cmd.init_options.allocator, .{});
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

    /// Runs the command as a full CLI application and exits the process with `run`'s exit code.
    ///
    /// This is the convenient entrypoint for binaries. Use `execute` when you
    /// need library-friendly behavior for tests, embedding, or custom error
    /// handling.
    pub fn runAndExit(self: *Command, argsIterator: *std.process.Args.Iterator, context: DataContext) noreturn {
        std.process.exit(self.run(argsIterator, context));
    }

    /// Like `runAndExit`, but returns the exit code instead of exiting: 0 on success, 1 on error.
    /// zli's own `CommandErrors` already printed their message; any other error, such as one
    /// returned by the command's exec function, is printed as `error: Name`. Flushes the writer.
    pub fn run(self: *Command, argsIterator: *std.process.Args.Iterator, context: DataContext) u8 {
        defer self.init_options.writer.flush() catch {};
        self.execute(argsIterator, context) catch |err| {
            if (!isCommandError(err)) self.init_options.writer.print("error: {s}\n", .{@errorName(err)}) catch {};
            return 1;
        };
        return 0;
    }

    fn displayCommandError(self: *const Command) Io.Writer.Error!void {
        const w = self.init_options.writer;
        try w.writeAll("\nRun: '");
        try self.printPath(w);
        try w.writeAll(" --help'\n");
    }

    /// Writes the command's path from the root, e.g. "app remote add".
    fn printPath(self: *const Command, w: *Io.Writer) Io.Writer.Error!void {
        if (self.parent) |parent| {
            try parent.printPath(w);
            try w.writeByte(' ');
        }
        try w.writeAll(self.cmd_options.name);
    }

    /// Where help descriptions start, counted after the row indent, so commands, flags and args line up.
    fn descriptionColumn(self: *const Command) usize {
        var widest: usize = 0;
        var cmd_it = self.commands_by_name.valueIterator();
        while (cmd_it.next()) |cmd| {
            if (!cmd.*.cmd_options.deprecated) widest = @max(widest, commandWidth(cmd.*));
        }
        var flag_it = self.flags_by_name.valueIterator();
        while (flag_it.next()) |f| {
            if (!f.hidden) widest = @max(widest, flagWidth(f.*));
        }
        for (self.positional_args.items) |arg| widest = @max(widest, arg.name.len);
        return widest + self._general_padding;
    }

    /// Returns the subcommands help lists (deprecated ones are left out), sorted by name and
    /// grouped by section title first if `by_section`. Caller deinits.
    fn sortedCommands(self: *const Command, by_section: bool) Allocator.Error!ArrayList(*Command) {
        var commands: ArrayList(*Command) = try .initCapacity(self.init_options.allocator, self.commands_by_name.count());
        var it = self.commands_by_name.valueIterator();
        while (it.next()) |cmd| {
            if (!cmd.*.cmd_options.deprecated) commands.appendAssumeCapacity(cmd.*);
        }

        std.sort.insertion(*Command, commands.items, by_section, struct {
            fn lessThan(sectioned: bool, a: *Command, b: *Command) bool {
                if (sectioned) {
                    const order = std.mem.order(u8, a.cmd_options.section_title, b.cmd_options.section_title);
                    if (order != .eq) return order == .lt;
                }
                return std.mem.lessThan(u8, a.cmd_options.name, b.cmd_options.name);
            }
        }.lessThan);
        return commands;
    }

    fn printAlignedCommands(self: *const Command, commands: []const *Command) Io.Writer.Error!void {
        const w = self.init_options.writer;
        const column = self.descriptionColumn();
        for (commands) |cmd| {
            try w.print("   {s}{s}{s}", .{ styles.BOLD, cmd.cmd_options.name, styles.RESET });
            if (cmd.cmd_options.shortcut) |s| try w.print(" ({s})", .{s});
            try printDescription(w, column, commandWidth(cmd), cmd.cmd_options.short_description orelse cmd.cmd_options.description);
            try w.writeByte('\n');
        }
    }
};

// HELPER FUNCTIONS

fn isCommandError(err: anyerror) bool {
    inline for (@typeInfo(CommandErrors).error_set.error_names.?) |name| {
        if (err == @field(CommandErrors, name)) return true;
    }
    return false;
}

/// Pads a help row from its name (`name_width` wide, after the row's 3-space indent) to `column`,
/// then writes `description`, indenting any further lines to the same column.
fn printDescription(w: *Io.Writer, column: usize, name_width: usize, description: []const u8) Io.Writer.Error!void {
    try w.splatByteAll(' ', column - name_width);
    var lines = std.mem.splitScalar(u8, description, '\n');
    try w.writeAll(lines.first());
    while (lines.next()) |line| {
        try w.writeByte('\n');
        if (line.len > 0) try w.splatByteAll(' ', 3 + column);
        try w.writeAll(line);
    }
}

/// Width of "-s, --name" (or "--name") in a help row.
fn flagWidth(flag: Flag) usize {
    return flag.name.len + 2 + (if (flag.shortcut) |s| s.len + 3 else 0);
}

/// Width of "name (s)" (or "name") in a help row.
fn commandWidth(cmd: *const Command) usize {
    return cmd.cmd_options.name.len + (if (cmd.cmd_options.shortcut) |s| s.len + 3 else 0);
}

const ParserOutput = struct {
    command: *Command,
    remaining_args: []const []const u8,
    should_execute: bool = true,

    pub fn deinit(self: ParserOutput, allocator: Allocator) void {
        allocator.free(self.remaining_args);
    }
};

fn parseArgs(self: *Command, argsIterator: *std.process.Args.Iterator) CommandParseErrors!ParserOutput {
    var current_cmd = self;
    const allocator = self.init_options.allocator;
    // Callers that `try execute(...)` skip their own flush on error, so get the message out here.
    errdefer current_cmd.init_options.writer.flush() catch {};

    _ = argsIterator.skip(); // program name

    var positionals: ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    var in_positionals = false;

    while (argsIterator.next()) |arg| {
        const writer = current_cmd.init_options.writer;

        if (std.mem.eql(u8, arg, "--")) {
            while (argsIterator.next()) |rest| try positionals.append(allocator, rest);
            break;
        }

        // Words, "", "-" and negative numbers like -5 or -1.5 are subcommands or positional args.
        if (arg.len < 2 or arg[0] != '-' or std.ascii.isDigit(arg[1])) {
            if (!in_positionals) {
                if (current_cmd.findCommand(arg)) |found_cmd| {
                    try found_cmd.checkDeprecated();

                    // Persistent flags given before the subcommand carry down to it.
                    var flag_it = current_cmd.flags_by_name.valueIterator();
                    while (flag_it.next()) |f| {
                        if (f.persistent) try found_cmd.flag_values.put(f.name, current_cmd.flag_values.get(f.name).?);
                    }

                    current_cmd = found_cmd;
                    continue;
                }

                if (current_cmd.positional_args.items.len == 0) {
                    try writer.print("Unknown command: '{s}'\n", .{arg});
                    try current_cmd.displayCommandError();
                    return CommandErrors.UnknownCommand;
                }

                // We've reached the positional section of this command.
                in_positionals = true;
            }

            try positionals.append(allocator, arg);
        } else if (arg[1] == '-') {
            // --name, --name=value or --no-name
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = body[0 .. eq orelse body.len];

            if (current_cmd.findFlag(name)) |flag| {
                if (eq) |i| {
                    try current_cmd.setFlagValue(flag, body[i + 1 ..]);
                } else if (flag.type == .Bool) {
                    try current_cmd.flag_values.put(flag.name, .{ .Bool = true });
                } else {
                    const value = argsIterator.next() orelse {
                        try writer.print("Missing value for flag --{s} of type: {t}\n", .{ flag.name, flag.type });
                        try current_cmd.displayCommandError();
                        return CommandErrors.MissingFlagValue;
                    };
                    try current_cmd.setFlagValue(flag, value);
                }
                continue;
            }

            // Tried after the full name, so a flag named like "no-cache" still works.
            const negated = if (eq == null and std.mem.startsWith(u8, name, "no-")) current_cmd.findFlag(name["no-".len..]) else null;
            const flag = negated orelse {
                try writer.print("Unknown flag: --{s}\n", .{body});
                try current_cmd.displayCommandError();
                return CommandErrors.UnknownFlag;
            };
            if (flag.type != .Bool) {
                try writer.print("Flag --{s} does not accept negation as it expects type: {t}\n", .{ flag.name, flag.type });
                return CommandErrors.InvalidFlagNegation;
            }
            try current_cmd.flag_values.put(flag.name, .{ .Bool = false });
        } else {
            // -v, or a group like -vt 2 where only the last shortcut may take a value
            const shortcuts = arg[1..];
            for (shortcuts, 0..) |c, i| {
                const flag = current_cmd.findFlag(shortcuts[i .. i + 1]) orelse {
                    try writer.print("Unknown flag shortcut: -{c}\n", .{c});
                    try current_cmd.displayCommandError();
                    return CommandErrors.UnknownFlag;
                };
                if (flag.type == .Bool) {
                    try current_cmd.flag_values.put(flag.name, .{ .Bool = true });
                } else if (i < shortcuts.len - 1) {
                    try writer.print("Flag -{c} ({s}) must be last in group since it expects a value of type: {t}\n", .{ c, flag.name, flag.type });
                    return CommandErrors.InvalidFlagShortcut;
                } else {
                    const value = argsIterator.next() orelse {
                        try writer.print("Missing value for flag -{c} ({s}) of type: {t}\n", .{ c, flag.name, flag.type });
                        try current_cmd.displayCommandError();
                        return CommandErrors.MissingFlagValue;
                    };
                    try current_cmd.setFlagValue(flag, value);
                }
            }
        }
    }

    const remaining_args = try positionals.toOwnedSlice(allocator);
    errdefer allocator.free(remaining_args);

    const help_requested = if (current_cmd.flag_values.get("help")) |v| v.Bool else false;
    if (help_requested) {
        try current_cmd.printHelp();
        try current_cmd.init_options.writer.flush();
        return .{ .command = current_cmd, .remaining_args = remaining_args, .should_execute = false };
    }

    try current_cmd.parsePositionalArgs(remaining_args);
    return .{ .command = current_cmd, .remaining_args = remaining_args };
}
