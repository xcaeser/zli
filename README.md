# 📟 zli

A **blazing-fast**, zero-cost CLI framework for Zig — inspired by Cobra (Go) and clap (Rust).

Build modular, ergonomic, and high-performance CLIs with ease.

[![Zig Version](https://img.shields.io/badge/Zig_Version-0.14.0-orange.svg?logo=zig)](README.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg?logo=cachet)](LICENSE)
[![Built by xcaeser](https://img.shields.io/badge/Built%20by-@xcaeser-blue)](https://github.com/xcaeser)
[![Version](https://img.shields.io/badge/ZLI-v3.1.1-green)](https://github.com/xcaeser/zli/releases)

> [!TIP]
> 🧱 Each command is modular and self-contained.

---

## 📚 Documentation

See [docs.md](docs.md) for full usage, examples, and internals.

---

## 🚀 Highlights

- Modular commands & subcommands
- Fast flag parsing (`--flag`, `--flag=value`, shorthand `-abc`)
- Type-safe support for `bool`, `int`, `string`
- Auto help/version/deprecation handling
- Works like Cobra or clap, but in Zig

---

## 📦 Installation

```sh
zig fetch --save=zli https://github.com/xcaeser/zli/archive/v3.1.1.tar.gz
```

Add to your `build.zig`:

```zig
const zli_dep = b.dependency("zli", .{ .target = target });
exe.root_module.addImport("zli", zli_dep.module("zli"));
```

---

## 🧪 Example

```zig
// src/main.zig
const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var root = try cli.build(allocator);
    defer root.deinit();

    try root.execute();
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
    .flag_type = .Bool,
    .default_value = .{ .Bool = false },
};

pub fn register(allocator: std.mem.Allocator) !*zli.Command {
    const cmd = try zli.Command.init(allocator, .{
        .name = "run",
        .description = "Run your workflow",
    }, run);

    try cmd.addFlag(now_flag);
    return cmd;
}

fn run(ctx: zli.CommandContext) !void {
    const now = ctx.command.getBoolValue("now");
    std.debug.print("Running now: {}\n", .{now});
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
    std.debug.print("v1.0.0\n", .{});
}
```

---

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
- Root is the entry point

---

## ✅ Features Checklist

- [x] Commands & subcommands
- [x] Flags & shorthands
- [x] Type-safe flag values
- [x] Help/version auto handling
- [x] Deprecation notices
- [ ] Positional args
- [ ] Command aliases
- [ ] Persistent flags

---

## 📝 License

MIT. See [LICENSE](LICENSE). Contributions welcome.
