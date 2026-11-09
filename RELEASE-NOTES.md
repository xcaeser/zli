## zli v6.2.0

### Added

- `PositionalArg.passthrough` (default `true`, which keeps v6.1.0 behavior). Set it to `false` on a variadic argument and flags keep parsing after the positionals, until `--`. With `passthrough = false` on `files`, `app merge a.pdf b.pdf -o out.pdf` passes `a.pdf` and `b.pdf` and sets `-o`.
- `ctx.flagValues("chain")` returns every value a flag was given, in order, as written. `app --chain a.pem --chain b.pem` gives `a.pem`, `b.pem`. Bool flags record `true` for `--x`, `false` for `--no-x`, and the text for `--x=false`. It accepts a name or a shortcut. A persistent flag given before a subcommand shows up in the subcommand's values. `ctx.flag` still returns the last value.
- `ctx.isFlagSet("greeting")` tells whether the command line gave the flag in any form. `--greeting=` is set (to an empty string), no `--greeting` is not set, and `--no-cache` sets `cache`.
- `InitOptions.error_writer`. Parse errors, deprecation notices and `run`'s `error: Name` line go there, so an app can send them to stderr while help and version stay on `writer`. It defaults to `writer`, and both writers are flushed on errors.

## zli v6.1.0

### Changed

- A command with a variadic positional argument takes every word after its first positional as a positional, including words that start with `-` or `--`. With a variadic `command` on `app shell`, `app shell ls -la` passes `ls` and `-la`, and `app shell cat --help` passes `cat` and `--help` instead of showing help. Flags before the first positional (`app shell --help`, `app shell -h`) still parse, and commands without a variadic argument are unchanged. To give such a command a flag, put it before the first positional.

## zli v6.0.0

A major release: a rewritten spinner, a leaner parser and help renderer (src/zli.zig shrinks from 1110 to 834 lines), and 14 bug fixes. It needs Zig 0.17.0, and a few APIs changed (see below).

### Breaking changes

- **Zig 0.17.0** is now the minimum version.
- **`Spinner.init` no longer takes a reader.** It is now `Spinner.init(io, writer, allocator, options)`. Commands that use `ctx.spinner` need no change.
- **`Spinner.SpinnerOptions` is renamed to `Spinner.Options`.**
- **Spinner frames no longer end in a space.** The spinner adds the gap itself. Remove the trailing space from custom frames, or you'll get two.
- **`Spinner.styles` is private.** Use `zli.styles`.
- **`SpinnerStyles.circle_halvess` is renamed to `circle_halves`.**
- **`Command._max_len` is removed.**
- **`runAndExit` prints `error: <Name>`** when a command's own function returns an error, instead of exiting 1 silently. zli's own parse errors still print only their usual message.
- **Deprecated commands are hidden from help listings.** They still run and print their deprecation notice.

```zig
// v5
var spinner = zli.Spinner.init(io, writer, reader, allocator, .{});
const options: zli.Spinner.SpinnerOptions = .{ .frames = &.{ "+ ", "x " } };

// v6
var spinner = zli.Spinner.init(io, writer, allocator, .{});
const options: zli.Spinner.Options = .{ .frames = &.{ "+", "x" } };
```

### Added

- `Command.run`, which works like `runAndExit` but returns the exit code instead of exiting.
- `spinner.warn()`, a yellow ⚠ line.
- `succeed`, `fail`, `warn`, `info` and `preserve` work without a `start()`, for one-off status lines.

### Fixed

#### Spinner

- When output is piped or redirected (CI logs, `> file`), nothing animates. Only the finished lines are printed, without colors or escape codes.
- `stop()`, `succeed()` and the other finishers return immediately. Before, they waited up to one refresh interval.
- Ctrl+C while a spinner runs restores the hidden cursor before the process exits.
- Messages wider than the terminal are clipped instead of leaving a trail of wrapped lines.

#### Parsing

- An empty argv, or an empty argument (`app echo ""`), no longer crashes.
- An unknown subcommand is reported as an error. Before, the parent command ran silently and exited 0.
- Persistent flags given before a subcommand (`app --verbose greet`) now reach it. `--help` is persistent too, so `app --help greet` shows greet's help.
- `-h` and `--help` after `--` are positional arguments.
- Flags whose name starts with `no-` (e.g. `--no-cache`) can be set.
- The long form of a shortcut (`--t=2`) sets the flag.
- `ctx.flag()` reads a flag by its shortcut.
- Negative numbers outside the i32 range, or with decimals (`-1.5`), are positional arguments instead of flag groups.
- `ctx.flag()` panics with the flag's name on a misspelled name, instead of undefined behavior in release builds.
- `ctx.flag()` saturates ints that don't fit the requested type instead of panicking.

#### Help and output

- Hidden flags no longer appear in help.
- Flags are sorted by name.
- Command, flag and argument descriptions line up in one column.
- Multi-line descriptions stay aligned (#14).
- Error output is flushed even when the caller skips its own flush.

#### Platforms and memory

- zli builds for Windows and WASI. Argument parsing no longer reads a POSIX-only field of the args iterator.
- `Command.init` frees everything when an allocation fails.

Full changelog: https://github.com/xcaeser/zli/compare/v5.1.4...v6.0.0
