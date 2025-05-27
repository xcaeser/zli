### 📟 zli

A **blazing-fast**, zero-cost CLI framework for Zig. The last one you will ever use.

Build modular, ergonomic, and high-performance CLIs with ease.
All batteries included.

[![Zig Version](https://img.shields.io/badge/Zig_Version-0.14.1-orange.svg?logo=zig)](README.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Built by xcaeser](https://img.shields.io/badge/Built%20by-@xcaeser-blue)](https://github.com/xcaeser)
[![Version](https://img.shields.io/badge/ZLI-v3.5.3-green)](https://github.com/xcaeser/zli/releases)

> 🧱 Each command is modular and self-contained.
> inspired by Cobra (Go) and clap (Rust).

## 📚 Documentation

See [docs.md](docs.md) for full usage, examples, and internals.

## 🚀 Highlights

- Modular commands & subcommands
- Fast flag parsing (`--flag`, `--flag=value`, shorthand `-abc`)
- Type-safe support for `bool`, `int`, `string`
- Named positional arguments with `required`, `optional`, `variadic`
- Auto help/version/deprecation handling
- Pretty help output with aligned flags & args
- Cobra-like usage hints, context-aware

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.5.3.tar.gz
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
    std.debug.print("{?}\n", .{ctx.root.options.version});
}
```

## ✅ Features Checklist

- [x] Commands & subcommands
- [x] Flags & shorthands
- [x] Type-safe flag values
- [x] Help/version auto handling
- [x] Deprecation notices
- [x] Positional args (required, optional, variadic)
- [x] Pretty-aligned help for flags & args
- [x] Named access: `ctx.getArg("name")`
- [x] Clean usage output like Cobra
- [ ] Command aliases
- [ ] Persistent flags

## 📝 License

MIT. See [LICENSE](LICENSE). Contributions welcome.
