const std = @import("std");
const builtin = @import("lib/builtin.zig");
const styles = builtin.styles;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

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

pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false,
};

pub const CommandOptions = struct {
    section_title: []const u8 = "General",
    name: []const u8,
    description: []const u8,
    version: ?std.SemanticVersion = null,
    commands_title: []const u8 = "Available commands",
    shortcut: ?[]const u8 = null,
    short_description: ?[]const u8 = null,
    help: ?[]const u8 = null,
    usage: ?[]const u8 = null,
    deprecated: bool = false,
    replaced_by: ?[]const u8 = null,
};

pub const CommandContext = struct {
    root: *const Command,
    direct_parent: *const Command,
    command: *Command,
    allocator: std.mem.Allocator,
    env: ?std.process.EnvMap = null,
    stdin: ?std.fs.File = null,
    // positional_args: [][]const u8,
};

const ExecFn = *const fn (ctx: CommandContext) anyerror!void;

pub const Command = struct {
    options: CommandOptions,
    flags: std.StringHashMap(Flag),
    flag_values: std.StringHashMap([]const u8),
    positional_args: std.ArrayList(PositionalArg),
    execFn: ExecFn,
    commands_by_name: std.StringHashMap(*Command),
    commands_by_shortcut: std.StringHashMap(*Command),
    parent: ?*Command = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFn) !*Command {
        const cmd = try allocator.create(Command);
        cmd.* = Command{
            .options = options,
            .flags = std.StringHashMap(Flag).init(allocator),
            .flag_values = std.StringHashMap([]const u8).init(allocator),
            .positional_args = std.ArrayList(PositionalArg).init(allocator),
            .execFn = execFn,
            .commands_by_name = std.StringHashMap(*Command).init(allocator),
            .commands_by_shortcut = std.StringHashMap(*Command).init(allocator),
            .allocator = allocator,
        };

        return cmd;
    }

    pub fn deinit(self: *Command) void {
        self.flags.deinit();
        self.flag_values.deinit();
        self.positional_args.deinit();

        var it = self.commands_by_name.iterator();
        while (it.next()) |entry| {
            const cmd = entry.value_ptr.*;
            cmd.deinit();
            self.allocator.destroy(cmd);
        }
        self.commands_by_name.deinit();
        self.commands_by_shortcut.deinit();
    }

    pub fn listCommands(self: *const Command) !void {
        if (self.commands_by_name.count() == 0) {
            try stdout.print("No commands available.\n", .{});
            return;
        }

        try stdout.print("{s}:\n", .{self.options.commands_title});

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
            try stdout.print("No commands available.\n", .{});
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

            try stdout.print("{s}:\n", .{section});

            std.sort.insertion(*Command, cmds.items, {}, struct {
                pub fn lessThan(_: void, a: *Command, b: *Command) bool {
                    return std.mem.order(u8, a.options.name, b.options.name) == .lt;
                }
            }.lessThan);

            try printAlignedCommands(cmds.items);
            try stdout.print("\n", .{});
        }
    }

    pub fn listFlags(self: *const Command) !void {
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

    fn checkDeprecated(self: *const Command) !void {
        if (self.options.deprecated) {
            if (self.options.version) |version| {
                try stdout.print("'{s}' v{} is deprecated\n", .{ self.options.name, version });
            } else {
                try stdout.print("'{s}' is deprecated\n", .{self.options.name});
            }

            if (self.options.replaced_by) |new_cmd_name| {
                try stdout.print("\nUse '{s}' instead.\n", .{new_cmd_name});
            }

            if (self.parent) |parent| {
                try stdout.print("\nRun '{s} [command] --help' for more information about a command.\n", .{parent.options.name});
            }

            std.process.exit(1);
        }
    }

    pub fn showInfo(self: *const Command) !void {
        try stdout.print("{s}{s}{s}\n", .{ styles.BOLD, self.options.description, styles.RESET });
        if (self.options.version) |version| try stdout.print("{s}v{}{s}\n", .{ styles.DIM, version, styles.RESET });
    }

    pub fn showVersion(self: *const Command) !void {
        if (self.options.version) |version| try stdout.print("{}\n", .{version});
    }

    pub fn printHelp(self: *Command) !void {
        try self.checkDeprecated();
        if (!self.options.deprecated) {
            try self.showInfo();
            try stdout.print("\n", .{});

            if (self.options.help) |help| {
                try stdout.print("{s}\n\n", .{help});
            }

            const parents = try self.getParents(self.allocator);
            defer parents.deinit();

            // Usage
            if (self.options.usage) |usage| {
                try stdout.print("Usage: {s}\n", .{usage});
            } else {
                try stdout.print("Usage: ", .{});
                for (parents.items) |p| {
                    try stdout.print("{s} ", .{p.options.name});
                }
                try stdout.print("{s} [options]\n", .{self.options.name});
            }

            try stdout.print("\n", .{});

            try self.listCommands();
            try stdout.print("\n", .{});

            try self.listFlags();
            if (self.flags.count() > 0) try stdout.print("\n", .{});

            try stdout.print("Run: '", .{});
            for (parents.items) |p| {
                try stdout.print("{s} ", .{p.options.name});
            }
            try stdout.print("{s} [command] --help'\n", .{self.options.name});
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

    pub fn getBoolValue(self: *const Command, flag_name: []const u8) bool {
        if (self.flag_values.get(flag_name)) |value_str| {
            return std.mem.eql(u8, value_str, "true");
        } else if (self.flags.get(flag_name)) |flag| {
            return flag.default_value == .Bool and flag.default_value.Bool;
        }
        return false; // Default to false if flag doesn't exist
    }

    pub fn getIntValue(self: *const Command, flag_name: []const u8) i32 {
        if (self.flag_values.get(flag_name)) |value_str| {
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

    pub fn getStringValue(self: *const Command, flag_name: []const u8) []const u8 {
        if (self.flag_values.get(flag_name)) |value_str| {
            return value_str;
        }

        if (self.flags.get(flag_name)) |flag| {
            if (flag.default_value == .String) {
                return flag.default_value.String;
            }
        }

        return ""; // Default to empty string if flag doesn't exist
    }

    pub fn getOptionalStringValue(self: *const Command, flag_name: []const u8) ?[]const u8 {
        if (self.flag_values.get(flag_name)) |value_str| {
            return value_str;
        } else if (self.flags.get(flag_name)) |flag| {
            return if (flag.default_value == .String) flag.default_value.String else null;
        }
        return null; // Return null if flag doesn't exist
    }

    pub fn addCommand(self: *Command, command: *Command) !void {
        command.parent = self;
        try self.commands_by_name.put(command.options.name, command);
        if (command.options.shortcut) |shortcut| try self.commands_by_shortcut.put(shortcut, command);
    }

    pub fn addCommands(self: *Command, commands: []const *Command) !void {
        for (commands) |cmd| try self.addCommand(cmd);
    }

    pub fn addPositionalArg(self: *Command, pos_arg: PositionalArg) !void {
        if (self.positional_args.items.len > 0) {
            const last_arg = self.positional_args.items[self.positional_args.items.len - 1];
            if (last_arg.variadic) {
                try stderr.print("Variadic args should only appear at the end.\n", .{});
                std.process.exit(1);
            }
        }
        try self.positional_args.append(pos_arg);
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

        try self.flag_values.put(flag.name, default_value);
    }

    pub fn addFlags(self: *Command, flags: []const Flag) !void {
        for (flags) |flag| {
            try self.addFlag(flag);
        }
    }

    // Improved parseFlags with better error handling
    fn parseFlags(self: *Command, args: []const []const u8) !void {
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
                        try printError(err, name, value);
                        return err;
                    };
                } else {
                    // Regular --flag [value] format
                    self.handleFlag(flag_name, args, &i) catch |err| {
                        try printError(err, flag_name, null);
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
                                try self.flag_values.put(flag.name, args[i + 1]);
                                i += 1;
                            } else {
                                try stderr.print("Error: Missing value for shorthand flag -{c}\n", .{shortcut_char});
                                try stderr.print("Flag '{s}' requires a {s} value\n", .{ flag.name, @tagName(flag.flag_type) });
                                return error.MissingValueForFlag;
                            }
                        } else {
                            // Boolean shorthand flags default to true
                            if (flag.flag_type == .Bool) {
                                try self.flag_values.put(flag.name, "true");
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

        try self.flag_values.put(flag_name, value);
    }

    // Helper function to handle flags in the flag=value format
    fn handleFlagValue(self: *Command, flag_name: []const u8, value: []const u8) !void {
        const def_flag = self.flags.get(flag_name) orelse return error.UnknownFlag;
        try validateValue(def_flag, value);
        try self.flag_values.put(flag_name, value);
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

    pub fn findCommand(self: *const Command, name_or_shortcut: []const u8) ?*Command {
        if (self.commands_by_name.get(name_or_shortcut)) |cmd| return cmd;
        if (self.commands_by_shortcut.get(name_or_shortcut)) |cmd| return cmd;
        return null;
    }

    fn findLeaf(self: *Command, args: *std.ArrayList([]const u8)) !*Command {
        var current = self;
        while (args.items.len > 0 and !std.mem.startsWith(u8, args.items[0], "-")) {
            const name = args.items[0];
            const next = current.findCommand(name) orelse {
                try stderr.print("Error: Unknown command '{s}'\n", .{name});
                const parents = try current.getParents(self.allocator);
                defer parents.deinit();

                try stderr.print("\nRun: '", .{});
                for (parents.items) |p| {
                    try stderr.print("{s} ", .{p.options.name});
                }
                try stderr.print("{s} [command] --help'\n", .{current.options.name});
                std.process.exit(1);
            };
            _ = try popFront([]const u8, args);
            current = next;
        }
        return current;
    }

    pub fn execute(self: *Command) !void {
        var bw = std.io.bufferedWriter(stdout);
        defer bw.flush() catch {};
        var input = std.process.args();
        _ = input.skip(); // skip program name

        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();
        while (input.next()) |arg| {
            try args.append(arg);
        }

        var cmd = try self.findLeaf(&args);

        if (args.items.len > 0 and
            (std.mem.eql(u8, args.items[0], "--help") or std.mem.eql(u8, args.items[0], "-h")))
        {
            try cmd.printHelp();
            return;
        }

        try cmd.checkDeprecated();

        cmd.parseFlags(args.items) catch {
            const parents = try cmd.getParents(self.allocator);
            defer parents.deinit();

            try stderr.print("\nRun: '", .{});
            for (parents.items) |p| {
                try stderr.print("{s} ", .{p.options.name});
            }
            try stderr.print("{s} [command] --help'\n", .{cmd.options.name});
            std.process.exit(1);
        };

        // try cmd.parsePositionalArgs(&args);

        const root = self;
        const ctx = CommandContext{
            .root = root,
            .direct_parent = cmd.parent orelse root,
            .command = cmd,
            .allocator = cmd.allocator,
        };

        try cmd.execFn(ctx);
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

// Print a human-friendly error message for flag errors
fn printError(err: anyerror, flag_name: []const u8, value: ?[]const u8) !void {
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

// fn println(comptime fmt: []const u8, args: anytype) !void {
//     try stdout.print(fmt, args);
//     try bw.flush();
// }
