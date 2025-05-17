# 📘 zli Documentation

## 📑 Table of Contents

- [📘 zli Documentation](#-zli-documentation)
  - [📑 Table of Contents](#-table-of-contents)
  - [📦 Installation](#-installation)
  - [⚙️ General Design](#️-general-design)
  - [🛠️ Command (`zli.Command`)](#️-command-zlicommand)
  - [📂 CommandOptions](#-commandoptions)
  - [🧭 CommandContext](#-commandcontext)
  - [🏷️ Flag](#️-flag)
  - [✅ Flag Parsing](#-flag-parsing)
  - [📈 Positional Args](#-positional-args)
  - [📎 Tips](#-tips)
  - [🧪 Full Example (Blitz CLI)](#-full-example-blitz-cli)

---

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.1.4.tar.gz
```

Add this in your `build.zig`:

```zig
const zli_dep = b.dependency("zli", .{ .target = target });
exe.root_module.addImport("zli", zli_dep.module("zli"));
```

---

## ⚙️ General Design

`zli` is built around a modular, command-centric design. Unlike libraries that rely heavily on a global builder pattern, `zli` empowers each `Command` to be a self-contained unit.

Key principles:

- **Commands are Central**: The `zli.Command` struct is the primary building block. Each command defines its own behavior, options, flags, and subcommands.
- **Modularity**: Commands can be defined in separate files and composed together to build complex CLI structures. This promotes better organization and reusability.
- **Explicit Configuration**: Command properties (like name, description, flags) are set directly on the `Command` or through its `CommandOptions`.
- **Execution Logic (`execFn`)**: Each command has an associated function (`execFn`) that is executed when the command is invoked. This function receives a `CommandContext` providing access to parsed values and CLI state.
- **Flexibility**: You can call the `register` or `execFn` functions anything you like as long as their signatures match (e.g. `(ctx: CommandContext) !void`).
- **Performance**: Designed with performance in mind, minimizing allocations and leveraging efficient data structures like hash maps for command and flag resolution.

You have full flexibility: your `register` functions can be named anything (`register`, `initCommand`, etc.), and so can your `execFn` handlers (`run`, `execute`, etc.)—as long as they match the required signature:

```zig
fn(ctx: CommandContext) !void
```

This keeps the API ergonomic and idiomatic Zig.

---

## 🛠️ Command (`zli.Command`)

The `zli.Command` struct represents a command in your CLI application. It holds all information related to a command, including its options, flags, subcommands, and the function to execute.

```zig
const Command = struct {
    options: CommandOptions, // Required metadata (name, description, etc.)
    flags: std.StringHashMap(Flag), // All registered flags
    values: std.StringHashMap([]const u8), // Parsed values for flags
    positional_args: std.ArrayList(PositionalArg), // Ordered positional arguments
    execFn: ExecFn, // Main logic function to run the command
    commands_by_name: std.StringHashMap(*Command), // Fast lookup by name
    commands_by_shortcut: std.StringHashMap(*Command), // Fast lookup by shortcut
    parent: ?*Command = null, // Set automatically when added to another command
    allocator: std.mem.Allocator, // Memory allocator
};
```

📌 Creating a command:

```zig
const runCmd = try Command.init(allocator, .{
    .name = "run",
    .description = "Run something",
}, myRunFn);
```

📌 Adding a command:

```zig
try root.addCommand(runCmd);
```

📌 Adding multiple commands:

```zig
try root.addCommands(&.{ runCmd, anotherCmd });
```

📌 Executing the command:

```zig
try root.execute();
```

---

## 📂 CommandOptions

Holds metadata for a command. Passed when calling `Command.init(...)`.

```zig
const CommandOptions = struct {
    section: ?Section = .Usage,
    name: []const u8, // Required: command name
    description: []const u8, // Required: full description for help
    version: ?std.SemanticVersion = null, // Optional: version printed with --version
    commands_title: []const u8 = "Available commands", // You can customize the title for the commands section however you like
    shortcut: ?[]const u8 = null, // Optional: alias (e.g. 'v' for 'version')
    short_description: ?[]const u8 = null,
    help: ?[]const u8 = null, // Optional: long help text
    usage: ?[]const u8 = null, // Optional: usage override
    deprecated: bool = false,
    replaced_by: ?[]const u8 = null,
};
```

📌 Example:

```zig
const options: CommandOptions = .{
    .name = "version",
    .description = "Display CLI version",
    .shortcut = "v",
    .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
    .commands_title = "Here's what you can do",
    // more options...
};
```

---

## 🧭 CommandContext

💡 `CommandContext` is extremely powerful: it encapsulates the runtime state and gives you access to parsed flag values, command hierarchy, and more.

Your command's logic function can be named anything—`run`, `handle`, `show`, etc.—as long as it respects this exact signature:

```zig
fn(ctx: CommandContext) !void
```

This gives you full freedom to structure your command modules however you want.

Passed to your command's `execFn`. Provides structured access to the CLI state.

```zig
const CommandContext = struct {
    root: *const Command, // The root command in the CLI tree
    direct_parent: *const Command, // Parent of the currently executing command
    command: *const Command, // The actual command being executed
    allocator: std.mem.Allocator,
    env: ?std.process.EnvMap = null,
    stdin: ?std.fs.File = null,
};
```

📌 Example:

```zig
fn run(ctx: CommandContext) !void { // Call this whatever you want
    std.debug.print("Running {s}\n", .{ctx.command.options.name});
}
```

And when you ini the command:

```zig
const runCmd = try Command.init(
    allocator,
    .{
        .name = "run",
        .description = "Run something",
    },
    run, // <- this is your function
);
```

---

## 🏷️ Flag

Use flags to define options for your CLI command. Supports bool, int, string with default value.

````zig
const Flag = struct {
    name: []const u8, // Required: --flag-name
    shortcut: ?[]const u8 = null, // Optional: -f
    description: []const u8,
    flag_type: FlagType,
    default_value: union(FlagType) {
        Bool: bool,
        Int: i32,
        String: []const u8,
    },
};


📌 Example:

```zig
const debugFlag = Flag{
    .name = "debug",
    .description = "Enable debug output",
    .flag_type = .Bool,
    .default_value = .{ .Bool = false },
};
````

📌 Adding a flag:

```zig
try cmd.addFlag(debugFlag);
```

---

## ✅ Flag Parsing

Get values via:

```zig
ctx.command.getBoolValue("debug");
ctx.command.getIntValue("ttl");
ctx.command.getStringValue("path");
ctx.command.getOptionalStringValue("maybe");
```

You can use either `--flag value` or `--flag=value`. Boolean flags default to `true` if no value is provided.

Shorthand flags like `-d -p value` or `-dpvalue` are also supported.

---

## 📈 Positional Args

Define args:

```zig
try cmd.addPositionalArg(.{
    .name = "input",
    .description = "Path to input file",
    .required = true,
});
```

To parse, implement in your `execFn` logic (API still evolving).

---

## 📎 Tips

- Use `printHelp()` to show full help. Other functions like `listCommands()` are also available.
- Mark commands deprecated with `deprecated: true`.
- Add `version` in `CommandOptions` to get `--version` for free.

---

## 🧪 Full Example (Blitz CLI)

```zig
// src/main.zig
const std = @import("std");
const root = @import("cli/root.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var cli = try root.build(allocator);
    defer cli.deinit();

    try cli.execute();
}
```

```zig
// src/cli/root.zig
const std = @import("std");
const zli = @import("zli");

const run = @import("run.zig");
const version = @import("version.zig");

pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    var root = try zli.Command.init(allocator, .{
        .name = "blitz",
        .description = "Your dev toolkit CLI",
        .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
    }, onRun);

    try root.addCommands(&.{
        try run.register(allocator),
        try version.register(allocator),
    });

    return root;
}

fn onRun(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}
```

```zig
// src/cli/version.zig
const std = @import("std");
const zli = @import("zli");

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    return zli.Command.init(allocator, .{
        .name = "version",
        .shortcut = "v",
        .description = "Show CLI version",
    }, show);
}

fn show(ctx: zli.CommandContext) !void {
    if (ctx.root.options.version) |v| {
        std.debug.print("{}\n", .{v});
    }
}
```

```zig
// src/cli/run.zig
const std = @import("std");
const zli = @import("zli");

const now_flag = zli.Flag{
    .name = "now",
    .shortcut = "n",
    .description = "Run immediately",
    .flag_type = .Bool,
    .default_value = .{ .Bool = false },
};

const ttl_flag = zli.Flag{
    .name = "ttl",
    .shortcut = "t",
    .description = "Time to live in seconds",
    .flag_type = .Int,
    .default_value = .{ .Int = 10 },
};

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const run_cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run the blitz engine",
    }, run);

    // Add reusable flags
    try run_cmd.addFlags(&.{ now_flag, ttl_flag });

    // Subcommand example
    const test_cmd = try zli.Command.init(allocator, .{
        .name = "test",
        .description = "Run tests after execution",
    }, test);

    try run_cmd.addCommand(test_cmd);

    return run_cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const now = ctx.command.getBoolValue("now");
    const ttl = ctx.command.getIntValue("ttl");
    std.debug.print("[run] now={}, ttl={}
", .{now, ttl});
}

fn test(ctx: zli.CommandContext) !void {
    std.debug.print("[run test] Running post-run tests...
", .{});
}
```

---

Happy hacking! ✨
