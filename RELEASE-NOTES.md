## zli v7.1.0

### Added

- `InitOptions.environ_map`: pass `init.environ_map` from `main`, and every command reads the process environment as `ctx.environ_map` (#42). It is optional, so existing apps compile unchanged.

### Fixed

- CI tests and builds the docs on Zig 0.17.1, the version zli requires, and the README badge says 0.17.1.
