## zli v6.2.0

### Added

- `PositionalArg.passthrough` (default `true`, which keeps v6.1.0 behavior). Set it to `false` on a variadic argument and flags keep parsing after the positionals, until `--`. With `passthrough = false` on `files`, `app merge a.pdf b.pdf -o out.pdf` passes `a.pdf` and `b.pdf` and sets `-o`.
- `ctx.flagValues("chain")` returns every value a flag was given, in order, as written. `app --chain a.pem --chain b.pem` gives `a.pem`, `b.pem`. Bool flags record `true` for `--x`, `false` for `--no-x`, and the text for `--x=false`. It accepts a name or a shortcut. A persistent flag given before a subcommand shows up in the subcommand's values. `ctx.flag` still returns the last value.
- `ctx.isFlagSet("greeting")` tells whether the command line gave the flag in any form. `--greeting=` is set (to an empty string), no `--greeting` is not set, and `--no-cache` sets `cache`.
- `InitOptions.error_writer`. Parse errors, deprecation notices and `run`'s `error: Name` line go there, so an app can send them to stderr while help and version stay on `writer`. It defaults to `writer`, and both writers are flushed on errors.
