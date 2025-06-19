# `zli` Documentation

**`zli`**: A blazing-fast, zero-cost CLI framework for Zig.

Welcome to the `zli` documentation! This guide will help you understand how to leverage `zli` to build modular, ergonomic, and high-performance Command Line Interfaces (CLIs) in Zig. Whether you're building a simple tool or a complex application suite, `zli` provides the batteries you need.

Inspired by giants like Cobra (Go) and clap (Rust), `zli` focuses on modularity, type safety, and developer experience.

## Table of Contents

- [`zli` Documentation](#zli-documentation)
  - [Table of Contents](#table-of-contents)
  - [🧠 Core Concepts](#-core-concepts)
    - [Command](#command)
    - [CommandContext](#commandcontext)
    - [Flag](#flag)
    - [PositionalArg](#positionalarg)
  - [🚀 Getting Started](#-getting-started)
    - [Installation](#installation)
    - [Suggested Project Structure](#suggested-project-structure)
  - [🛠 Building Your CLI: Step-by-Step](#-building-your-cli-step-by-step)
    - [1. The Main Application Entry Point (`src/main.zig`)](#1-the-main-application-entry-point-srcmainzig)
    - [2. Defining the Root Command (`src/cli/root.zig`)](#2-defining-the-root-command-srcclirootzig)
    - [3. Adding a Subcommand (`src/cli/run.zig`)](#3-adding-a-subcommand-srcclirunzig)
    - [4. Defining and Using Flags](#4-defining-and-using-flags)
    - [5. Defining and Using Positional Arguments](#5-defining-and-using-positional-arguments)
    - [6. A Simple Version Subcommand (`src/cli/version.zig`)](#6-a-simple-version-subcommand-srccliversionzig)
  - [✨ Features in Detail](#-features-in-detail)
    - [Automatic Help Messages](#automatic-help-messages)
    - [Version Handling](#version-handling)
    - [Type-Safe Flag Parsing](#type-safe-flag-parsing)
    - [Positional Arguments: Required, Optional, Variadic](#positional-arguments-required-optional-variadic)
    - [Passing Custom Data via `CommandContext`](#passing-custom-data-via-commandcontext)
    - [Deprecation Notices](#deprecation-notices)
  - [📝 Best Practices](#-best-practices)
    - [Modular Command Design](#modular-command-design)
    - [Error Handling](#error-handling)
    - [Allocator Management](#allocator-management)
  - [📖 API Quick Reference](#-api-quick-reference)
    - [`zli.Command`](#zlicommand)
    - [`zli.CommandOptions`](#zlicommandoptions)
    - [`zli.CommandContext`](#zlicommandcontext)
    - [`zli.Flag`](#zliflag)
    - [`zli.PositionalArg`](#zlipositionalarg)
  - [`zli.Spinner`](#zlispinner)
  - [🤝 Contributing](#-contributing)
  - [📜 License](#-license)

## 🧠 Core Concepts

Before writing commands, understand the three pillars of `zli`:

### Command

The core unit of behavior in `zli`. Each `Command` represents an action or a group of related actions (subcommands) that your CLI can perform.

- **`name`**: The string used to invoke the command (e.g., `mycli <name>`).
- **`description`**: A brief explanation of what the command does, shown in help messages.
- **`shortcut`**: (Optional) A shorter alias for the command name.
- **`subcommands`**: A `Command` can have child commands, forming a tree structure (e.g., `git remote add <name> <url>`).
- **`flags`**: Named arguments that modify a command's behavior (e.g., `--verbose`, `-f output.txt`).
- **`positional arguments`**: Unnamed arguments whose meaning is determined by their position (e.g., `cp <source> <destination>`).
- **`execFn`**: A Zig function that gets executed when the command is run. This is where your command's logic resides. It receives a `CommandContext`. If a command has subcommands, its `execFn` is typically only called if no subcommands are matched, often used to display help.

### CommandContext

Passed to every `execFn`, the `CommandContext` is your window into the CLI's state during execution. It provides:

- **`.flag("name", T) T`**: Accesses the value of a flag named `"name"`, parsed as type `T` (e.g., `bool`, `i64`, `[]const u8`). This is type-safe.
- **`.getArg("positional_name") ?[]const u8`**: Retrieves the value of a positional argument by its defined name. Returns `null` if the argument was not provided (and is optional).
- **`.command: *Command`**: A pointer to the `Command` instance that is currently being executed. Useful for accessing command-specific options or printing help.
- **`.root: *Command`**: A pointer to the root `Command` of your CLI. Useful for accessing global application settings like version.
- **`.allocator: std.mem.Allocator`**: The allocator used by `zli` for this command's execution. You can use this for any allocations within your `execFn`.
- **`.data: ?*anyopaque`**: A user-defined pointer that can be passed during `root.execute()` to share arbitrary data with all command functions.
- **`.stdin: std.fs.File.Reader`**, **`.stdout: std.fs.File.Writer`**, **`.stderr: std.fs.File.Writer`**: Standard I/O streams for interaction.

### Flag

Flags are named options that modify a command's behavior. `zli` supports common flag patterns:

- Boolean flags: `--verbose`, `-v`
- Value flags: `--output report.txt`, `--count=10`
- Shorthand clustering: `-abc` can be equivalent to `-a -b -c` if `a`, `b`, `c` are boolean flags.

Flags are defined with a `zli.Flag` struct:

- **`.name: []const u8`**: Full name of the flag (e.g., "verbose").
- **`.shortcut: []const u8`**: Single-character shorthand (e.g., "v").
- **`.description: []const u8`**: Help text for the flag.
- **`.type: zli.FlagType`**: The expected type of the flag's value (`.Bool`, `.Int`, `.String`).
- **`.default_value: zli.FlagValue`**: A default value if the flag is not provided by the user.

### PositionalArg

Positional arguments are values passed to a command after its name and flags, identified by their order.

- **`.name: []const u8`**: An internal name for the argument, used to retrieve its value via `ctx.getArg("name")`. This name is also used in help messages.
- **`.description: []const u8`**: Help text for the argument.
- **`.required: bool`**: If `true`, `zli` will (or you should check and) error if this argument is missing.
- **`.variadic: bool`**: If `true`, this argument can accept multiple values (e.g., `mycli process file1 file2 file3...`). A variadic argument must be the last positional argument. When accessed via `ctx.getArg()`, it will return the first value; subsequent values would typically be accessed via `ctx.args()` or a similar mechanism if `zli` directly supports it (check `CommandContext` fields or methods for raw argument access if needed for variadic handling beyond the first element). _Note: Specific handling for multiple variadic values might require accessing `ctx.command.args` or a similar field that holds parsed arguments directly._

## 🚀 Getting Started

### Installation

1.  Fetch `zli` as a dependency using Zig's package manager:

    ```sh
    zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.7.1.tar.gz
    ```

    (Replace `v3.7.1` with the desired version). This adds the dependency to your `build.zig.zon`.

2.  Add `zli` to your executable in `build.zig`:

    ```zig
    const std = @import("std");

    pub fn build(b: *std.Build) void {
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        const exe = b.addExecutable(.{
            .name = "your-app",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        // Add zli dependency
        const zli_dep = b.dependency("zli", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zli", zli_dep.module("zli"));

        b.installArtifact(exe);
        // ... rest of your build script
    }
    ```

### Suggested Project Structure

A modular structure keeps your CLI codebase organized:

```
your-app/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig       # Application entry point
│   └── cli/           # All CLI command definitions
│       ├── root.zig   # Root command definition
│       ├── cmd1.zig   # Definition for `cmd1`
│       └── cmd2.zig   # Definition for `cmd2`
```

- Each command typically resides in its own `.zig` file within a `cli` directory.
- `root.zig` defines the main application command and registers subcommands.

## 🛠 Building Your CLI: Step-by-Step

Let's build a simple CLI called `blitz` with a `run` subcommand.

### 1. The Main Application Entry Point (`src/main.zig`)

This file initializes and executes your root command.

```zig
// src/main.zig
const std = @import("std");
const cli_root = @import("cli/root.zig"); // Your root command definition

pub fn main() !void {
    // It's good practice to use a general-purpose allocator.
    // std.heap.page_allocator is also a common choice for CLIs.
    const allocator = std.heap.smp_allocator;

    // Build the command structure
    var root_command = try cli_root.build(allocator);
    defer root_command.deinit(); // Ensure all command resources are freed

    // Execute the command based on os.args
    // You can pass custom data here if needed:
    // try root_command.execute(.{ .data = &my_custom_data });
    try root_command.execute(.{});
}
```

_Key points:_

- An `allocator` is crucial for `zli` as it dynamically allocates memory for commands, flags, and arguments.
- `cli_root.build()` (which we'll define next) constructs your command tree. you can name build() fn however you want :).
- `root_command.deinit()` cleans up resources.
- `root_command.execute()` parses `std.os.args` and runs the appropriate command logic.

### 2. Defining the Root Command (`src/cli/root.zig`)

The root command is the entry point of your CLI application (e.g., `blitz`).

```zig
// src/cli/root.zig
const std = @import("std");
const zli = @import("zli");

// Forward declare or import subcommand modules
const run_cmd = @import("run.zig");
const version_cmd = @import("version.zig");

// This function will be called to construct the root command
pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = "blitz",
        .description = "A (fictional) dev toolkit CLI.",
        .version = "v1.0.0", // Optional: for auto --version flag or manual display
    },
    showHelp,
    ); // Default execFn if no subcommand is matched

    // Register subcommands
    try root.addCommands(&.{
        try run_cmd.register(allocator),
        try version_cmd.register(allocator),
    });

    return root;
}

// Default execution function for the root command (e.g., when `blitz` is run without subcommands)
fn showHelp(ctx: zli.CommandContext) !void {
    // Display the help message for the current command (root in this case)
    try ctx.command.printHelp();
}
```

_Key points:_

- `zli.Command.init()` creates a new command. It takes an allocator, `zli.CommandOptions`, and an execution function (`execFn`).
- `CommandOptions` include `.name`, `.description`, and optionally `.version`.
- `root.addCommands()` attaches subcommands. Each subcommand is also a `*zli.Command`.
- The `showHelp` function is a typical `execFn` for root commands, displaying usage information.

### 3. Adding a Subcommand (`src/cli/run.zig`)

Let's define the `blitz run` subcommand.

```zig
// src/cli/run.zig
const std = @import("std");
const zli = @import("zli");

// This function will be called by root.zig to get this command
pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run a specified workflow",
    },
    runWorkflow,
    ); // The function to execute for `blitz run`

    // We'll add flags and args in the next steps
    return cmd;
}

// The execution logic for the `run` command
fn runWorkflow(ctx: zli.CommandContext) !void {
    std.debug.print("Executing the run workflow...\n", .{});
    // Access flags and args using ctx, e.g.:
    // const verbose = ctx.flag("verbose", bool);
    // const script_name = ctx.getArg("script") orelse "default.script";
    // ...
}
```

_Key points:_

- Each subcommand module typically exports a `register` (or `build`) function that returns `!*zli.Command`.
- It defines its own `name`, `description`, and `execFn`.

### 4. Defining and Using Flags

Flags allow users to modify command behavior. Let's add a `--now` flag to the `run` command.

Modify `src/cli/run.zig`:

```zig
// src/cli/run.zig
const std = @import("std");
const zli = @import("zli");

const now_flag = zli.Flag{
    .name = "now",
    .shortcut = "n",
    .description = "Run the workflow immediately",
    .type = .Bool, // This is a boolean flag
    .default_value = .{ .Bool = false },
};

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run a specified workflow",
    }, runWorkflow);

    try cmd.addFlag(now_flag); // Add the flag to the command

    return cmd;
}

fn runWorkflow(ctx: zli.CommandContext) !void {
    // Access the flag value type-safely
    const run_immediately = ctx.flag("now", bool);

    if (run_immediately) {
        std.debug.print("Executing workflow immediately!\n", .{});
    } else {
        std.debug.print("Executing workflow (scheduled).\n", .{});
    }
    // ... further logic
}
```

_Key points:_

- Define a `zli.Flag` struct specifying its properties.
- Use `cmd.addFlag()` to associate it with the command.
- Access the flag's value in `execFn` using `ctx.flag("name", type)`. `zli` handles parsing and type conversion.

Supported flag types:

- `.Bool`: `ctx.flag("myflag", bool)`
- `.Int`: `ctx.flag("myflag", i64)` (or other integer types, u32 etc... but make sure to handle integer cast issues)
- `.String`: `ctx.flag("myflag", []const u8)`

### 5. Defining and Using Positional Arguments

Positional arguments are specified by their order. Let's add a required `script` argument and an optional `env` argument to `blitz run`.

Modify `src/cli/run.zig`:

```zig
// src/cli/run.zig
const std = @import("std");
const zli = @import("zli");

// now_flag definition (as above) ...
const now_flag = zli.Flag{ /* ... */ };

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run a specified workflow",
    }, runWorkflow);

    try cmd.addFlag(now_flag);

    // Add positional arguments
    try cmd.addPositionalArg(.{
        .name = "script", // Used for help text and ctx.getArg()
        .description = "The script to execute",
        .required = true,
    });
    try cmd.addPositionalArg(.{
        .name = "env",
        .description = "Target environment (e.g., dev, prod)",
        .required = false, // This argument is optional
    });

    return cmd;
}

fn runWorkflow(ctx: zli.CommandContext) !void {
    const run_immediately = ctx.flag("now", bool);

    // Access positional arguments
    const script_name = ctx.getArg("script") orelse {
        // Should not happen if zli enforces required args, but good for clarity
        // or if you manually handle this logic.
        // zli's help generation will indicate it's required.
        // Actual enforcement might be manual or zli might error before execFn.
        try ctx.command.stderr.print("Error: Missing required argument 'script'.\n", .{});
        try ctx.command.printHelp(.{});
        return zli.UserError.MissingRequiredArgument; // Or an appropriate error
    };

    const environment = ctx.getArg("env") orelse "development"; // Default if not provided

    std.debug.print("Running script '{s}' in environment '{s}'. Immediate: {any}\n", .{
        script_name,
        environment,
        run_immediately,
    });
}
```

_Key points:_

- Define positional arguments using `zli.PositionalArg` struct, specifying `.name`, `.description`, and `.required`.
- Add them with `cmd.addPositionalArg()`. Order matters.
- Access values with `ctx.getArg("name")`. This returns an `?[]const u8`. Use `orelse` for default values for optional arguments or to handle missing required ones (though `zli` often helps by showing an error/help message before `execFn` if a required arg is missing).

### 6. A Simple Version Subcommand (`src/cli/version.zig`)

It's common to have a command to display the application's version.

```zig
// src/cli/version.zig
const std = @import("std");
const zli = @import("zli");

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    return zli.Command.init(allocator, .{
        .name = "version",
        .shortcut = "v", // Allows `blitz v`
        .description = "Show CLI version",
    }, showVersion);
}

fn showVersion(ctx: zli.CommandContext) !void {
    // Access the version string set on the root command
    if (ctx.root.options.version) |v| {
        try ctx.command.stdout.print("{s}\n", .{v});
    } else {
        try ctx.command.stdout.print("Version not set.\n", .{});
    }
}
```

This command, when registered in `root.zig`, will allow users to run `blitz version` or `blitz v`.

## ✨ Features in Detail

### Automatic Help Messages

`zli` automatically generates help messages for your CLI and its commands.

- Running a command with `--help` or `-h` (by default) will display its specific help.
- If a root command's `execFn` (like `showHelp` in our example) calls `ctx.command.printHelp(...)`, it will be shown when the CLI is run without arguments or subcommands.
- Help messages are neatly formatted, aligning flags, arguments, and descriptions.
- Customize help output slightly with `zli.PrintHelpOptions` (e.g., `.show_flags_for_subcommands`).

Example help output might look like:

```
blitz run

Run a specified workflow

Usage:
  blitz run [flags] <script> [env]

Arguments:
  script     The script to execute (required)
  env        Target environment (e.g., dev, prod)

Flags:
  -h, --help     Show help for command
  -n, --now      Run the workflow immediately (default: false)
```

### Version Handling

- **Via Root Command Option**: You can set a `.version` string in `zli.CommandOptions` for your root command:

  ```zig
  // In cli/root.zig
  const root = try zli.Command.init(allocator, .{
      .name = "blitz",
      .description = "...",
      .version = "v1.2.3", // Set version here
  }, showHelp);
  ```

  `zli` may automatically provide a `--version` flag on the root command that prints this version string. If not, you can easily implement a `version` subcommand (as shown previously) that accesses `ctx.root.options.version`.

- **Via a `version` Subcommand**: As demonstrated in the `src/cli/version.zig` example, creating a dedicated `version` subcommand is a clear and common pattern. This command can then access `ctx.root.options.version`.

### Type-Safe Flag Parsing

`zli` ensures that flag values are parsed into the correct Zig types you specify.

- `ctx.flag("myflag", bool)` returns `bool`.
- `ctx.flag("myflag", i64)` returns `i64`.
- `ctx.flag("myflag", []const u8)` returns `[]const u8`.

If a flag value cannot be parsed to the expected type (e.g., "abc" for an `.Int` flag), `zli` will typically handle the error and display a helpful message to the user before your `execFn` is called.

### Positional Arguments: Required, Optional, Variadic

- **`required: true`**: If a positional argument is marked as required, `zli`'s help output will indicate this. The framework may automatically error out if a required argument is missing, or you might need to check for `null` from `ctx.getArg()` and handle it.

  ```zig
  try cmd.addPositionalArg(.{ .name = "input", .required = true, /* ... */ });
  const input_file = ctx.getArg("input") orelse return error.MissingInput; // Or handle gracefully
  ```

- **`required: false` (Optional)**: These can be omitted. `ctx.getArg()` will return `null`. Use `orelse` to provide a default.

  ```zig
  try cmd.addPositionalArg(.{ .name = "output", .required = false, /* ... */ });
  const output_file = ctx.getArg("output") orelse "default.out";
  ```

- **`variadic: true`**: A variadic argument can consume multiple trailing inputs. It must be the last positional argument defined for a command.
  ```zig
  try cmd.addPositionalArg(.{
      .name = "files",
      .description = "Input files to process",
      .required = true,
      .variadic = true,
  });
  ```
  Accessing variadic arguments:
  - `ctx.getArg("files")` would likely give you the _first_ file.
  - To get all variadic arguments, you might need to access a field like `ctx.command.parsed_args.positional_values.get("files_variadic_slice_name")` or iterate over `ctx.rawArgs()` after parsing flags. (The exact mechanism for accessing _all_ variadic arguments as a slice needs to be confirmed from `zli`'s specific API for `CommandContext` or parsed arguments. The README indicates support but doesn't detail access).
    _Developer Note: If `zli` doesn't directly provide a slice for variadic args via `ctx.getArg()`, you might need to iterate over remaining arguments in `ctx.command.args` after known flags and positional args are accounted for, or `zli` might place them under a special key._

### Passing Custom Data via `CommandContext`

You can pass arbitrary application-specific data (like configuration, database connections, etc.) to all your command execution functions.

In `src/main.zig`:

```zig
// src/main.zig
// ...
pub const AppData = struct {
    config_path: []const u8,
    verbose_logging: bool,
};

pub fn main() !void {
    // ... allocator setup ...
    var root = try cli.build(allocator);
    defer root.deinit();

    var my_app_data = AppData{
        .config_path = "config.json",
        .verbose_logging = true,
    };

    try root.execute(.{ .allocator = allocator, .data = &my_app_data });
}
```

In any command's `execFn`:

```zig
// src/cli/any_command.zig
// ...

pub const AppData = struct { // redefine it or import it
    config_path: []const u8,
    verbose_logging: bool,
};

fn myCommandFn(ctx: zli.CommandContext) !void {
    const app_data = ctx.getContextData(AppData); // returns a pointer to app_data

    // Now do something
    std.debug.print("Config path from custom data: {s}\n", .{app_data.config_path});

    // ...
}
```

### Deprecation Notices

`zli` will automatically show a warning when a deprecated command/flag is used.

This might be configured via `zli.CommandOptions` or `zli.Flag`:

```zig
// Hypothetical example - check zli source for actual API
const cmd = try zli.Command.init(allocator, .{
    .name = "oldcmd",
    .description = "This is an old command.",
    .deprecated = true, // or .deprecation_message = "Use 'newcmd' instead."
    // ...
}, execOldCmd);

const old_flag = zli.Flag{
    .name = "legacy",
    .description = "A legacy flag.",
    .deprecated = true,
    .replaced_by = "new", // Will display "Use 'new' instead'.
    // ...
};
```

## 📝 Best Practices

### Modular Command Design

- Keep each command's logic self-contained in its own file (e.g., `cli/mycommand.zig`).
- The `register` or `build` function in each command file should be responsible for initializing the command, its flags, and its positional arguments.
- The root command module (`cli/root.zig`) then imports and registers these subcommands. This keeps your codebase clean and scalable.

### Error Handling

- Command execution functions (`execFn`) should return `!void` (or another error union type).
- Propagate errors using `try` or handle them gracefully within the command.
- `zli` itself will handle parsing errors for flags and arguments.
- For application-specific errors, you can define custom error sets and return them. `zli`'s `execute` function will propagate these up to `main`.

  ```zig
  const MyError = error{
      FileNotFound,
      NetworkError,
  };

  fn myExecFn(ctx: zli.CommandContext) MyError!void {
      if (problem) return MyError.FileNotFound;
      // ...
  }
  ```

### Allocator Management

- Pass an allocator to `zli.Command.init()`. `zli` uses this for its internal allocations.
- Ensure `Command.deinit()` is called (typically via `defer` on the root command in `main.zig`) to free all resources allocated by `zli` for the command tree.
- If your command functions perform allocations, use the `ctx.allocator` for consistency, or manage your own allocator lifecycle appropriately.

## 📖 API Quick Reference

This is a brief overview of key `zli` components. For full details, refer to the `zli` source code.

### `zli.Command`

The central struct representing a command.

- `pub fn init(allocator: std.mem.Allocator, options: CommandOptions, execFn: ExecFn) !*Command`
- `pub fn deinit(self: *Command)`
- `pub fn addCommand(self: *Command, sub_command: *Command) !void`
- `pub fn addCommands(self: *Command, sub_commands: []const *Command) !void`
- `pub fn addFlag(self: *Command, flag: Flag) !void`
- `pub fn addPositionalArg(self: *Command, arg: PositionalArg) !void`
- `pub fn execute(self: *Command, options: ExecuteOptions) !void`
- `pub fn printHelp(self: *const Command, options: PrintHelpOptions) !void`
- `options: CommandOptions`
- `flags: std.ArrayList(Flag)`
- `positional_args: std.ArrayList(PositionalArg)`
- `sub_commands: std.ArrayList(*Command)`
- `execFn: ExecFn`
- `stdout: std.fs.File.Writer` (and `stderr`, `stdin`)

### `zli.CommandOptions`

Configuration for a `Command`.

- `.name: []const u8`
- `.shortcut: ?[]const u8 = null`
- `.aliases: ?[]const []const u8 = null`
- `.description: ?[]const u8 = null`
- `.version: ?[]const u8 = null`
- `.deprecated: bool = false` (or similar for deprecation message)
- ... other options like usage examples, etc.

### `zli.CommandContext`

Provided to `ExecFn`.

- `.allocator: std.mem.Allocator`
- `.command: *Command` (current command)
- `.root: *Command` (root command)
- `.data: ?*anyopaque` (user-provided data)
- `.stdin: std.fs.File.Reader`
- `.stdout: std.fs.File.Writer`
- `.stderr: std.fs.File.Writer`
- `pub fn flag(self: CommandContext, comptime name: []const u8, comptime T: type) T`
- `pub fn getArg(self: CommandContext, name: []const u8) ?[]const u8`

### `zli.Flag`

Definition for a command-line flag.

- `.name: []const u8`
- `.shortcut: ?[]const u8 = null`
- `.description: ?[]const u8 = null`
- `.type: FlagType` (e.g., `.Bool`, `.Int`, `.String`)
- `.default_value: ?FlagValue = null`
- `.deprecated: bool = false` (or similar for deprecation message)

### `zli.PositionalArg`

Definition for a positional argument.

- `.name: []const u8` (for help text and `ctx.getArg()`)
- `.description: ?[]const u8 = null`
- `.required: bool = false`
- `.variadic: bool = false`

## `zli.Spinner`

A powerful and customizable CLI spinner.

It is accessible via `ctx.spinner` and can be used in any command's `execFn`.

here's an example of how it works:

```zig

const std = @import("std");
const Spinner = @import("spinner.zig").Spinner;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // const spinner = try Spinner.init(allocator, .{}); // you don't have to do this if you're using zli. It is initialized automatically for you.
    // defer spinner.deinit();

    try spinner.start("Step 1: Initializing the system...", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // This updates the text of the current step
    try spinner.updateText("Step 1: System initialization is taking a while...", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // This completes Step 1 and starts a new step (Step 2)
    try spinner.nextStep("Step 2: Downloading resources...", .{});
    std.time.sleep(1 * std.time.ns_per_s);

    // Add a log line. It will appear above the spinner and stay there.
    try spinner.addLine("Downloaded 'resource_a.zip'", .{});
    std.time.sleep(2 * std.time.ns_per_s);
    try spinner.addLine("Downloaded 'resource_b.zip'", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // Complete Step 2 and start Step 3
    try spinner.nextStep("Step 3: Compiling assets...", .{});
    std.time.sleep(3 * std.time.ns_per_s);

    // Finish the entire process with a success message
    try spinner.succeed("All steps completed successfully!", .{});

    std.debug.print("\n--- Starting another example (failure case) ---\n\n", .{});

    const spinner2 = try Spinner.init(allocator, .{ .frames = Spinner.SpinnerStyles.line });
    defer spinner2.deinit();

    try spinner2.start("Task 1: Connecting to server...", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    try spinner2.nextStep("Task 2: Authenticating...", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // The whole process fails at this step
    try spinner2.fail("Authentication failed: Invalid credentials.", .{});
}

```

## 🤝 Contributing

Contributions to `zli` are welcome! Please refer to the main GitHub repository (`https://github.com/xcaeser/zli`) for contribution guidelines, opening issues, or submitting pull requests.

## 📜 License

`zli` is licensed under the MIT License. See the [LICENSE](LICENSE) file in the main repository for full details.
