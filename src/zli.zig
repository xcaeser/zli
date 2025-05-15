const std = @import("std");
const builtin = @import("lib/builtin.zig");
const styles = builtin.styles;

const stdout_file = std.io.getStdOut().writer();
var bw = std.io.bufferedWriter(stdout_file);
const stdout = bw.writer();
const stderr = std.io.getStdErr().writer();

pub const Section = enum {
    Usage,
    Configuration,
    Access,
    Help,
    Advanced,
    Experimental,
};

pub const FlagType = enum {
    Bool,
    Int,
    String,
};

pub const Flag = struct {
    name: []const u8,
    shortcut: ?[]const u8 = null,
    description: []const u8,
    flag_type: FlagType,
    default_value: union(FlagType) {
        Bool: bool,
        Int: i32,
        String: []const u8,
    },
};

pub const CommandOptions = struct {
    section: Section,
    name: []const u8,
    description: []const u8,
    shortcut: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    help: ?[]const u8 = null,
    usage: ?[]const u8 = null,
};

pub const CommandContext = struct {
    builder: *const Builder,
    command: *const Command,
    allocator: std.mem.Allocator,
    env: ?std.process.EnvMap = null,
    stdin: ?std.fs.File = null,
};

const ExecFn = *const fn (ctx: CommandContext) anyerror!void;

pub const Command = struct {
    options: CommandOptions,
    flags: std.StringHashMap(Flag),
    values: std.StringHashMap([]const u8),
    execFn: ExecFn,
    subcommands: std.ArrayList(*Command), // ArrayList instead of hashmap because I don't think you will be adding that many subcommads <3
    parent: ?*Command = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFn) !*Command {
        const cmd = try allocator.create(Command);
        cmd.* = Command{
            .options = options,
            .flags = std.StringHashMap(Flag).init(allocator),
            .values = std.StringHashMap([]const u8).init(allocator),
            .execFn = execFn,
            .subcommands = std.ArrayList(*Command).init(allocator),
            .allocator = allocator,
        };

        return cmd;
    }

    pub fn deinit(self: *Command) void {
        self.flags.deinit();
        self.values.deinit();
        for (self.subcommands.items) |subcmd| {
            subcmd.deinit();
            self.allocator.destroy(subcmd);
        }
        self.subcommands.deinit();
    }

    pub fn listSubcommands(self: *const Command) !void {
        if (self.subcommands.items.len > 0) {
            try stdout.print("\nSubcommands:\n", .{});
            try printAlignedCommands(self.subcommands.items);
        }
    }

    pub fn listFlags(self: *const Command) !void {
        if (self.flags.count() > 0) {
            try stdout.print("\nFlags:\n", .{});
            var it = self.flags.iterator();
            while (it.next()) |entry| {
                const flag = entry.value_ptr.*;

                // Print shortcut if available
                if (flag.shortcut) |shortcut| {
                    try stdout.print("  -{s}, ", .{shortcut});
                } else {
                    try stdout.print("      ", .{});
                }

                // Print flag name and description
                try stdout.print("--{s}\t{s} [{s}]", .{
                    flag.name,
                    flag.description,
                    @tagName(flag.flag_type),
                });

                // Print default value
                switch (flag.flag_type) {
                    .Bool => try stdout.print(" (default: {s})", .{if (flag.default_value.Bool) "true" else "false"}),
                    .Int => try stdout.print(" (default: {})", .{flag.default_value.Int}),
                    .String => if (flag.default_value.String.len > 0) {
                        try stdout.print(" (default: \"{s}\")", .{flag.default_value.String});
                    },
                }

                try stdout.print("\n", .{});
            }
        }
    }

    pub fn print(self: *const Command) !void {
        try stdout.print("\nDescription: {s}\n", .{self.options.description});
        try listSubcommands(self);
        try listFlags(self);
        try stdout.print("\nRun '{s} [command] --help' for more information about a command.\n", .{self.options.name});
    }

    // Print help for this command
    pub fn printHelp(self: *const Command) !void {
        if (self.options.help) |help| {
            try stdout.print("{s}\n", .{help});
        }

        if (self.options.usage) |usage| {
            try stdout.print("Usage: {s}\n", .{usage});
        } else {
            try stdout.print("Usage: {s} [options]\n", .{self.options.name});
        }

        try self.print();
    }

    // Get a boolean value from a flag
    pub fn getBoolValue(self: *const Command, flag_name: []const u8) bool {
        if (self.values.get(flag_name)) |value_str| {
            return std.mem.eql(u8, value_str, "true");
        } else if (self.flags.get(flag_name)) |flag| {
            return flag.default_value == .Bool and flag.default_value.Bool;
        }
        return false; // Default to false if flag doesn't exist
    }

    // Get an integer value from a flag
    pub fn getIntValue(self: *const Command, flag_name: []const u8) i32 {
        if (self.values.get(flag_name)) |value_str| {
            const trimmed = std.mem.trim(u8, value_str, " \t\r\n");
            return std.fmt.parseInt(i32, trimmed, 10) catch {
                if (self.flags.get(flag_name)) |flag| {
                    return if (flag.default_value == .Int) flag.default_value.Int else 0;
                }
                return 0;
            };
        } else if (self.flags.get(flag_name)) |flag| {
            return if (flag.default_value == .Int) flag.default_value.Int else 0;
        }
        return 0; // Default to 0 if flag doesn't exist
    }

    // Get a string value from a flag
    pub fn getStringValue(self: *const Command, flag_name: []const u8) []const u8 {
        if (self.values.get(flag_name)) |value_str| {
            return value_str;
        }

        if (self.flags.get(flag_name)) |flag| {
            if (flag.default_value == .String) {
                return flag.default_value.String;
            }
        }

        return ""; // Default to empty string if flag doesn't exist
    }

    // Get an optional string value from a flag (returns null if not found)
    pub fn getOptionalStringValue(self: *const Command, flag_name: []const u8) ?[]const u8 {
        if (self.values.get(flag_name)) |value_str| {
            return value_str;
        } else if (self.flags.get(flag_name)) |flag| {
            return if (flag.default_value == .String) flag.default_value.String else null;
        }
        return null; // Return null if flag doesn't exist
    }

    pub fn addSubCommand(self: *Command, subCmd: *Command) !void {
        subCmd.parent = self;
        try self.subcommands.append(subCmd);
    }

    pub fn addFlag(self: *Command, flag: Flag) !void {
        try self.flags.put(flag.name, flag);

        const default_value: []const u8 = switch (flag.default_value) {
            .Bool => if (flag.default_value.Bool) "true" else "false",
            .Int => blk: {
                var buf: [12]u8 = undefined;
                break :blk try std.fmt.bufPrint(&buf, "{}", .{flag.default_value.Int});
            },
            .String => flag.default_value.String,
        };

        try self.values.put(flag.name, default_value);
    }

    pub fn addFlags(self: *Command, flags: []const Flag) !void {
        for (flags) |flag| {
            try self.addFlag(flag);
        }
    }

    // Improved parseFlags with better error handling
    pub fn parseFlags(self: *Command, args: []const []const u8) !void {
        var i: usize = 0;
        while (i < args.len) {
            const arg = args[i];

            // Handle long flags (--flag)
            if (std.mem.startsWith(u8, arg, "--")) {
                const flag_name = arg[2..];

                // Check if it's a flag=value format
                if (std.mem.indexOf(u8, flag_name, "=")) |equal_index| {
                    const name = flag_name[0..equal_index];
                    const value = flag_name[equal_index + 1 ..];

                    self.handleFlagValue(name, value) catch |err| {
                        try printFlagError(err, name, value);
                        return err;
                    };
                } else {
                    // Regular --flag [value] format
                    self.handleFlag(flag_name, args, &i) catch |err| {
                        try printFlagError(err, flag_name, null);
                        // Suggest the correct usage if possible
                        try suggestCorrectUsage(self, flag_name);
                        return err;
                    };
                }
            }
            // Handle shorthand flags (-f)
            else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.eql(u8, arg, "-")) {
                // Multiple flags can be combined (-abc)
                const shortcuts = arg[1..];

                // Process each character as a separate shorthand
                for (shortcuts, 0..) |shortcut_char, char_index| {
                    const shortcut = [_]u8{shortcut_char};

                    // Find the corresponding flag for this shortcut
                    const flag_info = self.findFlagByShortcut(&shortcut);

                    if (flag_info) |flag| {
                        if (flag.flag_type != .Bool and char_index < shortcuts.len - 1) {
                            try stderr.print("Error: Non-boolean flag '-{c}' must be used separately or at the end of a flag group\n", .{shortcut_char});
                            return error.InvalidFlagCombination;
                        }

                        // Special case: if this is the last shortcut in the group
                        // and it expects a non-boolean value, the next argument is the value
                        if (char_index == shortcuts.len - 1 and flag.flag_type != .Bool) {
                            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                                try self.values.put(flag.name, args[i + 1]);
                                i += 1;
                            } else {
                                try stderr.print("Error: Missing value for shorthand flag -{c}\n", .{shortcut_char});
                                try stderr.print("Flag '{s}' requires a {s} value\n", .{ flag.name, @tagName(flag.flag_type) });
                                return error.MissingValueForFlag;
                            }
                        } else {
                            // Boolean shorthand flags default to true
                            if (flag.flag_type == .Bool) {
                                try self.values.put(flag.name, "true");
                            } else {
                                try stderr.print("Error: Invalid flag combination\n", .{});
                                try stderr.print("Non-boolean flag '-{c}' ({s}) cannot be combined with other flags\n", .{ shortcut_char, flag.name });
                                return error.InvalidFlagCombination;
                            }
                        }
                    } else {
                        try stderr.print("Error: Unknown shorthand flag: -{c}\n", .{shortcut_char});
                        return error.UnknownFlag;
                    }
                }
            }
            // else {
            //     // This is neither a flag nor a shorthand - could be a positional argument
            //     // For now, we'll just skip it, but you might want to collect these somewhere
            // }

            i += 1;
        }
    }

    // Helper function to find a flag by its shortcut
    fn findFlagByShortcut(self: *Command, shortcut: []const u8) ?Flag {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.shortcut) |flag_shortcut| {
                if (std.mem.eql(u8, flag_shortcut, shortcut)) {
                    return entry.value_ptr.*;
                }
            }
        }
        return null;
    }

    // Helper function to handle a flag and its value with improved error handling
    fn handleFlag(self: *Command, flag_name: []const u8, args: []const []const u8, i: *usize) !void {
        const def_flag = self.flags.get(flag_name) orelse return error.UnknownFlag;
        const flag = def_flag;
        var value: []const u8 = undefined;

        switch (flag.flag_type) {
            .Bool => {
                if (i.* + 1 < args.len and !std.mem.startsWith(u8, args[i.* + 1], "-")) {
                    const next_arg = args[i.* + 1];
                    if (std.mem.eql(u8, next_arg, "true") or std.mem.eql(u8, next_arg, "false")) {
                        value = next_arg;
                        i.* += 1;
                    } else {
                        value = "true";
                    }
                } else {
                    value = "true";
                }
            },
            else => {
                if (i.* + 1 >= args.len or std.mem.startsWith(u8, args[i.* + 1], "-")) {
                    return error.MissingValueForFlag;
                }
                value = args[i.* + 1];
                try validateValue(flag, value);
                i.* += 1;
            },
        }

        try self.values.put(flag_name, value);
    }

    // Helper function to handle flags in the flag=value format
    fn handleFlagValue(self: *Command, flag_name: []const u8, value: []const u8) !void {
        const def_flag = self.flags.get(flag_name) orelse return error.UnknownFlag;
        try validateValue(def_flag, value);
        try self.values.put(flag_name, value);
    }

    fn validateValue(flag: Flag, value: []const u8) !void {
        switch (flag.flag_type) {
            .Bool => {
                if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) {
                    return error.InvalidBooleanValue;
                }
            },
            .Int => {
                _ = std.fmt.parseInt(i32, value, 10) catch |err| {
                    std.log.err("Failed to parse integer '{s}': {s}", .{ value, @errorName(err) });
                    return error.InvalidIntegerValue;
                };
            },
            .String => {},
        }
    }

    fn findSubcommand(commands: []*Command, command_name_or_shortcut: []const u8) !?*Command {
        for (commands) |cmd| {
            if (std.mem.eql(u8, command_name_or_shortcut, cmd.options.name)) {
                return cmd;
            }
            if (cmd.options.shortcut) |shortcut| {
                if (std.mem.eql(u8, command_name_or_shortcut, shortcut)) {
                    return cmd;
                }
            }
        }
        return null;
    }

    pub fn executeExecFn(self: *Command, builder: *const Builder) !void {
        const ctx = CommandContext{
            .builder = builder,
            .command = self,
            .allocator = self.allocator,
        };
        self.execFn(ctx) catch |err| {
            try stderr.print("Error executing command: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    pub fn execute(self: *Command, builder: *const Builder, args: *std.ArrayList([]const u8)) !void {
        if (args.items.len != 0) {
            // Check for help flag
            if (std.mem.eql(u8, args.items[0], "--help") or std.mem.eql(u8, args.items[0], "-h")) {
                try self.printHelp();
                try bw.flush();
                std.process.exit(0);
            }

            // Find next command
            if (!std.mem.startsWith(u8, args.items[0], "-")) {
                const next_command = try findSubcommand(self.subcommands.items, args.items[0]) orelse {
                    try stderr.print("{s}Error:{s} Unknown command: '{s}'\n", .{ styles.BOLD, styles.RESET, args.items[0] });
                    try self.listSubcommands();
                    try bw.flush();
                    std.process.exit(1);
                };
                _ = try popFront([]const u8, args); // skip the current command name

                next_command.execute(builder, args) catch |err| {
                    try stderr.print("{s}Error:{s} {s} when executing command '{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), next_command.options.name });
                };
                try bw.flush();
                std.process.exit(0);
            }
        }

        // Parse flags
        self.parseFlags(args.items) catch {
            try stderr.print("\nRun '{s} {s} --help' for usage information\n", .{ builder.options.name, self.options.name });
            std.process.exit(1);
        };

        try self.executeExecFn(builder);
        try bw.flush();
    }

    // Suggest correct usage for a flag
    fn suggestCorrectUsage(command: *Command, flag_name: []const u8) !void {
        if (command.flags.get(flag_name)) |flag| {
            switch (flag.flag_type) {
                .Bool => {
                    try stderr.print("Boolean flag '--{s}' can be used without a value (defaults to true)\n", .{flag_name});
                    try stderr.print("Or explicitly: --{s}=true or --{s}=false\n", .{ flag_name, flag_name });
                },
                .Int => {
                    try stderr.print("Integer flag '--{s}' requires a numeric value\n", .{flag_name});
                    try stderr.print("Example: --{s}=123 or --{s} 123\n", .{ flag_name, flag_name });
                },
                .String => {
                    try stderr.print("String flag '--{s}' requires a text value\n", .{flag_name});
                    try stderr.print("Example: --{s}=\"hello\" or --{s} hello\n", .{ flag_name, flag_name });
                },
            }
        }
    }
    // Print a human-friendly error message for flag errors
    fn printFlagError(err: anyerror, flag_name: []const u8, value: ?[]const u8) !void {
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
};

pub const BuilderOptions = struct {
    name: []const u8,
    description: []const u8,
    version: std.SemanticVersion,
    commands_title: []const u8 = "Available commands",
};

pub const Builder = struct {
    options: BuilderOptions,
    commands_by_name: std.StringHashMap(*Command),
    commands_by_shortcut: std.StringHashMap(*Command),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: BuilderOptions) !Builder {
        return Builder{
            .options = options,
            .commands_by_name = std.StringHashMap(*Command).init(allocator),
            .commands_by_shortcut = std.StringHashMap(*Command).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Builder) void {
        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            const cmd = entry.value_ptr.*;
            cmd.deinit();
            self.allocator.destroy(cmd);
        }
        self.commands_by_name.deinit();
        self.commands_by_shortcut.deinit();
    }

    pub fn showInfo(self: *const Builder) !void {
        try stdout.print("{s}{s}{s}\n", .{ styles.BOLD, self.options.description, styles.RESET });
        try stdout.print("{s}v{}{s}\n", .{ styles.DIM, self.options.version, styles.RESET });
    }

    pub fn listCommands(self: *const Builder) !void {
        if (self.commands_by_name.count() == 0) {
            try stdout.print("\nNo commands available.\n", .{});
            return;
        }

        try stdout.print("\n{s}:\n", .{self.options.commands_title});

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

        try stdout.print("\nUse '{s} [command] --help' for more information about a command.\n", .{self.options.name});
    }

    pub fn showHelp(self: *const Builder) !void {
        try self.showInfo();
        try self.listCommands();
    }

    fn addCommand(self: *Builder, command: *Command) !void {
        try self.commands_by_name.put(command.options.name, command);
        if (command.options.shortcut) |shortcut| try self.commands_by_shortcut.put(shortcut, command);
    }

    pub fn addCommands(self: *Builder, cmds: []const *Command) !void {
        for (cmds) |cmd| try self.addCommand(cmd);
    }

    // TODO: reword due to cmd.execute need for args.
    // pub fn executeCmd(self: *const Builder, cmd_name: []const u8, args: []const []const u8) !void {
    //     // Find the requested command
    //     var found_cmd: ?*Command = null;
    //     for (self.commands.items) |*cmd| {
    //         if (std.mem.eql(u8, cmd_name, cmd.options.name)) {
    //             found_cmd = cmd;
    //             break;
    //         }
    //     }

    //     if (found_cmd) |cmd| {
    //         // Parse and execute
    //         cmd.parseFlags(args) catch {
    //             try stderr.print("\nRun '{s} {s} --help' for usage information\n", .{ self.options.name, cmd.options.name });
    //             return;
    //         };

    //         cmd.execute(self) catch |err| {
    //             try stderr.print("{s}Error:{s} {s} when executing command '{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), cmd.options.name });
    //             return;
    //         };
    //     } else {
    //         try stderr.print("{s}Error:{s} Unknown command: '{s}'\n", .{ styles.BOLD, styles.RESET, cmd_name });
    //         try self.listCommands();
    //         return;
    //     }
    // }

    pub fn findCommand(self: *const Builder, name_or_shortcut: []const u8) ?*Command {
        if (self.commands_by_name.get(name_or_shortcut)) |cmd| return cmd;
        if (self.commands_by_shortcut.get(name_or_shortcut)) |cmd| return cmd;
        return null;
    }

    fn getMainCommand(self: *const Builder, args: *std.ArrayList([]const u8)) !*Command {
        if (args.items.len == 0) {
            try self.showInfo();
            try self.listCommands();
            try bw.flush();
            std.process.exit(0);
        }

        // Check for help flag
        if (std.mem.eql(u8, args.items[0], "--help") or std.mem.eql(u8, args.items[0], "-h")) {
            try self.showHelp();
            try bw.flush();
            std.process.exit(0);
        }

        const command_name = args.items[0];

        // Find main command
        const main_command = self.findCommand(command_name) orelse {
            try stderr.print("{s}Error:{s} Unknown command: '{s}'\n", .{ styles.BOLD, styles.RESET, command_name });
            try self.listCommands();
            try bw.flush();
            std.process.exit(1);
        };

        return main_command;
    }

    pub fn execute(self: *const Builder) !void {
        var input = std.process.args();
        _ = input.skip(); // skip program name

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (input.next()) |arg| {
            try args.append(arg);
        }

        const command = try self.getMainCommand(&args);

        _ = try popFront([]const u8, &args); // skip the main command name

        command.execute(self, &args) catch |err| {
            try stderr.print("{s}Error:{s} {s} when executing command '{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), command.options.name });
        };
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
        try stdout.print("   {s}", .{cmd.options.name});

        // Print shortcut directly if exists
        if (cmd.options.shortcut) |s| {
            try stdout.print(" ({s})", .{s});
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

        try stdout.writeByteNTimes(' ', padding + 4); // 4-space gap between name and desc
        try stdout.print("{s}\n", .{desc});
    }
}

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
