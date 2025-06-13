### 📟 zli

A **blazing-fast**, zero-cost CLI framework for Zig. The last one you will ever use.

Build modular, ergonomic, and high-performance CLIs with ease.
All batteries included.

[![Tests](https://github.com/xcaeser/zli/actions/workflows/main.yml/badge.svg)](https://github.com/xcaeser/zli/actions/workflows/main.yml)
[![Zig Version](https://img.shields.io/badge/Zig_Version-0.14.1-orange.svg?logo=zig)](README.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Built by xcaeser](https://img.shields.io/badge/Built%20by-@xcaeser-blue)](https://github.com/xcaeser)
[![Version](https://img.shields.io/badge/ZLI-v3.7.0-green)](https://github.com/xcaeser/zli/releases)

> [!TIP]
> 🧱 Each command is modular and self-contained.

## 📚 Documentation

See [docs.md](docs.md) for full usage, examples, and internals.

## 🚀 Highlights

- Modular commands & subcommands
- Fast flag parsing (`--flag`, `--flag=value`, shorthand `-abc`)
- Type-safe support for `bool`, `int`, `string`
- Named positional arguments with `required`, `optional`, `variadic`
- Auto help/version/deprecation handling
- Pretty help output with aligned flags & args
- Spinners (new in v3.7.0)
- Usage hints, context-aware

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.7.0.tar.gz
```

Add to your `build.zig`:

```zig
const zli_dep = b.dependency("zli", .{ .target = target });
exe.root_module.addImport("zli", zli_dep.module("zli"));
```

## 🗂 Suggested Structure

```
your-app/
├── build.zig
├── src/
│   ├── main.zig
│   └── cli/
│       ├── root.zig
│       ├── run.zig
│       └── version.zig
```

- Each command is in its own file
- You explicitly register subcommands
- `root.zig` is the entry point

## 🧪 Example

```zig
// src/main.zig
const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var root = try cli.build(allocator);
    defer root.deinit();

    try root.execute(.{}); // Or pass data with: try root.execute(.{ .data = &my_data });
}
```

```zig
// src/cli/root.zig
const std = @import("std");
const zli = @import("zli");

const run = @import("run.zig");
const version = @import("version.zig");

pub fn build(allocator: std.mem.Allocator) !*zli.Command {
    const root = try zli.Command.init(allocator, .{
        .name = "blitz",
        .description = "Your dev toolkit CLI",
    }, showHelp);

    try root.addCommands(&.{
        try run.register(allocator),
        try version.register(allocator),
    });

    return root;
}

fn showHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
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
    .type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run your workflow",
    }, run);

    try cmd.addFlag(now_flag);
    try cmd.addPositionalArg(.{
        .name = "script",
        .description = "Script to execute",
        .required = true,
    });
    try cmd.addPositionalArg(.{
        .name = "env",
        .description = "Environment name",
        .required = false,
    });

    return cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const now = ctx.flag("now", bool); // type-safe flag access

    const script = ctx.getArg("script") orelse {
        try ctx.command.stderr.print("Missing script arg\n", .{});
        return;
    };
    const env = ctx.getArg("env") orelse "default";

    std.debug.print("Running {s} in {s} (now = {})\n", .{ script, env, now });

    // You can also get other commands by name:
    // if (ctx.root.findCommand("create")) |create_cmd| {
    //    try create_cmd.printUsageLine();
    // }

    // if you passed data to your root command, you can access it here:
    // const object = ctx.getContextData(type_of_your_data); // can be struct, []const u8, etc., object is a pointer.

};
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
    std.debug.print("{?}\n", .{ctx.root.options.version});
}
```

### Spinners example

```zig
const std = @import("std");
const zli = @import("zli");

pub fn run(ctx: zli.CommandContext) !void {
    // Step 1: Start the first task.
    try ctx.spinner.start(.{}, "Connecting to vault...", .{});
    doSomething();
    try ctx.spinner.updateText("Step 2: Authentication is taking a moment...", .{});
    doSomething();

    // Step 2: Mark Step 1 as complete and start the next task.
    const key = ctx.getArg("key") orelse "b";
    try ctx.spinner.nextStep("Retrieving key '{s}'...", .{key});
    doSomething();

    // Step 3: Mark Step 2 as complete and start the final task.
    try ctx.spinner.nextStep("Decrypting value...", .{});
    const value = try zv.getFromVault(key);
    const fl = ctx.flag("now", bool);
    doSomething();

    // Step 4: Mark the final task as successful and stop.
    try ctx.spinner.succeed("Success! Found value: {s} (flag: {any})", .{ value, fl });
}
```

## ✅ Features Checklist

- [x] Commands & subcommands
- [x] Command aliases
- [x] Flags & shorthands
- [x] Type-safe flag values
- [x] Positional args (required, optional, variadic)
- [x] Named access: `ctx.getArg("name")`
- [x] Context data
- [x] Help/version auto handling
- [x] Deprecation notices
- [x] Pretty-aligned help for flags & args
- [x] Clean usage output like Cobra
- [x] Spinners and loading state (very powerful)
- [ ] Persistent flags

## 📝 License

MIT. See [LICENSE](LICENSE). Contributions welcome.
