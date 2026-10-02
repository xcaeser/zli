## zli v5.1.4

### Fixed

- Commands no longer write a show-cursor escape (`ESC[?25h`) to stdout when they finish. `Spinner.deinit` emitted it unconditionally, so it ended up in piped and captured output; `stop()` already restores the cursor when the spinner was running.

Full changelog: https://github.com/xcaeser/zli/compare/v5.1.3...v5.1.4
