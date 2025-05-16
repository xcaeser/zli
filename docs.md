# zli Documentation

Welcome to the `zli` documentation! `zli` is a **blazing fast**, zero-cost-abstraction command-line interface (CLI) framework for Zig. This guide will help you understand its core components and how to use them to build powerful CLI applications.

## Table of Contents

- [zli Documentation](#zli-documentation)
  - [Table of Contents](#table-of-contents)
  - [📦 Installation](#-installation)
  - [⚙️ General Design](#️-general-design)
  - [🛠️ Command (`zli.Command`)](#️-command-zlicommand)
    - [Creating a Command](#creating-a-command)
    - [Adding Subcommands](#adding-subcommands)
    - [Key `zli.Command` functions:](#key-zlicommand-functions)
  - [🔧 CommandOptions (`zli.CommandOptions`)](#-commandoptions-zlicommandoptions)
    - [Example](#example)
  - [👉 CommandContext (`zli.CommandContext`)](#-commandcontext-zlicommandcontext)
    - [Example](#example-1)
  - [🚩 Flag (`zli.Flag`)](#-flag-zliflag)
    - [Defining and Adding Flags](#defining-and-adding-flags)
    - [Retrieving Flag Values](#retrieving-flag-values)

## 📦 Installation

To add `zli` to your project, use Zig's built-in package manager:

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.1.1.tar.gz
```

_Note: Replace `v3.1.1` with the desired version tag._

Then, add it as a dependency in your `build.zig` file:

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "your-app-name",
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
    // ... rest of your build configuration
}
```

Now you can import `zli` in your Zig files:

```zig
const zli = @import("zli");
```

## ⚙️ General Design

`zli` is built around a modular, command-centric design. Unlike libraries that rely heavily on a global builder pattern, `zli` empowers each `Command` to be a self-contained unit.

Key principles:

- **Commands are Central**: The `zli.Command` struct is the primary building block. Each command defines its own behavior, options, flags, and subcommands.
- **Modularity**: Commands can be defined in separate files and composed together to build complex CLI structures. This promotes better organization and reusability.
- **Explicit Configuration**: Command properties (like name, description, flags) are set directly on the `Command` or through its `CommandOptions`.
- **Execution Logic (`execFn`)**: Each command has an associated function (`execFn`) that is executed when the command is invoked. This function receives a `CommandContext` providing access to parsed values and CLI state.
- **Performance**: Designed with performance in mind, minimizing allocations and leveraging efficient data structures like hash maps for command and flag resolution.

This approach leads to clear, maintainable, and testable CLI code.

## 🛠️ Command (`zli.Command`)

The `zli.Command` struct represents a command in your CLI application. It holds all information related to a command, including its options, flags, subcommands, and the function to execute.

### Creating a Command

You create a command using `zli.Command.init()`. It requires an allocator, `zli.CommandOptions`, and an execution function (`execFn`).

```zig
const std = @import("std");
const zli = @import("zli");

// This function will be executed when the 'hello' command is run.
fn runHello(ctx: zli.CommandContext) !void {
    // Access command options through ctx.command.options
    std.debug.print("Executing command: {s}\n", .{ctx.command.options.name});
    std.debug.print("Description: {s}\n", .{ctx.command.options.description});

    // Example of accessing a flag (see Flag section for defining flags)
    const name = ctx.command.getStringValue("name"); // Assumes a 'name' flag exists
    std.debug.print("Hello, {s}!\n", .{name});
}

// Function to create and configure the 'hello' command
pub fn createHelloCommand(allocator: std.mem.Allocator) !*zli.Command {
    const helloCmd = try zli.Command.init(
        allocator,
        .{ // zli.CommandOptions (see next section)
            .name = "hello",
            .description = "Prints a greeting message.",
            .usage = "app hello --name <your_name>",
        },
        runHello, // The function to execute for this command
    );

    // Add flags to the command (see Flag section)
    try helloCmd.addFlag(.{
        .name = "name",
        .shortcut = "n",
        .description = "The name to greet.",
        .flag_type = .String,
        .default_value = .{ .String = "World" },
    });

    return helloCmd;
}

// Example of how you might use it in your main application setup:
// (Assuming you have an allocator and a root command)
//
// var gpa = std.heap.GeneralPurposeAllocator(.{}){};
// defer _ = gpa.deinit();
// const allocator = gpa.allocator();
//
// var rootCommand = try zli.Command.init(allocator, .{ .name = "app", .description = "My CLI App" }, runRootLogic);
// defer rootCommand.deinit(); // Deallocates the command and its subcommands/flags
//
// const helloSubCommand = try createHelloCommand(allocator);
// try rootCommand.addCommand(helloSubCommand); // Add 'hello' as a subcommand to 'rootCommand'
//
// // To start the CLI parsing and execution:
// // try rootCommand.execute();
```

### Adding Subcommands

Commands can have subcommands, forming a nested structure. Use `addCommand()` or `addCommands()`.

```zig
// ... (allocator and rootCmd defined as above) ...
// var rootCmd = try zli.Command.init(...);
// defer rootCmd.deinit();

// Create another command
fn runConfig(ctx: zli.CommandContext) !void {
    std.debug.print("Configuring {s}...\n", .{ctx.root.options.name});
}

var configCmd = try zli.Command.init(
    allocator, // use the same allocator or a child allocator
    .{ .name = "config", .description = "Manages configuration." },
    runConfig,
);

// Add configCmd as a subcommand of rootCmd
try rootCmd.addCommand(configCmd);

// Now, your CLI might be invoked as: `your-app config`
```

### Key `zli.Command` functions:

- `init(allocator, options, execFn) !*Command`: Creates a new command.
- `deinit()`: Deallocates the command, its flags, and its subcommands. Call this on your root command when your application exits.
- `addCommand(child: *Command) !void`: Adds a subcommand.
- `addCommands(children: []const *Command) !void`: Adds multiple subcommands.
- `addFlag(flag: Flag) !void`: Adds a flag. (See [Flag](#-flag-zliflag) section).
- `addFlags(flags: []const Flag) !void`: Adds multiple flags.
- `printHelp() !void`: Prints the help message for the command.
- `execute() !void`: Parses command line arguments, finds the appropriate command, parses its flags, and runs its `execFn`. This is typically called on the root command.

## 🔧 CommandOptions (`zli.CommandOptions`)

The `zli.CommandOptions` struct is used to configure the metadata and behavior of a `zli.Command`. It's passed to `zli.Command.init()`.

Key fields:

- `name: []const u8`: The name of the command (e.g., "start", "list").
- `description: []const u8`: A detailed description of the command, shown in help messages.
- `section: ?Section = .Usage`: (Optional) Categorizes the command in help messages (e.g., `.Usage`, `.Configuration`). `Section` is an enum: `Usage`, `Configuration`, `Access`, `Help`, `Advanced`, `Experimental`.
- `version: ?std.SemanticVersion = null`: (Optional) The version of the command or application.
- `commands_title: []const u8 = "Available commands"`: (Optional) Custom title for the list of subcommands in help.
- `shortcut: ?[]const u8 = null`: (Optional) A short alias for the command (e.g., "ls" for "list").
- `short_description: ?[]const u8 = null`: (Optional) A brief description used when listing commands. Defaults to `description` if null.
- `help: ?[]const u8 = null`: (Optional) Custom long help text.
- `usage: ?[]const u8 = null`: (Optional) Custom usage line (e.g., "app command [options] <file>").
- `deprecated: bool = false`: (Optional) Marks the command as deprecated.
- `replaced_by: ?[]const u8 = null`: (Optional) If deprecated, suggests a replacement command.

### Example

```zig
const std = @import("std");
const zli = @import("zli");

// ...
const serverCmdOptions = zli.CommandOptions{
    .name = "server",
    .description = "Manages the application server.",
    .short_description = "Manage server (start, stop, status)", // For concise listings
    .shortcut = "s",
    .version = std.SemanticVersion.parse("0.1.0") catch unreachable,
    .usage = "app server [subcommand] --port <port_number>",
    .section = .Access, // Categorize under 'Access' in help
    .commands_title = "Server operations",
};

// Usage with Command.init:
// var serverCmd = try zli.Command.init(allocator, serverCmdOptions, runServerRoot);

const startServerCmdOptions = zli.CommandOptions{
    .name = "start",
    .description = "Starts the application server.",
    .deprecated = true,
    .replaced_by = "run", // Suggests 'run' as the new command
};

// Usage:
// var startCmd = try zli.Command.init(allocator, startServerCmdOptions, runStartServer);
// try serverCmd.addCommand(startCmd);
```

## 👉 CommandContext (`zli.CommandContext`)

When a command's `execFn` is called, it receives a `zli.CommandContext` struct. This context provides information about the current execution environment and allows access to parsed flag values and other command-related data.

Key fields:

- `root: *const Command`: A pointer to the root command of the CLI application.
- `direct_parent: *const Command`: A pointer to the immediate parent command of the currently executing command. This will be the same as `root` if the current command is a direct child of the root, or `root` if the current command _is_ the root (in which case, `command.parent` would be null).
- `command: *const Command`: A pointer to the `Command` struct that is currently being executed. This is what you'll use most often to access options, flags, etc., of the current command.
- `allocator: std.mem.Allocator`: The allocator used by the command.
- `env: ?std.process.EnvMap = null`: (Optional) Provides access to environment variables.
- `stdin: ?std.fs.File = null`: (Optional) Provides access to standard input.

### Example

```zig
const std = @import("std");
const zli = @import("zli");

fn processData(ctx: zli.CommandContext) !void {
    std.debug.print("--- Command Context Info ---\n", .{});
    std.debug.print("Executing Command: {s}\n", .{ctx.command.options.name});
    if (ctx.command.options.version) |v| {
        std.debug.print("Command Version: {s}\n", .{v});
    }

    std.debug.print("Root Command: {s}\n", .{ctx.root.options.name});

    // Check if there's a direct parent and print its name
    // Note: for a root command, `ctx.command.parent` would be null.
    // `ctx.direct_parent` points to the logical parent in the call chain.
    // If `ctx.command` is the root command itself, `ctx.direct_parent` will also be the root command.
    if (ctx.command.parent) |parent_cmd_ptr| { // Check if current command has a structural parent
        std.debug.print("Direct Parent Command: {s}\n", .{parent_cmd_ptr.options.name});
    } else {
        std.debug.print("This is a top-level command (or the root).\n", .{});
    }


    // Accessing flag values (assuming flags are defined on ctx.command)
    const inputFile = ctx.command.getStringValue("input-file"); // Example flag
    const verbose = ctx.command.getBoolValue("verbose");     // Example flag

    if (verbose) {
        std.debug.print("Verbose mode: ON\n", .{});
    }
    std.debug.print("Processing file: {s}\n", .{inputFile});

    // You can also print help for the current command if needed
    // if (some_condition) {
    //     try ctx.command.printHelp();
    //     return;
    // }
    std.debug.print("--- End Context Info ---\n", .{});
}

// This function would be passed to zli.Command.init:
// var processCmd = try zli.Command.init(
//     allocator,
//     .{ .name = "process", .description = "Processes data." },
//     processData
// );
//
// // Define flags for processCmd
// try processCmd.addFlags(&.{
//     .{ .name = "input-file", .description = "Path to the input file", .flag_type = .String, .default_value = .{ .String = "input.txt"} },
//     .{ .name = "verbose", .shortcut = "v", .description = "Enable verbose output", .flag_type = .Bool, .default_value = .{ .Bool = false } },
// });
```

## 🚩 Flag (`zli.Flag`)

Flags (also known as options or switches) modify the behavior of commands. `zli.Flag` defines a command-line flag.

Fields:

- `name: []const u8`: The full name of the flag (e.g., "verbose", "output-file"). Used with `--name`.
- `shortcut: ?[]const u8 = null`: (Optional) A single-character alias for the flag (e.g., "v", "o"). Used with `-s`.
- `description: []const u8`: A description of the flag, shown in help messages.
- `flag_type: FlagType`: The type of the flag's value. `FlagType` is an enum:
  - `.Bool`: Boolean flag (e.g., `--force`, `-f`).
  - `.Int`: Integer flag (e.g., `--count 10`).
  - `.String`: String flag (e.g., `--message "Hello"`).
- `default_value: union(FlagType)`: The default value if the flag is not provided. The union tag must match `flag_type`.
  - `.Bool: bool`
  - `.Int: i32`
  - `.String: []const u8`

### Defining and Adding Flags

You define `Flag` structs and add them to a `Command` using `addFlag()` or `addFlags()`.

```zig
const std = @import("std");
const zli = @import("zli");

// Define some flags
const verboseFlag = zli.Flag{
    .name = "verbose",
    .shortcut = "v",
    .description = "Enable verbose logging.",
    .flag_type = .Bool,
    .default_value = .{ .Bool = false },
};

const portFlag = zli.Flag{
    .name = "port",
    .shortcut = "p",
    .description = "Port number to listen on.",
    .flag_type = .Int,
    .default_value = .{ .Int = 8080 },
};

const configFileFlag = zli.Flag{
    .name = "config",
    .description = "Path to the configuration file.",
    .flag_type = .String,
    .default_value = .{ .String = "/etc/app/config.json" },
};

// Example execution logic that uses these flags
fn runMyServer(ctx: zli.CommandContext) !void {
    const isVerbose = ctx.command.getBoolValue("verbose");
    const serverPort = ctx.command.getIntValue("port");
    const configPath = ctx.command.getStringValue("config");

    if (isVerbose) {
        std.debug.print("Verbose mode enabled.\n", .{});
    }
    std.debug.print("Server starting on port: {d}\n", .{serverPort});
    std.debug.print("Using config file: {s}\n", .{configPath});
    // ... server logic ...
}

// In your command setup:
// var serverCmd = try zli.Command.init(
//     allocator,
//     .{ .name = "serve", .description = "Starts the application server." },
//     runMyServer
// );
//
// // Add flags to the serverCmd
// try serverCmd.addFlag(verboseFlag);
// try serverCmd.addFlag(portFlag);
// try serverCmd.addFlag(configFileFlag);
// // Alternatively, add multiple flags at once:
// // try serverCmd.addFlags(&.{verboseFlag, portFlag, configFileFlag});
```

### Retrieving Flag Values

Inside a command's `execFn`, you retrieve parsed flag values from the `CommandContext` using methods on the `ctx.command` pointer:

- `getBoolValue(flag_name: []const u8) bool`
- `getIntValue(flag_name: []const u8) i32`
- `getStringValue(flag_name: []const u8) []const u8`
- `getOptionalStringValue(flag_name: []const u8) ?[]const u8`

These methods will return the parsed value if the flag was provided by the user, or the flag's `default_value` if it wasn't. If a flag is not defined on the command, boolean flags default to `false`, integers to `0`, and strings to `""` (or `null` for `getOptionalStringValue`).

`zli` handles parsing arguments like `--port=8000`, `--port 8000`, `-v`, `--verbose`, `--verbose=true`, and combined shorthands like `-abc`.
