# 📘 zli Documentation

## 📑 Table of Contents

- [📘 zli Documentation](#-zli-documentation)
  - [📑 Table of Contents](#-table-of-contents)
  - [📦 Installation](#-installation)
  - [⚙️ General Design](#️-general-design)
  - [✅ Features Checklist](#-features-checklist)
  - [🛠️ Command (`zli.Command`)](#️-command-zlicommand)
  - [📂 CommandOptions](#-commandoptions)
  - [🧭 CommandContext](#-commandcontext)
  - [🏷️ Flag (`zli.Flag`)](#️-flag-zliflag)
  - [🇺 FlagValue (`zli.FlagValue`)](#-flagvalue-zliflagvalue)
  - [✅ Flag Parsing](#-flag-parsing)
  - [📈 Positional Args (`zli.PositionalArg`)](#-positional-args-zlipositionalarg)
  - [📎 General Tips](#-general-tips)
  - [🧪 Full Example (Composable Blitz CLI)](#-full-example-composable-blitz-cli)
    - [`src/main.zig`](#srcmainzig)
    - [`src/cli/root.zig`](#srcclirootzig)
    - [`src/cli/run.zig`](#srcclirunzig)
    - [`src/cli/version.zig`](#srccliversionzig)

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.3.1.tar.gz
```

**Note:** Please update the version in the URL above if `v3.3.1` is no longer the correct version for the described API changes.

Add this in your `build.zig`:

```zig
const zli_dep = b.dependency("zli", .{ .target = target });
exe.root_module.addImport("zli", zli_dep.module("zli"));
```

## ⚙️ General Design

`zli` is built around a modular, command-centric design. Unlike libraries that rely heavily on a global builder pattern, `zli` empowers each `Command` to be a self-contained unit.

## ✅ Features Checklist

- [x] Commands & subcommands
- [x] Flags & shorthands
- [x] Type-safe flag values
- [x] Help/version auto handling
- [x] Deprecation notices
- [x] Positional args

Key principles:

- **Commands are Central**: The `zli.Command` struct is the primary building block. Each command defines its own behavior, options, flags, and subcommands.
- **Modularity**: Commands can be defined in separate files and composed together to build complex CLI structures. This promotes better organization and reusability.
- **Explicit Configuration**: Command properties (like name, description, flags) are set directly on the `Command` or through its `CommandOptions`.
- **Execution Logic (`execFn`)**: Each command has an associated function (`execFn`) that is executed when the command is invoked. This function receives a `CommandContext` providing access to parsed values and CLI state.
- **Flexibility**: You can call the `register` or `execFn` functions anything you like as long as their signatures match (e.g. `(ctx: CommandContext) !void`).
- **Performance**: Designed with performance in mind, minimizing allocations and leveraging efficient data structures like hash maps for command and flag resolution (e.g., `flags_by_name`, `flags_by_shortcut`).

You have full flexibility: your `register` functions can be named anything (`register`, `initCommand`, etc.), and so can your `execFn` handlers (`run`, `execute`, etc.)—as long as they match the required signature:

```zig
fn(ctx: zli.CommandContext) !void
```

This keeps the API ergonomic and idiomatic Zig.

## 🛠️ Command (`zli.Command`)

The `zli.Command` struct represents a command in your CLI application. It holds all information related to a command, including its options, flags, subcommands, and the function to execute.

```zig
const Command = struct {
    options: CommandOptions, // Required metadata (name, description, etc.)

    flags_by_name: std.StringHashMap(Flag), // Flags registered by their full name (e.g., --verbose)
    flags_by_shortcut: std.StringHashMap(Flag), // Flags registered by their shortcut (e.g., -v)
    flag_values: std.StringHashMap(FlagValue), // Parsed or default values for flags

    positional_args: std.ArrayList(PositionalArg), // Ordered positional arguments

    execFn: ExecFn, // Main logic function to run the command

    commands_by_name: std.StringHashMap(*Command), // Subcommands, lookup by name
    commands_by_shortcut: std.StringHashMap(*Command), // Subcommands, lookup by shortcut

    parent: ?*Command = null, // Set automatically when added to another command
    allocator: std.mem.Allocator, // Memory allocator
    stdout: std.io.Writer, // Writer for standard output, defaults to std.io.getStdOut().writer()
    stderr: std.io.Writer, // Writer for standard error, defaults to std.io.getStdErr().writer()
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
// try to add in alphabetical order if u have a lot of commands, however, this is not required. they will be sorted automatically
try root.addCommands(&.{ runCmd, anotherCmd });
```

📌 Executing the command:

```zig
try root_command.execute(.{}); // pass any data you want to the command .{.data = &my_data}
```

## 📂 CommandOptions

Holds metadata for a command. Passed when calling `Command.init(...)`.

```zig
const CommandOptions = struct {
    section_title: []const u8 = "General", // Title for grouping commands in help, e.g., "General", "Build Commands"
    name: []const u8, // Required: command name
    description: []const u8, // Required: full description for help
    version: ?std.SemanticVersion = null, // Optional: version printed with --version
    commands_title: []const u8 = "Available commands", // Title for the subcommands list in help
    shortcut: ?[]const u8 = null, // Optional: alias (e.g. 'v' for 'version')
    short_description: ?[]const u8 = null, // Optional: shorter description for command listings
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
    .section_title = "Information", // Group this command under "Information"
    .shortcut = "v",
    .version = std.SemanticVersion.parse("1.0.0") catch unreachable,
    .commands_title = "Sub-tasks for versioning", // If it had subcommands
    // more options...
};
```

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
    command: *Command, // The actual command being executed, u can access its flags and options and anything else
    allocator: std.mem.Allocator,
    data: ?*anyopaque = null, // Optional: user-defined data pointer
};
```

📌 Example:

```zig
fn run(ctx: CommandContext) !void { // Call this whatever you want
    // Use ctx.flag() to get typed flag values (see Flag Parsing section)
    const debug_mode = ctx.flag("debug", bool);
    const retries = ctx.flag("retries", i32);
    const username = ctx.flag("user", []const u8);

    std.debug.print("Running {s}\n", .{ctx.command.options.name});
    if (debug_mode) {
        std.debug.print("Debug mode enabled. Retries: {}, User: {s}\n", .{ retries, username });
    }

    // Accessing context data
    const data_ptr = ctx.getContextData(comptime T); // Get a pointer to user-defined data
}
```

And when you init the command:

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

## 🏷️ Flag (`zli.Flag`)

Use flags to define options for your CLI command. Supports bool, int, string with a default value.

```zig
const Flag = struct {
    name: []const u8, // Required: --flag-name
    shortcut: ?[]const u8 = null, // Optional: -f
    description: []const u8,
    type: FlagType, // The type of the flag (.Bool, .Int, .String)
    default_value: FlagValue, // The default value, must match 'type'
};
```

`FlagType` is an enum:

```zig
pub const FlagType = enum {
    Bool,
    Int,
    String,
};
```

See the next section for `FlagValue`.

📌 Example:

```zig
const debugFlag = Flag{
    .name = "debug",
    .shortcut = "d",
    .description = "Enable debug output",
    .type = .Bool, // Note: field name is 'type'
    .default_value = .{ .Bool = false }, // Value is a FlagValue
};

const portFlag = Flag{
    .name = "port",
    .description = "Port number to listen on",
    .type = .Int,
    .default_value = .{ .Int = 8080 },
};

const configFileFlag = Flag{
    .name = "config",
    .shortcut = "c",
    .description = "Path to configuration file",
    .type = .String,
    .default_value = .{ .String = "config.json" },
};
```

📌 Adding a flag:

```zig
try cmd.addFlag(debugFlag);
try cmd.addFlags(&.{ portFlag, configFileFlag });
```

Flags are registered by both their name and shortcut (if provided) for efficient lookup.

## 🇺 FlagValue (`zli.FlagValue`)

`FlagValue` is a union that holds the actual value for a flag. It's used for `Flag.default_value` and internally for storing parsed flag values.

```zig
pub const FlagValue = union(FlagType) {
    Bool: bool,
    Int: i32,
    String: []const u8,
};
```

When defining a `Flag`, the `default_value` field must be a `FlagValue` that corresponds to the `Flag.type`.

Example:

- If `Flag.type` is `.Bool`, then `Flag.default_value` must be `.{ .Bool = true }` or `.{ .Bool = false }`.
- If `Flag.type` is `.Int`, then `Flag.default_value` must be `.{ .Int = 123 }`.
- If `Flag.type` is `.String`, then `Flag.default_value` must be `.{ .String = "hello" }`.

## ✅ Flag Parsing

Flag values are accessed in your `execFn` via the `ctx.flag()` method on `CommandContext`. This method is type-safe and convenient.

```zig
fn myCommandFn(ctx: CommandContext) !void {
    // For a flag defined as:
    // const debugFlag = Flag{ .name = "debug", .type = .Bool, .default_value = .{ .Bool = false } };
    const is_debug_enabled: bool = ctx.flag("debug", bool);

    // const countFlag = Flag{ .name = "count", .type = .Int, .default_value = .{ .Int = 0 } };
    const retry_count: i32 = ctx.flag("count", i32);

    // const nameFlag = Flag{ .name = "name", .type = .String, .default_value = .{ .String = "" } };
    const user_name: []const u8 = ctx.flag("name", []const u8);

    std.debug.print("Debug: {}, Count: {}, Name: {s}\n", .{is_debug_enabled, retry_count, user_name});
}
```

The `ctx.flag(flag_name, DesiredType)` method:

- Takes the flag name (long name) and the expected `comptime` type (e.g., `bool`, `i32`, `[]const u8`).
- Returns the parsed value if the flag was provided by the user.
- If the flag was not provided, it returns the `default_value` specified in the `Flag` definition.
- If the flag name is unknown or the types are mismatched in definition (which should be caught by `zli`'s internal logic or setup), `ctx.flag` will fall back to a default for the `DesiredType` (e.g., `false` for `bool`, `0` for integers, `""` for `[]const u8`). Robust flag definition ensures this fallback is rarely hit.

Supported syntaxes:

- Long flags: `--myflag value`, `--myflag=value`
- Boolean long flags: `--enable-feature` (implies true), `--enable-feature=true`, `--enable-feature=false`
- Short flags: `-s value`, `-svalue` (for non-booleans, value cannot be part of the same argument if other shorthands are combined, e.g., `-abc value_for_c` not `-abcvalue_for_c`).
- Combined short boolean flags: `-abc` (implies `-a`, `-b`, `-c` are all true, assuming they are boolean flags).

`zli` handles parsing errors (e.g., invalid value for type, unknown flag) by printing an error message and exiting.

## 📈 Positional Args (`zli.PositionalArg`)

Define positional arguments for your command.

```zig
pub const PositionalArg = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
    variadic: bool = false, // If true, this arg can consume multiple remaining inputs
};
```

📌 Define args:

```zig
try cmd.addPositionalArg(.{
    .name = "input",
    .description = "Path to input file",
    .required = true,
});

try cmd.addPositionalArg(.{
    .name = "outputs",
    .description = "Path to output files",
    .required = false,
    .variadic = true,
});
```

> [!IMPORTANT]
>
> Parsing Positional Arguments:
> The current API for accessing parsed positional arguments within `execFn` is still evolving. For now, you would need to inspect `ctx.command.positional_args` and correlate them with the remaining unparsed arguments after flag parsing. `zli`'s `execute` function will handle basic validation like required arguments.
>
> _(Developer Note: The `parsePositionalArgs` function exists in the new code but is currently a stub. The documentation should reflect the user-facing way to access these once fully implemented)._

## 📎 General Tips

- **Help Messages**:
  - Use `cmd.printHelp()` to show the full, auto-generated help message for a command.
  - The help message includes description, usage, available subcommands (grouped by `section_title` from `CommandOptions`), and flags.
  - You can also call `cmd.listCommands()`, `cmd.listCommandsBySection()`, and `cmd.listFlags()` directly if you need finer-grained control over help output.
- **Deprecation**: Mark commands as deprecated using `deprecated: true` in `CommandOptions`. Optionally, specify `replaced_by` with the name of the new command. Accessing a deprecated command will print a warning and exit.
- **Automatic Version Flag**: Add a `version: std.SemanticVersion` to your root command's `CommandOptions` to automatically get a `--version` flag that prints the version and exits.
- **Section Titles for Commands**: Use `section_title` in `CommandOptions` for each command to group related commands under custom headings in the help output (via `listCommandsBySection`, which `printHelp` uses).
- **stdout/stderr**: The `Command` struct now has `stdout` and `stderr` writers, defaulting to the process's stdio. You can potentially replace these on a `Command` instance if you need to redirect output for testing or specific scenarios, though this is an advanced use case.

## 🧪 Full Example (Composable Blitz CLI)

This example will have the following file structure:

```
src/
├── main.zig
└── cli/
    ├── root.zig
    ├── run.zig
    └── version.zig
```

### `src/main.zig`

This is the entry point of your application. It sets up the allocator and orchestrates the CLI execution.

```zig
// src/main.zig
const std = @import("std");
const cli_builder = @import("cli/root.zig"); // Adjusted path

pub fn main() !void {

    const allocator = std.heap.smp_allocator;

    // Build the root command structure from our cli module
    const root_command = try cli_builder.build(allocator);
    defer root_command.deinit(); // Deinitialize the command tree

    // Execute the CLI. zli will parse arguments and run the appropriate command.
    try root_command.execute(.{}); // pass any data you want to the command .{.data = &my_data}
}
```

### `src/cli/root.zig`

This file defines the root command of your CLI ("blitz") and registers its subcommands.

```zig
// src/cli/root.zig
const std = @import("std");
const zli = @import("zli");

// Import subcommand modules
const run = @import("./run.zig");
const version = @import("./version.zig");

// This function constructs and returns the configured root command.
pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = "blitz",
        .description = "A composable Blitz CLI example for your development tasks.",
        .short_description = "Blitz dev toolkit.",
        // Set the version for the entire CLI application here
        .version = try std.SemanticVersion.parse("0.2.0"),
        .commands_title = "Core Commands", // Customize title for subcommands list
    }, rootExec); // The function to call if 'blitz' is run without subcommands

    // Register subcommands by calling their respective 'register' functions
    // try to add in alphabetical order if u have a lot of commands, however, this is not required. they will be sorted automatically
    try root.addCommands(&.{
        try run.register(allocator),
        try version.register(allocator),
    });

    return root;
}

// execFn for the root command.
// Called if 'blitz' is executed without any subcommands.
// A common behavior is to show the help message.
fn rootExec(ctx: zli.CommandContext) !void {
    // If the global verbose flag (if we had one on root) was set, we could print more.
    // const verbose = ctx.flag("verbose", bool); // Example if root had a --verbose
    // if (verbose) {
    //     try ctx.command.stdout.print("Blitz root command invoked verbosely.\n", .{});
    // }

    try ctx.command.stdout.print("Welcome to Blitz CLI! Available commands are listed below.\n\n", .{});
    try ctx.command.printHelp(); // Show detailed help for the root command
}
```

### `src/cli/run.zig`

This file defines the `run` subcommand, its flags, and its execution logic.

```zig
// src/cli/run.zig
const std = @import("std");
const zli = @import("zli");

// Define flags for the 'run' command
const now_flag = zli.Flag{
    .name = "now",
    .shortcut = "n",
    .description = "Run the workflow immediately without delay.",
    .type = .Bool, // Use .type instead of .flag_type
    .default_value = .{ .Bool = false }, // FlagValue union
};

const target_flag = zli.Flag{
    .name = "target",
    .shortcut = "t",
    .description = "Specify the target environment (e.g., dev, prod).",
    .type = .String,
    .default_value = .{ .String = "dev" },
};

// This function registers the 'run' command.
pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Simulates running a specific workflow or task.",
        .short_description = "Execute a workflow.",
        .section_title = "Workflow Management", // For grouping in help output if desired
        .usage = "blitz run [--now] [--target <env>] [workflow-name]",
    }, executeRun);

    try cmd.addFlags(&.{ now_flag, target_flag });

    // Example of adding a positional argument
    try cmd.addPositionalArg(.{
        .name = "workflow-name",
        .description = "The name of the workflow to run (optional).",
        .required = false,
    });

    return cmd;
}

// execFn for the 'run' command.
fn executeRun(ctx: zli.CommandContext) !void {
    // Access flag values using ctx.flag()
    const run_immediately = ctx.flag("now", bool);
    const target_env = ctx.flag("target", []const u8);

    try ctx.command.stdout.print("Executing 'run' command...\n", .{});
    try ctx.command.stdout.print("  Target environment: {s}\n", .{target_env});

    if (run_immediately) {
        try ctx.command.stdout.print("  Running immediately!\n", .{});
    } else {
        try ctx.command.stdout.print("  Scheduled to run (not immediate).\n", .{});
    }

    // Accessing positional arguments is still evolving in zli for direct typed access.
    // For now, you'd typically iterate over remaining args after flag parsing.
    // zli's internal `parsePositionalArgs` is called, but exposing them cleanly
    // to execFn like `ctx.positionalArg("workflow-name", []const u8)` is a future step.
    // Here's a placeholder for how you might indicate it:
    if (ctx.command.positional_args.items.len > 0) {
        // This indicates a positional argument was defined.
        // The actual *values* would be in the args remaining after flag parsing.
        // For this example, we'll just acknowledge its definition.
        // A real app would look at the remaining command line arguments.
        try ctx.command.stdout.print("  (Note: Positional argument 'workflow-name' can be specified.)\n", .{});
    }

    // You can access parent or root command context if needed:
    // if (ctx.root.options.version) |v| {
    //     try ctx.command.stdout.print("  (Running under Blitz CLI version: {})\n", .{v});
    // }
}
```

### `src/cli/version.zig`

This file defines the `version` subcommand.

```zig
// src/cli/version.zig
const std = @import("std");
const zli = @import("zli");

// This function registers the 'version' command.
pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    // The 'version' command typically doesn't have its own flags or subcommands.
    // Its primary purpose is to display the application's version.
    return zli.Command.init(allocator, .{
        .name = "version",
        .shortcut = "v", // Common shortcut for version
        .description = "Displays the version of the Blitz CLI.",
        .short_description = "Show CLI version.",
        .section_title = "Information", // Grouping in help
    }, showAppVersion);
}

// execFn for the 'version' command.
fn showAppVersion(ctx: zli.CommandContext) !void {
    // The version is typically stored in the root command's options.
    if (ctx.root.options.version) |app_version| {
        try ctx.command.stdout.print("{s} version {s}\n", .{
            ctx.root.options.name, // e.g., "blitz"
            @tagName(app_version), // This gets "0.2.0" from the SemanticVersion
        });
    } else {
        // This case should ideally not happen if version is set in root.zig
        try ctx.command.stdout.print("Version information is not available.\n", .{});
    }
}
```

**To use this example:**

1.  Save the files in the `src/` and `src/cli/` directories as shown.
2.  Ensure your `zli` library code (the `NEW CODE` you provided) is accessible (e.g., in a `lib/zli` directory or as a dependency your `build.zig` can find).
3.  Update your `build.zig` to compile `src/main.zig` and link/import `zli`.

This modular structure makes it much easier to manage larger CLIs, as each command's logic is self-contained.

Happy hacking! ✨
