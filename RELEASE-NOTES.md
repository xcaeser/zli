## zli v5.1.0

This release focuses on smoother command parsing, persistent flags, and friendlier onboarding for new users.

### Migration note

- CLI binaries should call `Command.runAndExit`; `Command.execute` now returns parser/execution errors for tests, embedding, and custom error handling instead of exiting the process directly.

### Added

- Added persistent flags with `.persistent = true`, so parent command flags are automatically available to registered subcommands.
- Added support for negated boolean flags using `--no-flag`, which sets boolean flags to `false`.
- Added `Command.runAndExit` for full CLI binaries that should terminate with process exit codes.
- Added the public `CommandErrors` error set for command parsing and validation failures.
- Added explicit command error aliases to function signatures for setup, parsing, and printing flows.
- Added a single-file quick start in the README showing root command initialization, execution, flags, and a subcommand without splitting the CLI across multiple files.
- Added Zig `0.16.0` package metadata via `.minimum_zig_version`.

### Improved

- Reworked command argument parsing to handle command traversal, long flags, grouped short flags, flag values, and positional arguments through a single parser flow.
- Improved validation and error messages for missing flag values, invalid flag values, unknown flags, unknown commands, and positional argument count mismatches.
- Kept `Command.execute` library-friendly by returning parser/execution errors instead of exiting directly.
- Improved version output by flushing the writer after `printVersion`.
- Updated README badges and install command for `v5.1.0`.

### Changed

- Replaced older inline flag parsing internals with the new parser path used by `Command.execute`.
- Marked persistent flags as complete in the README feature checklist.
- Added `.DS_Store` and `.idea` to `.gitignore`.

Full changelog: https://github.com/xcaeser/zli/compare/v5.0.0...v5.1.0
