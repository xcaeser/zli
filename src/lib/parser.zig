const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Command = @import("../zli.zig").Command;

const PType = enum {
    WORD, // Command, Value or Pos Arg
    LONG_FLAG,
    SHORT_FLAG,
    GROUP_FLAG,
    NEGATIVE_VALUE,
    NEGATED_FLAG,
};

const Program = struct {
    current_commmand: Command,
    options: ArrayList([]const u8),
    options_values: ArrayList(u8),
    positionals: ArrayList([]const u8),
    allocator: Allocator,
};

// cli run --flag value --bool --op=77 -p -abc xxxx yyyy zzzz
pub fn parse(cmd: *Command, args: *ArrayList([]const u8), argsIterator: *std.process.Args.Iterator) !void {
    _ = args; // autofix
    // std.debug.print("PARSING for {s} v{f}...\n", .{ cmd.cmd_options.name, cmd.cmd_options.version.? });

    const allocator = cmd.init_options.allocator;
    _ = allocator; // autofix

    const prog_name = argsIterator.next() orelse unreachable; // always the program name as first arg

    std.debug.print("PROGRAM NAME: {s}\n", .{prog_name});

    var is_flag: bool = false;

    const args_len = argsIterator.inner.remaining.len;
    _ = args_len; // autofix

    outer: while (argsIterator.next()) |arg| {
        const reverse_idx = argsIterator.inner.remaining.len;

        const arg_type = assessArgType(arg);
        std.debug.print("{d}. {s} : {s}\n", .{ reverse_idx, arg, @tagName(arg_type) });

        inner: switch (arg_type) {
            .WORD => {
                // assess if a command as long as next one is not flag type
                // if is_flag is true, we should stop looking for commands
                if (!is_flag) {
                    var current = cmd;
                    if (current.commands_by_name.count() == 0) {
                        if (current.positional_args.items.len == 0) {
                            try current.init_options.writer.print("Unknown command: '{s}'\n", .{arg});
                            try current.displayCommandError();
                            return error.UnknownCommand;
                        }
                    } else if (current.findCommand(arg)) |c| {
                        try current.init_options.writer.print("Found command: '{s}'\n", .{c.cmd_options.name});
                        continue :outer;
                    }
                }
                // assess if value if prev is flag

            },
            .NEGATIVE_VALUE => {},
            .LONG_FLAG => {
                is_flag = true;
            },
            .SHORT_FLAG => {
                // depends if flag is bool don't get next one, if not get it
                is_flag = true;
            },
            .GROUP_FLAG => {
                is_flag = true;
                // split into short flags array and handle with :argsw in a for loop
                break :inner;
            },
            .NEGATED_FLAG => {
                is_flag = true;
            },
        }
    }
}

fn assessArgType(arg: []const u8) PType {
    if (std.mem.startsWith(u8, arg, "--no-") and arg.len > "--no-".len) {
        return .NEGATED_FLAG;
    }

    if (std.mem.startsWith(u8, arg, "--") and arg.len > "--".len) {
        return .LONG_FLAG;
    }

    if (arg[0] != '-') return .WORD;

    if (std.fmt.parseInt(i32, arg, 10)) |_| {
        return .NEGATIVE_VALUE;
    } else |_| {}

    if (arg.len == 2) return .SHORT_FLAG;

    if (arg.len > 2 and arg[1] != '-') return .GROUP_FLAG;

    return .WORD;
}
