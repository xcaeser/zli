const std = @import("std");
const builtin = @import("lib/builtin.zig");
const styles = builtin.styles;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub const Section = enum {
    Usage,
    Configuration,
    Access,
    Help,
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
    shortcut: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    description: []const u8,
    usage: ?[]const u8 = null,
};

pub const CommandContext = struct {
    builder: *Builder,
    command: *Command,
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFn) !Command {
        return Command{
            .options = options,
            .flags = std.StringHashMap(Flag).init(allocator),
            .values = std.StringHashMap([]const u8).init(allocator),
            .execFn = execFn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Command) void {
        self.flags.deinit();
        self.values.deinit();
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

                    if (flag_info) |info| {
                        const flag_name = info.name;
                        const flag = info.flag;
                        if (flag.flag_type != .Bool and char_index < shortcuts.len - 1) {
                            try stderr.print("Error: Non-boolean flag '-{c}' must be used separately or at the end of a flag group\n", .{shortcut_char});
                            return error.InvalidFlagCombination;
                        }

                        // Special case: if this is the last shortcut in the group
                        // and it expects a non-boolean value, the next argument is the value
                        if (char_index == shortcuts.len - 1 and flag.flag_type != .Bool) {
                            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                                try self.values.put(flag_name, args[i + 1]);
                                i += 1;
                            } else {
                                try stderr.print("Error: Missing value for shorthand flag -{c}\n", .{shortcut_char});
                                try stderr.print("Flag '{s}' requires a {s} value\n", .{ flag_name, @tagName(flag.flag_type) });
                                return error.MissingValueForFlag;
                            }
                        } else {
                            // Boolean shorthand flags default to true
                            if (flag.flag_type == .Bool) {
                                try self.values.put(flag_name, "true");
                            } else {
                                try stderr.print("Error: Invalid flag combination\n", .{});
                                try stderr.print("Non-boolean flag '-{c}' ({s}) cannot be combined with other flags\n", .{ shortcut_char, flag_name });
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
    fn findFlagByShortcut(self: *Command, shortcut: []const u8) ?struct { name: []const u8, flag: Flag } {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.shortcut) |flag_shortcut| {
                if (std.mem.eql(u8, flag_shortcut, shortcut)) {
                    return .{
                        .name = entry.key_ptr.*,
                        .flag = entry.value_ptr.*,
                    };
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

    // Get a boolean value from a flag
    pub fn getBoolValue(self: *Command, flag_name: []const u8) bool {
        if (self.values.get(flag_name)) |value_str| {
            return std.mem.eql(u8, value_str, "true");
        } else if (self.flags.get(flag_name)) |flag| {
            return flag.default_value == .Bool and flag.default_value.Bool;
        }
        return false; // Default to false if flag doesn't exist
    }

    // Get an integer value from a flag
    pub fn getIntValue(self: *Command, flag_name: []const u8) i32 {
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
    pub fn getStringValue(self: *Command, flag_name: []const u8) []const u8 {
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
    pub fn getOptionalStringValue(self: *Command, flag_name: []const u8) ?[]const u8 {
        if (self.values.get(flag_name)) |value_str| {
            return value_str;
        } else if (self.flags.get(flag_name)) |flag| {
            return if (flag.default_value == .String) flag.default_value.String else null;
        }
        return null; // Return null if flag doesn't exist
    }

    pub fn execute(self: *Command, builder: *Builder) !void {
        const ctx = CommandContext{
            .builder = builder,
            .command = self,
            .allocator = self.allocator,
        };
        try self.execFn(ctx);
    }

    pub fn print(self: *const Command) !void {
        try stdout.print("Description: {s}\n\n", .{self.options.description});

        // Print flags
        if (self.flags.count() > 0) {
            try stdout.print("Flags:\n", .{});
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

    // Print help for this command
    pub fn printHelp(self: *const Command) !void {
        try stdout.print("\n", .{});
        // Print usage if available, or generate a default one
        if (self.options.usage) |usage| {
            try stdout.print("Usage: {s} {s} [options]\n\n", .{ self.options.name, usage });
        } else {
            try stdout.print("Usage: {s} [options]\n\n", .{self.options.name});
        }

        try self.print();
    }
};

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

pub const BuilderOptions = struct {
    name: []const u8,
    description: []const u8,
    version: std.SemanticVersion,
};

pub const Builder = struct {
    options: BuilderOptions,
    commands: std.ArrayList(Command),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: BuilderOptions) !Builder {
        return Builder{
            .options = options,
            .commands = std.ArrayList(Command).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Builder) void {
        for (self.commands.items) |*cmd| {
            cmd.deinit();
        }
        self.commands.deinit();
    }

    fn addCommand(self: *Builder, command: Command) !void {
        try self.commands.append(command);
    }

    pub fn addCommands(self: *Builder, cmds: []const Command) !void {
        for (cmds) |cmd| try self.addCommand(cmd);
    }

    // Modified function to handle errors without exposing stack traces
    fn processArgs(self: *Builder) !?*Command {
        var input = std.process.args();
        _ = input.skip(); // skip program name

        const command_name = input.next() orelse {
            // No command provided, show general help/info
            try self.showInfo();
            try self.listCommands();
            return null;
        };

        // Special case for global help command
        if (std.mem.eql(u8, command_name, "--help") or std.mem.eql(u8, command_name, "-h")) {
            try self.showHelp();
            return null;
        }

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        while (input.next()) |arg| {
            try args.append(arg);
        }

        // Find the requested command
        for (self.commands.items) |*cmd| {
            const matches = if (std.mem.eql(u8, command_name, cmd.options.name)) true else if (cmd.options.shortcut) |shortcut| std.mem.eql(u8, command_name, shortcut) else false;

            if (matches) {
                // Check for help flag
                for (args.items) |arg| {
                    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                        try cmd.printHelp();
                        return null; // Signal that we've handled this case
                    }
                }

                // Parse flags
                cmd.parseFlags(args.items) catch {
                    try stderr.print("\nRun '{s} {s} --help' for usage information\n", .{ self.options.name, cmd.options.name });
                    return null; // Signal error without propagating it
                };

                return cmd;
            }
        }

        // Command not found
        try stderr.print("{s}Error:{s} Unknown command: '{s}'\n\n", .{ styles.BOLD, styles.RESET, command_name });
        try self.listCommands();
        return null; // Signal error without propagating it
    }

    pub fn executeCmd(self: *Builder, cmd_name: []const u8, args: []const []const u8) !void {
        // Find the requested command
        var found_cmd: ?*Command = null;
        for (self.commands.items) |*cmd| {
            if (std.mem.eql(u8, cmd_name, cmd.options.name)) {
                found_cmd = cmd;
                break;
            }
        }

        if (found_cmd) |cmd| {
            // Parse and execute
            cmd.parseFlags(args) catch {
                try stderr.print("\nRun '{s} {s} --help' for usage information\n", .{ self.options.name, cmd.options.name });
                return;
            };

            cmd.execute(self) catch |err| {
                try stderr.print("{s}Error:{s} {s} when executing command '{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), cmd.options.name });
                return;
            };
        } else {
            try stderr.print("{s}Error:{s} Unknown command: '{s}'\n", .{ styles.BOLD, styles.RESET, cmd_name });
            try self.listCommands();
            return;
        }
    }

    pub fn showInfo(self: *Builder) !void {
        try stdout.print("{s}{s}{s}\n", .{ styles.BOLD, self.options.description, styles.RESET });
        try stdout.print("{s}v{}{s}\n\n", .{ styles.DIM, self.options.version, styles.RESET });
    }

    pub fn listCommands(self: *Builder) !void {
        if (self.commands.items.len == 0) {
            try stdout.print("No commands available.\n", .{});
            return;
        }

        try stdout.print("Available commands:\n", .{});

        // Step 1: determine the maximum name + shortcut width
        var max_width: usize = 0;
        for (self.commands.items) |cmd| {
            const name_len = cmd.options.name.len;
            const shortcut_len = if (cmd.options.shortcut) |s| s.len + 3 else 0; // for " ()"
            const total_len = name_len + shortcut_len;
            if (total_len > max_width) {
                max_width = total_len;
            }
        }

        // Step 2: print commands with aligned descriptions
        for (self.commands.items) |cmd| {
            const shortcut_text = if (cmd.options.shortcut) |s| std.fmt.allocPrint(self.allocator, " ({s})", .{s}) catch "()" else "";
            defer if (cmd.options.shortcut != null) self.allocator.free(shortcut_text);

            const name_and_shortcut = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ cmd.options.name, shortcut_text });
            defer self.allocator.free(name_and_shortcut);

            const padding = max_width - name_and_shortcut.len;
            try stdout.print("   {s}", .{name_and_shortcut});
            try stdout.writeByteNTimes(' ', padding + 4); // 2 spaces between name and desc
            try stdout.print("{s}\n", .{cmd.options.description});
        }

        try stdout.print("\nUse '{s} [command] --help' for more information about a command.\n", .{self.options.name});
    }

    pub fn showHelp(self: *Builder) !void {
        try self.showInfo();
        try self.listCommands();
    }

    // Updated Builder.execute without redundant showInfo
    pub fn execute(self: *Builder) !void {
        // Process arguments with improved error handling
        const command = try self.processArgs();

        // If processArgs returned null, an error occurred or help was shown
        if (command == null) {
            return;
        }

        // Execute the command and handle errors internally
        command.?.execute(self) catch |err| {
            try stderr.print("{s}Error:{s} {s} when executing command '{s}'\n", .{ styles.BOLD, styles.RESET, @errorName(err), command.?.options.name });
            return; // Return without propagating the error
        };
    }
};
