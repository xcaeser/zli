const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin.zig");
pub const styles = builtin.styles;

var g_active_spinner: ?*Spinner = null;

/// Progress indicator for long running operations
const Spinner = @This();

/// The state of an individual line managed by the spinner.
const LineState = enum {
    spinning,
    succeeded,
    failed,
    info,
    /// A static line (e.g., a log) that is not part of the active spinner.
    preserved,
};

const SpinnerLine = struct {
    message: []const u8,
    state: LineState,
};

pub const SpinnerStyles = struct {
    pub const dots = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const dots2 = &.{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
    pub const circle = &.{ "◐", "◓", "◑", "◒" };
    pub const line = &.{ "-", "\\", "|", "/" };
    pub const simple_dots_scrolling = &.{ ".  ", ".. ", "...", " ..", "  .", "   " };
    pub const star = &.{ "✶", "✸", "✹", "✺", "✹", "✷" };
    pub const clock = &.{ "🕛", "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚" };
    pub const triangle = &.{ "◢", "◣", "◤", "◥" };
    pub const bouncing_bar = &.{ "[    ]", "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]", "[    ]", "[   =]", "[  ==]", "[ ===]", "[====]", "[=== ]", "[==  ]", "[=   ]" };
    pub const grow_vertical = &.{ " ", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃" };
};

pub const SpinnerOptions = struct {
    frames: []const []const u8 = SpinnerStyles.dots,
    interval_ms: u64 = 80,
};

frames: []const []const u8,
interval: u64,

lines: std.ArrayList(SpinnerLine),
is_running: std.atomic.Value(bool),
thread: ?std.Thread = null,
frame_index: usize = 0,
lines_drawn: usize = 0,

writer: *Writer,
mutex: std.Thread.Mutex = .{},
allocator: Allocator,

// For signal handling
prev_handler: std.posix.Sigaction,
handler_installed: bool,

/// Initialize a new spinner. Does not start it.
pub fn init(writer: *Writer, allocator: Allocator, options: SpinnerOptions) !*Spinner {
    const spinner = try allocator.create(Spinner);

    const owned_frames = try allocator.dupe([]const u8, options.frames);
    errdefer allocator.free(owned_frames);

    spinner.* = Spinner{
        .allocator = allocator,
        .writer = writer,
        .frames = owned_frames,
        .interval = options.interval_ms * std.time.ns_per_ms,
        .is_running = std.atomic.Value(bool).init(false),
        .lines = std.ArrayList(SpinnerLine).empty,
        .prev_handler = undefined,
        .handler_installed = false,
    };

    if (g_active_spinner == null) {
        g_active_spinner = spinner;
        var new_action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleInterrupt },
            .mask = std.posix.sigemptyset(), // Use std.posix
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &new_action, &spinner.prev_handler);
        spinner.handler_installed = true;
    }

    return spinner;
}

/// Stops the spinner if it's running and frees allocated memory.
pub fn deinit(self: *Spinner) void {
    if (self.handler_installed) {
        std.posix.sigaction(std.posix.SIG.INT, &self.prev_handler, null);
        g_active_spinner = null;
        self.handler_installed = false;
    }
    if (self.is_running.load(.monotonic)) {
        self.stop() catch {};
    }
    for (self.lines.items) |line| self.allocator.free(line.message);
    self.lines.deinit(self.allocator);
    self.allocator.free(self.frames);
    self.allocator.destroy(self);
}

/// Starts the spinner animation in a background thread.
pub fn start(self: *Spinner, options: SpinnerOptions, comptime format: []const u8, args: anytype) !void {
    if (self.is_running.load(.monotonic)) return; // Already running

    self.mutex.lock();
    defer self.mutex.unlock();

    // Free the old frames and duplicate the new ones
    self.allocator.free(self.frames);
    self.frames = try self.allocator.dupe([]const u8, options.frames);
    self.interval = options.interval_ms * std.time.ns_per_ms;

    // Clear any previous state
    for (self.lines.items) |line| self.allocator.free(line.message);
    self.lines.clearRetainingCapacity();
    self.lines_drawn = 0;
    self.frame_index = 0;

    const message = try std.fmt.allocPrint(self.allocator, format, args);
    errdefer self.allocator.free(message);

    try self.lines.append(self.allocator, .{ .message = message, .state = .spinning });

    self.is_running.store(true, .release);
    self.thread = try std.Thread.spawn(.{}, spinLoop, .{self});
}

/// Stops the spinner animation and waits for the background thread to exit.
pub fn stop(self: *Spinner) !void {
    if (!self.is_running.load(.monotonic)) return;

    self.is_running.store(false, .release);

    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    // Final redraw to leave terminal clean
    try self.render(false);
    // Show cursor
    try self.writer.print("\x1b[?25h", .{});
}

/// Stops the spinner and marks the final step as successful.
pub fn succeed(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.succeeded, format, args);
}

/// Stops the spinner and marks the final step as failed.
pub fn fail(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.failed, format, args);
}

/// Stops the spinner and marks the final step with an info icon.
pub fn info(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.info, format, args);
}

/// Updates the text of the current spinning line.
pub fn updateText(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    const new_text = try std.fmt.allocPrint(self.allocator, format, args);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.findLastSpinningLine()) |line| {
        self.allocator.free(line.message);
        line.message = new_text;
    } else {
        // If no spinning line, just free the new text as there's nothing to update.
        self.allocator.free(new_text);
    }
}

/// Marks the current step as successful and starts a new spinning step.
pub fn nextStep(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    const new_text = try std.fmt.allocPrint(self.allocator, format, args);
    errdefer self.allocator.free(new_text);

    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.findLastSpinningLine()) |line| {
        line.state = .succeeded;
    }

    try self.lines.append(self.allocator, .{ .message = new_text, .state = .spinning });
}

/// Adds a static, preserved line of text (like a log) above the spinner.
/// It will be printed on the next frame and will not be cleared.
pub fn addLine(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(self.allocator, format, args);

    self.mutex.lock();
    defer self.mutex.unlock();

    // To preserve a line, we insert it *before* the first spinning line.
    var i: usize = 0;
    while (i < self.lines.items.len) : (i += 1) {
        if (self.lines.items[i].state == .spinning) break;
    }

    try self.lines.insert(self.allocator, i, .{ .message = message, .state = .preserved });
}

fn finalize(self: *Spinner, final_state: LineState, comptime format: []const u8, args: anytype) !void {
    self.mutex.lock();
    const new_text = try std.fmt.allocPrint(self.allocator, format, args);
    if (self.findLastSpinningLine()) |line| {
        self.allocator.free(line.message);
        line.message = new_text;
        line.state = final_state;
    } else {
        // If there was no spinning line, create one with the final state.
        try self.lines.append(self.allocator, .{ .message = new_text, .state = final_state });
    }
    self.mutex.unlock();
    try self.stop();
}

/// Finds the last line that is currently in a 'spinning' state.
fn findLastSpinningLine(self: *Spinner) ?*SpinnerLine {
    // Use a while loop for safe backward iteration.
    var i = self.lines.items.len;
    while (i > 0) {
        i -= 1;
        if (self.lines.items[i].state == .spinning) {
            return &self.lines.items[i];
        }
    }
    return null;
}

/// Erases the lines drawn in the previous frame.
fn erase(self: *Spinner) !void {
    if (self.lines_drawn == 0) return;
    // Move cursor up N lines
    try self.writer.print("\r\x1b[{d}A", .{self.lines_drawn});
    // Clear from cursor to end of screen
    try self.writer.print("\x1b[J", .{});
}

/// Renders all lines based on their current state.
fn render(self: *Spinner, is_spinning: bool) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Erase previous spinner output
    try self.erase();

    const lines_to_draw = self.lines.items;
    var drawn_count: usize = 0;

    for (lines_to_draw) |line| {
        // The .spinning state is the only one with a dynamic (runtime) prefix.
        // We must handle it separately to avoid illegal comptime concatenation.
        if (line.state == .spinning and is_spinning) {
            const frame = self.frames[self.frame_index];
            // Use runtime formatting to combine the parts.
            try self.writer.print("{s}{s}{s} {s}\n", .{ styles.CYAN, frame, styles.RESET, line.message });
        } else {
            // All other cases use static prefixes that can be concatenated at compile-time.
            // This includes the "paused" spinning state.
            const prefix = switch (line.state) {
                .spinning => styles.CYAN ++ " " ++ styles.RESET, // Paused state icon
                .succeeded => styles.GREEN ++ "✔" ++ styles.RESET,
                .failed => styles.RED ++ "✖" ++ styles.RESET,
                .info => styles.BLUE ++ "ℹ" ++ styles.RESET,
                .preserved => styles.DIM ++ "»" ++ styles.RESET,
            };
            try self.writer.print("{s} {s}\n", .{ prefix, line.message });
        }
        drawn_count += 1;
    }

    self.lines_drawn = drawn_count;

    if (is_spinning) {
        self.frame_index = (self.frame_index + 1) % self.frames.len;
    }
}

/// The main loop for the background thread.
fn spinLoop(self: *Spinner) void {
    // Hide cursor
    self.writer.print("\x1b[?25l", .{}) catch return;
    defer self.writer.print("\x1b[?25h", .{}) catch {};

    while (self.is_running.load(.acquire)) {
        self.render(true) catch {
            // If rendering fails, stop the spinner to prevent broken output.
            self.is_running.store(false, .release);
            break;
        };
        std.time.sleep(self.interval);
        // try std.Thread.yield();
    }
}

fn handleInterrupt(signum: c_int) callconv(.c) void {
    _ = signum; // We know it's SIGINT but don't need to use the value.

    if (g_active_spinner) |spinner| {
        spinner.stop() catch {};
    }

    // After cleanup, exit the program with an error code
    // indicating it was interrupted. 130 is the standard for this.
    std.process.exit(130);
}
