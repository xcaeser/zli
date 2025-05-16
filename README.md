# 📟 zli

A **blazing fast**, zero-cost-abstraction command-line interface (CLI) framework for Zig, inspired by Go's Cobra and Rust's clap. Build robust, ergonomic, and highly-performant CLI apps with ease.

Written fully in Zig.

[![Zig Version](https://img.shields.io/badge/Zig_Version-0.14.0-orange.svg?logo=zig)](README.md)
[![MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Built by xcaeser](https://img.shields.io/badge/Built%20by-@xcaeser-blue)](https://github.com/xcaeser)
[![Version](https://img.shields.io/badge/ZLI-v3.0.1-green)](https://github.com/xcaeser/zli/releases)

> [!IMPORTANT]
> ⚠️ Version 3.0 introduces breaking changes and a new command model. (no more after this, no promises 🫢)
>
> `Builder` was removed. Commands are now modular and self-contained.

## 🚀 Why zli?

- **Ultra-performant**: Minimal allocations, fast hash map-based resolution, and zero overhead.
- **Modular**: No more builders. Each `Command` manages its own subcommands and flags.
- **Type-safe flag parsing**: Booleans, ints, strings with default values and validation.
- **Built-in help/version**: Auto-help, usage, and semantic versioning support.
- **User-friendly output**: Styled, aligned, and informative CLI UX.
- **Deprecation-aware**: Mark commands as deprecated with suggested alternatives.
- **Supports positional arguments**

## ✅ Features Checklist

- [x] Subcommands with hash map lookup
- [x] Shorthand flags (e.g., -n for --now)
- [x] Type-safe parsing with default values
- [x] Auto help and version display
- [x] Semantic versioning
- [x] Deprecation warnings and replacements
- [ ] Positional arguments support
- [ ] Command aliases
- [ ] Persistent flags
- [ ] Full Windows support

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.0.1.tar.gz
```

**Add to `build.zig`**

```zig
const zli_dep = b.dependency("zli", .{ .target = target });
exe.root_module.addImport("zli", zli_dep.module("zli"));
```

## 🏎️ Usage

### 🖥️ Example Terminal Output

Here’s a sample session with the CLI built using `zli` for a task runner app called **blitz**:

```sh
$ blitz --help
Blitz CLI - your developer productivity toolkit.
v1.0.2

Available commands:
   run             Run a script or task
   version (v)     Show blitz CLI version

Run 'blitz [command] --help' for details on a specific command.

$ blitz version # or v
1.0.2

$ blitz run --script=build.zig --verbose true # both flag styles work  '=' and ' '
Running script: build.zig
Verbose output enabled.

$ blitz run test --repeat 3 # or -r. you can even use many shorthands -abc
Running test suite...
Repeating 3 times...
Test round 1: ✅
Test round 2: ✅
Test round 3: ✅
All tests passed!
```

### Project Structure

```
your-app/
├── src/
│   └── cli/
│       ├── root.zig       # CLI builder and command registration
│       ├── run.zig      # Example command
│       └── version.zig    # Version command
├── main.zig
└── build.zig
```

### Example: `src/main.zig`

```zig
const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var blitz = try cli.build(allocator);
    defer blitz.deinit();

    try blitz.execute();
}
```

### Example: `src/cli/root.zig`

```zig
const std = @import("std");
const zli = @import("zli");

const CLICommand = zli.Command;
const CLICommandOptions = zli.CommandOptions;
const CLICommandContext = zli.CommandContext;

const run_cmd = @import("run.zig");
const version_cmd = @import("version.zig");

pub fn build(allocator: std.mem.Allocator) !*CLICommand {
    var root = try CLICommand.init(allocator, .{
        .name = "blitz",
        .description = "Blitz CLI - your developer productivity toolkit.",
        .version = std.SemanticVersion.parse("1.0.2") catch unreachable,
    },
    runRoot,
    );

    try root.addCommands(&.{
        try run_cmd.register(root),
        try version_cmd.register(root),
    });

    return root;
}

fn runRoot(ctx: CLICommandContext) !void {
    // Modular AF :)
    // try ctx.command.listCommands();
    // try ctx.command.listFlags();
    // try ctx.command.printHelp();
    // std.debug.print("{}\n", .{ctx.command.options.version.?});

    // Do anything you want here
    // e.g. run a server, run a task, etc.
    // ctx.command.printHelp() to print help for this command
}
```

### Example: `src/cli/run.zig`

```zig
const std = @import("std");
const zli = @import("zli");

const CLICommand = zli.Command;
const CLICommandOptions = zli.CommandOptions;
const CLICommandContext = zli.CommandContext;
const CLIFlag = zli.Flag;

const version_cmd = @import("version.zig");

const options: CLICommandOptions = .{
    .name = "run",
    .description = "run the blitz instance",
    .section = .Access,
    .version = std.SemanticVersion.parse("3.1.4") catch unreachable,
    .deprecated = true,
    .replaced_by = "start",
};

pub fn register(parent_command: *CLICommand) !*CLICommand {
    var cmd = try CLICommand.init(parent_command.allocator, options, runCommand);
    const subcmd = try CLICommand.init(parent_command.allocator, suboptions, runCommand2);

    try cmd.addCommand(subcmd);

    try cmd.addFlags(&.{ nowFlag, ttlFlag });
    return cmd;
}

fn runCommand(ctx: CLICommandContext) !void {
    _ = ctx;
}

fn runCommand2(ctx: CLICommandContext) !void {
    const now = ctx.command.getBoolValue("now");
    const ttl = ctx.command.getIntValue("ttl");
    std.debug.print("Time to live: {d}\n", .{ttl});
}

const nowFlag = CLIFlag{
    .name = "now",
    .shortcut = "n",
    .description = "Forces to run now",
    .flag_type = .Bool,
    .default_value = .{ .Bool = true },
};

const ttlFlag = CLIFlag{
    .name = "ttl",
    .shortcut = "t",
    .description = "Time to live",
    .flag_type = .Int,
    .default_value = .{ .Int = 22 },
};
```

### Example: `src/cli/version.zig`

```zig
const std = @import("std");
const zli = @import("../lib/zli.zig");

const CLICommand = zli.Command;
const CLICommandOptions = zli.CommandOptions;
const CLICommandContext = zli.CommandContext;

const options: CLICommandOptions = .{
    .name = "version",
    .shortcut = "v",
    .description = "blitz's current installed version",
};

pub fn register(parent_command: *CLICommand) !*CLICommand {
    const cmd = try CLICommand.init(parent_command.allocator, options, runCommand);
    return cmd;
}

fn runCommand(ctx: CLICommandContext) !void {
    std.debug.print("{}\n", .{ctx.parent_command.?.options.version.?});  // Access the parent command
}
```

## 👍 Contributing

PRs and issues welcome. File bugs, suggest features, or optimize the API.

## 📝 License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
