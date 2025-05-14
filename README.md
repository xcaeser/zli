# zli

A **blazing fast**, zero-cost-abstraction command-line interface (CLI) framework for Zig, inspired by Go's Cobra and Rust's clap. Build robust, ergonomic, and highly-performant CLI apps with ease.

Written fully in Zig.

[![Version](https://img.shields.io/badge/Zig_Version-0.14.0-orange.svg?logo=zig)](README.md)
[![MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)

## 🚀 Why zli?

- **Ultra-performant**: Minimal allocations, zero hidden costs, and native Zig speed.
- **Modular**: Organize commands in a `cli/` folder, with a `root.zig` as your entrypoint.
- **Type-safe flag parsing**: Booleans, ints, strings, with default values and shortcuts.
- **Automatic help/version**: Built-in help and semantic versioning.
- **Colorful, user-friendly output**: Styled errors and help for a great UX.
- **Extensible**: Add commands and flags with minimal boilerplate.

## ✅ Features

- Command/subcommand structure
- Advanced flag parsing (bool, int, string)
- Default values and shortcuts
- Automatic help and usage generation
- Semantic versioning
- Styled output (with terminal support)
- Clear, actionable error messages

## 🏎️ Usage

### Project Structure (Cobra-style)

```
your-app/
├── src/
│   └── cli/
│       ├── root.zig       # CLI builder and command registration
│       ├── start.zig      # Example command
│       └── version.zig    # Version command
├── main.zig
└── build.zig
```

### Example: `src/cli/root.zig`

```zig
const std = @import("std");
const zli = @import("zli");
const start_cmd = @import("start.zig");
const version_cmd = @import("version.zig");

pub fn build(allocator: std.mem.Allocator) !zli.Builder {
    var root = try zli.Builder.init(allocator, .{
        .name = "blitz",
        .description = "Blitz: a blazing fast CLI app.",
        .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
        // other options...
    });

    try root.addCommands(&.{
        try start_cmd.register(&root),
        try version_cmd.register(&root),
    });

    return root;
}
```

### Example: Adding a Command (`src/cli/start.zig`)

```zig
const std = @import("std");
const zli = @import("zli");

const options: zli.CommandOptions = .{
    .name = "start",
    .description = "Start the blitz instance",
    .section = .Access,
};

pub fn register(zli_builder: *zli.Builder) !zli.Command {
    var cmd = try zli.Command.init(
        zli_builder.allocator,
        options,
        runCommand,
    );

    try cmd.addFlags(&.{
        nowFlag,
        ttlFlag,
    });

    return cmd;
}

fn runCommand(ctx: zli.CommandContext) !void {
    const now = ctx.command.getBoolValue("now");
    const ttl = ctx.command.getIntValue("ttl");
    std.debug.print("The things: {} and {d}\\n", .{ now, ttl });

    // Do anything you want here
    // e.g. start a server, run a task, etc.
    // ctx.command.printHelp() to print help for this command
}

const nowFlag = zli.Flag{
    .name = "now",
    .shortcut = "n",
    .description = "Forces to start now",
    .flag_type = .Bool,
    .default_value = .{ .Bool = true },
};

const ttlFlag = zli.Flag{
    .name = "ttl",
    .shortcut = "t",
    .description = "Time to live",
    .flag_type = .Int,
    .default_value = .{ .Int = 22 },
};
```

### Example: `src/main.zig`

```zig
const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var blitz_cli = try cli.build(allocator);
    defer blitz_cli.deinit();
    try blitz_cli.execute();
}
```

### 🖥️ CLI Example

```sh
$ blitz start --now=false --ttl 60 # both flag styles work  '=' and ' '
The things: false and 60

$ blitz version
1.0.0

$ blitz --help # or -h. you can even use many shorthands -abc
Blitz: a blazing fast CLI app.
v1.0.0

Available commands:
   start      Start the blitz instance
   version    Blitz's current installed version

Use 'blitz [command] --help' for more information about a command.
```

## 📦 Installation

**Option 1: `zig fetch`**

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v1.0.0.tar.gz
```

**Option 2: `build.zig.zon`**

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zli = .{
            .url = "https://github.com/xcaeser/zli/archive/v1.0.0.tar.gz",
            .hash = "...", // zig's suggested hash
        },
    },
}
```

**Add to `build.zig`**

```zig
const zli_dep = b.dependency("zli", .{ .target = target, .optimize = optimize });

exe.root_module.addImport("zli", zli_dep.module("zli"));
```

## 📚 API Summary

| Signature                                                                     | Description                             |
| ----------------------------------------------------------------------------- | --------------------------------------- |
| `fn build(allocator: std.mem.Allocator) !Builder`                             | Create a new CLI builder                |
| `fn Builder.addCommands(self: *Builder, cmds: []const Command) !void`         | Register multiple commands              |
| `fn Command.addFlag(self: *Command, flag: Flag) !void`                        | Add a flag to a command                 |
| `fn Command.getBoolValue(self: *Command, flag_name: []const u8) bool`         | Get a boolean flag value                |
| `fn Command.getIntValue(self: *Command, flag_name: []const u8) i32`           | Get an integer flag value               |
| `fn Command.getStringValue(self: *Command, flag_name: []const u8) []const u8` | Get a string flag value                 |
| `fn Builder.execute(self: *Builder) !void`                                    | Parse args and run the selected command |
| `fn Command.printHelp(self: *const Command) !void`                            | Print help for a command                |

## 🤝 Contributing

Issues and pull requests are welcome! Please open an issue for bugs, feature requests, or questions.

## 📝 License

MIT
