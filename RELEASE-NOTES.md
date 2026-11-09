## zli v7.0.0

### Breaking

- `addCommand` and `addCommands` return `CommandSetupErrors!void` instead of `Allocator.Error!void`, and `CommandErrors` has a new `DuplicateCommand`. Code that names `Allocator.Error` around these calls, or switches exhaustively on `CommandErrors`, needs updating.
- `addCommand` refuses, with `DuplicateCommand` and one line on the error writer, a name the parent already has, a command that already has a parent, and a command added to itself or one of its ancestors. These used to leak the first command, free one twice, or hang `deinit`. On any error the command is still yours to `deinit`.
- A persistent flag is now one definition, on the command that declares it, and subcommands see it through their parents instead of getting a copy. A subcommand's own flag of the same name wins, by name and by shortcut, whatever order flags and commands were added in. Before, a sub's Int `--level` read the root's Bool value, and which definition won depended on the order.
- The built-in `help` flag is no longer persistent; every command has its own. `app --help sub` still shows `sub`'s help, but redefining `help` on the root no longer changes it on subcommands.
- Requires Zig 0.17.1.

### Added

- `CommandOptions.help_footer`: your own message, printed last in that command's help. Subcommands don't inherit it.

### Fixed

- Each `run`/`execute` starts from the flag defaults. A second run on the same command tree used to keep the previous run's flags, so `app --help` followed by `app` printed help again.
- An allocation failure partway through `addCommand` no longer leaves the command half-owned by the parent, which caused a double free.
- Redefining a flag drops the shortcut of its old definition, so `-h` no longer reaches the old `help` after you redefine it with another shortcut.
- A `help` flag redefined as a non-Bool type is an ordinary flag instead of a panic on every run.
- The spinner's Ctrl+C handler is installed only while a spinner runs on a terminal, and puts your previous handler back on `stop`. After a Ctrl+C your app survives, the next spinner restores the cursor again, and a Ctrl+C after `stop` no longer prints a stray escape sequence.
- Help leaves out the blank line after Flags when every flag is hidden.
- The README's multi-file example compiles.
