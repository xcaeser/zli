const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const Command = @import("../zli.zig").Command;

const PType = enum {
    WORD, // Command, Value or Pos Arg
    LONG_FLAG_WITH_VALUE,
    LONG_FLAG,
    SHORT_FLAG,
    GROUP_FLAG,
    // NEGATIVE_VALUE,
    NEGATED_FLAG,
};

// cli run --flag value --bool --op=77 -p -abc xxxx yyyy zzzz
pub fn parse(self: *Command, argsIterator: *std.process.Args.Iterator) !void {
    var current = self;

    const allocator = current.init_options.allocator;
    _ = allocator; // autofix

    const prog_name = argsIterator.next() orelse unreachable; // always the program name as first arg

    std.debug.print("PROGRAM NAME: {s}\n", .{prog_name});

    var is_flag: bool = false;
    const args_len = argsIterator.inner.remaining.len;

    outer: while (argsIterator.next()) |arg| {
        const reverse_idx = args_len - argsIterator.inner.remaining.len % args_len - 1;

        const arg_type = assessArgType(arg);
        std.debug.print("{d}. {s} : {s}\n", .{ reverse_idx, arg, @tagName(arg_type) });

        inner: switch (arg_type) {
            .WORD => {
                // assess if a command as long as next one is not flag type
                // if is_flag is true, we should stop looking for commands
                if (!is_flag) {
                    if (current.commands_by_name.count() == 0) {
                        if (current.positional_args.items.len == 0) {
                            try current.init_options.writer.print("Unknown command: '{s}'\n", .{arg});
                            try current.displayCommandError();
                            return error.UnknownCommand;
                        }
                    } else if (current.findCommand(arg)) |c| {
                        try current.init_options.writer.print("Found command: '{s}'\n", .{c.cmd_options.name});
                        current = c;
                        continue :outer;
                    }
                }
                // assess if value if prev is flag

            },
            .LONG_FLAG_WITH_VALUE => {
                try current.init_options.writer.print("Current command: '{s}'\n", .{current.cmd_options.name});
                is_flag = true;
                const idx = std.mem.find(u8, arg, "=") orelse unreachable;
                const flag_name = arg[0..idx];
                const value = arg[idx + 1 ..];

                const flag = current.findFlag(flag_name);

                if (flag == null) {
                    try current.init_options.writer.print("Unknown flag: --{s}\n", .{flag_name});
                    try current.displayCommandError();
                    try current.init_options.writer.flush();
                    std.process.exit(1);
                }

                const flag_value = flag.?.safeEvaluate(value) catch {
                    try current.init_options.writer.print("Invalid value for flag --{s}: '{s}'\n", .{ flag_name, value });
                    try current.init_options.writer.print("Expected a value of type: {s}\n", .{@tagName(flag.?.type)});
                    try current.displayCommandError();
                    try current.init_options.writer.flush();
                    std.process.exit(1);
                };
                try self.flag_values.put(flag.?.name, flag_value);
            },
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

    if (std.mem.startsWith(u8, arg, "--") and arg.len > "--".len and std.mem.find(u8, arg, "=") != null) {
        return .LONG_FLAG_WITH_VALUE;
    }

    if (std.mem.startsWith(u8, arg, "--") and arg.len > "--".len) {
        return .LONG_FLAG;
    }

    if (arg[0] != '-') return .WORD;

    if (std.fmt.parseInt(i32, arg, 10)) |_| {
        return .WORD;
    } else |_| {}

    if (arg.len == 2) return .SHORT_FLAG;

    if (arg.len > 2 and arg[1] != '-') return .GROUP_FLAG;

    return .WORD;
}
