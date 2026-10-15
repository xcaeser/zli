//! Spinner indicator for long running operations
//!
//! Animates only when the writer is a terminal. Piped or redirected output gets
//! just the final `succeed`/`fail`/`warn`/`info`/`preserve` lines, without escape codes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const native_os = @import("builtin").os.tag;

const builtin = @import("builtin.zig");
const styles = builtin.styles;

const Spinner = @This();
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const clear_line = "\r\x1b[2K";
// Frames are drawn with autowrap off, so a message wider than the terminal is
// clipped instead of wrapping onto a line `clear_line` can't reach.
const wrap_off = "\x1b[?7l";
const wrap_on = "\x1b[?7h";

pub const SpinnerStyles = struct {
    pub const none = &.{""};
    pub const line = &.{ "-", "\\", "|", "/" };
    pub const arc = &.{ "◜", "◠", "◝", "◞", "◡", "◟" };
    pub const point = &.{ "∙∙∙", "●∙∙", "∙●∙", "∙∙●", "∙∙∙" };

    pub const dots = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const dots2 = &.{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
    pub const dots_wide = &.{ "⠉⠉", "⠈⠙", "⠀⠹", "⠀⢸", "⠀⣰", "⢀⣠", "⣀⣀", "⣄⡀", "⣆⠀", "⡇⠀", "⠏⠀", "⠋⠁" };
    pub const dots_circle = &.{ "⢎ ", "⠎⠁", "⠊⠑", "⠈⠱", " ⡱", "⢀⡰", "⢄⡠", "⢆⡀" };
    pub const dots_8bit = &.{ " ", "⠁", "⠂", "⠃", "⠄", "⠅", "⠆", "⠇", "⡀", "⡁", "⡂", "⡃", "⡄", "⡅", "⡆", "⡇", "⠈", "⠉", "⠊", "⠋", "⠌", "⠍", "⠎", "⠏", "⡈", "⡉", "⡊", "⡋", "⡌", "⡍", "⡎", "⡏", "⠐", "⠑", "⠒", "⠓", "⠔", "⠕", "⠖", "⠗", "⡐", "⡑", "⡒", "⡓", "⡔", "⡕", "⡖", "⡗", "⠘", "⠙", "⠚", "⠛", "⠜", "⠝", "⠞", "⠟", "⡘", "⡙", "⡚", "⡛", "⡜", "⡝", "⡞", "⡟", "⠠", "⠡", "⠢", "⠣", "⠤", "⠥", "⠦", "⠧", "⡠", "⡡", "⡢", "⡣", "⡤", "⡥", "⡦", "⡧", "⠨", "⠩", "⠪", "⠫", "⠬", "⠭", "⠮", "⠯", "⡨", "⡩", "⡪", "⡫", "⡬", "⡭", "⡮", "⡯", "⠰", "⠱", "⠲", "⠳", "⠴", "⠵", "⠶", "⠷", "⡰", "⡱", "⡲", "⡳", "⡴", "⡵", "⡶", "⡷", "⠸", "⠹", "⠺", "⠻", "⠼", "⠽", "⠾", "⠿", "⡸", "⡹", "⡺", "⡻", "⡼", "⡽", "⡾", "⡿", "⢀", "⢁", "⢂", "⢃", "⢄", "⢅", "⢆", "⢇", "⣀", "⣁", "⣂", "⣃", "⣄", "⣅", "⣆", "⣇", "⢈", "⢉", "⢊", "⢋", "⢌", "⢍", "⢎", "⢏", "⣈", "⣉", "⣊", "⣋", "⣌", "⣍", "⣎", "⣏", "⢐", "⢑", "⢒", "⢓", "⢔", "⢕", "⢖", "⢗", "⣐", "⣑", "⣒", "⣓", "⣔", "⣕", "⣖", "⣗", "⢘", "⢙", "⢚", "⢛", "⢜", "⢝", "⢞", "⢟", "⣘", "⣙", "⣚", "⣛", "⣜", "⣝", "⣞", "⣟", "⢠", "⢡", "⢢", "⢣", "⢤", "⢥", "⢦", "⢧", "⣠", "⣡", "⣢", "⣣", "⣤", "⣥", "⣦", "⣧", "⢨", "⢩", "⢪", "⢫", "⢬", "⢭", "⢮", "⢯", "⣨", "⣩", "⣪", "⣫", "⣬", "⣭", "⣮", "⣯", "⢰", "⢱", "⢲", "⢳", "⢴", "⢵", "⢶", "⢷", "⣰", "⣱", "⣲", "⣳", "⣴", "⣵", "⣶", "⣷", "⢸", "⢹", "⢺", "⢻", "⢼", "⢽", "⢾", "⢿", "⣸", "⣹", "⣺", "⣻", "⣼", "⣽", "⣾", "⣿" };
    pub const sand = &.{ "⠁", "⠂", "⠄", "⡀", "⡈", "⡐", "⢁", "⡠", "⣀", "⣁", "⣂", "⣄", "⣌", "⣔", "⣤", "⣥", "⣦", "⣮", "⣶", "⣷", "⣿", "⡿", "⠿", "⢟", "⠟", "⡛", "⠛", "⠫", "⢋", "⠋", "⠍", "⡉", "⠉", "⠑", "⠡" };
    pub const dots_scrolling = &.{ ".  ", ".. ", "...", " ..", "  .", "   " };
    pub const flip = &.{ "_", "_", "_", "-", "`", "`", "'", "´", "-", "_", "_", "_" };

    pub const aesthetic = &.{ "▰▰▱▱▱▱▱", "▰▱▱▱▱▱▱", "▰▰▰▱▱▱▱", "▰▰▰▰▱▱▱", "▰▰▰▰▰▱▱", "▰▰▰▰▰▰▱", "▰▰▰▰▰▰▰", "▰▱▱▱▱▱▱" };
    pub const bouncing_ball = &.{ "( ●    )", "(  ●   )", "(   ●  )", "(    ● )", "(     ●)", "(    ● )", "(   ●  )", "(  ●   )", "( ●    )", "(●     )" };
    pub const bouncing_bar = &.{ "[    ]", "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]", "[    ]", "[   =]", "[  ==]", "[ ===]", "[====]", "[=== ]", "[==  ]", "[=   ]" };

    pub const toggle = &.{ "◍", "◌" };
    pub const toggle2 = &.{ "□", "■" };
    pub const noise = &.{ "▓", "▒", "░" };
    pub const hamburger = &.{ "☱", "☲", "☴" };
    pub const triangle = &.{ "◢", "◣", "◤", "◥" };
    pub const box_bounce = &.{ "▌", "▀", "▐", "▄" };
    pub const circle_halves = &.{ "◐", "◓", "◑", "◒" };
    pub const star = &.{ "✶", "✸", "✹", "✺", "✹", "✷" };
    pub const grow_vertical = &.{ " ", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃" };

    pub const earth = &.{ "🌍", "🌎", "🌏" };
    pub const monkey = &.{ "🙈", "🙈", "🙉", "🙊" };
    pub const speaker = &.{ "🔈", "🔉", "🔊", "🔉" };
    pub const moon = &.{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" };
    pub const mindblown = &.{ "😐", "😐", "😮", "😮", "😦", "😦", "😧", "😧", "🤯", "💥", "✨" };
    pub const clock = &.{ "🕛", "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚" };
    pub const weather = &.{ "☀️", "☀️", "☀️", "🌤", "⛅️", "🌥", "☁️", "🌧", "🌨", "🌧", "🌨", "🌧", "🌨", "⛈", "🌨", "🌧", "🌨", "☁️", "🌥", "⛅️", "🌤", "☀️", "☀️" };
};

pub const Options = struct {
    /// Drawn before the message with a space between, e.g. `&.{ "+", "x" }`.
    frames: []const []const u8 = SpinnerStyles.dots,
    refresh_rate_ms: u64 = 80,
};

frames: []const []const u8,
refresh_rate_ms: u64,
message: []const u8,
frame_index: usize = 0,
allocator: Allocator,
io: Io,
writer: *Io.Writer,
/// The terminal `writer` writes to, or null when it isn't one (pipe, file, test buffer).
terminal: ?Io.File,
/// Whether a spinner line is on screen.
active: bool = false,
loop: ?Io.Future(void) = null,
stop_requested: Io.Event = .unset,
mutex: Io.Mutex = .init,

/// `.{}` gives `SpinnerStyles.dots` at 80ms.
pub fn init(io: Io, writer: *Io.Writer, allocator: Allocator, options: Options) Spinner {
    return Spinner{
        .io = io,
        .writer = writer,
        .allocator = allocator,
        .refresh_rate_ms = options.refresh_rate_ms,
        .frames = normalizeFrames(options.frames),
        .message = "",
        .terminal = terminalOf(io, writer),
    };
}

pub fn deinit(self: *Spinner) void {
    self.stop();
    self.replaceMessage("");
}

/// Prints a line above the spinner. Use this instead of writing to the writer
/// directly while a spinner runs. End `format` with a newline, or the next
/// frame overwrites it.
pub fn print(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    if (self.active) try self.writer.writeAll(clear_line);
    try self.writer.print(format, args);
}

/// Spins `format` on a new line, replacing any running spinner. End the line
/// with `succeed`, `fail`, `warn`, `info` or `preserve`; `stop` erases it.
pub fn start(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    self.stop();
    try self.updateMessage(format, args);
    const terminal = self.terminal orelse return;

    self.active = true;
    restoreCursorOnInterrupt(terminal);
    self.writer.writeAll(hide_cursor) catch {};
    self.loop = self.io.concurrent(spinLoop, .{self}) catch {
        // This Io can't run the animation alongside the caller: show one still frame.
        self.draw();
        return;
    };
}

pub fn stop(self: *Spinner) void {
    if (self.loop) |*loop| {
        self.stop_requested.set(self.io);
        loop.await(self.io);
        self.loop = null;
        self.stop_requested.reset();
    }

    if (!self.active) return;
    self.active = false;
    self.writer.writeAll(clear_line ++ show_cursor) catch {};
    self.writer.flush() catch {};
}

/// Replaces both frames and refresh rate; omitted fields go back to their defaults.
pub fn updateStyle(self: *Spinner, options: Options) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    self.frame_index = 0;
    self.frames = normalizeFrames(options.frames);
    self.refresh_rate_ms = options.refresh_rate_ms;
}

pub fn updateMessage(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    self.replaceMessage(try std.fmt.allocPrint(self.allocator, format, args));
}

pub fn succeed(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(styles.GREEN, "✔ ", format, args);
}

pub fn fail(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(styles.RED, "✖ ", format, args);
}

pub fn warn(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(styles.YELLOW, "⚠ ", format, args);
}

pub fn info(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(styles.BLUE, "i ", format, args);
}

/// Like `succeed`, but a neutral dim `»` line, e.g. for a log.
pub fn preserve(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(styles.DIM, "» ", format, args);
}

/// Stops the spinner, if any, and prints `symbol` and the message as a finished line.
fn finalize(self: *Spinner, comptime color: []const u8, comptime symbol: []const u8, comptime format: []const u8, args: anytype) !void {
    self.stop();
    self.replaceMessage("");

    if (self.terminal != null) {
        try self.writer.print(color ++ symbol ++ styles.RESET ++ format ++ "\n", args);
    } else {
        try self.writer.print(symbol ++ format ++ "\n", args);
    }
}

fn spinLoop(self: *Spinner) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        self.draw();
        self.frame_index = (self.frame_index + 1) % self.frames.len;
        const delay: Io.Duration = .fromMilliseconds(@intCast(self.refresh_rate_ms));
        self.mutex.unlock(self.io);

        // Sleep one frame, but wake as soon as `stop` asks.
        self.stop_requested.waitTimeout(self.io, .{ .duration = .{ .raw = delay, .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return,
        };
        return;
    }
}

/// Caller holds `mutex`, or no spin loop is running.
fn draw(self: *Spinner) void {
    const frame = self.frames[self.frame_index];
    const gap = if (frame.len == 0) "" else " ";
    self.writer.print(clear_line ++ wrap_off ++ "{s}{s}{s}" ++ wrap_on, .{ frame, gap, self.message }) catch {};
    self.writer.flush() catch {};
}

fn replaceMessage(self: *Spinner, new_message: []const u8) void {
    self.allocator.free(self.message); // no-op for the initial ""
    self.message = new_message;
}

fn normalizeFrames(frames: []const []const u8) []const []const u8 {
    return if (frames.len == 0) SpinnerStyles.none else frames;
}

fn terminalOf(io: Io, writer: *Io.Writer) ?Io.File {
    if (writer.vtable.drain != &Io.File.Writer.drain) return null;
    const file_writer: *Io.File.Writer = @alignCast(@fieldParentPtr("interface", writer));
    const is_tty = file_writer.file.isTty(io) catch false;
    return if (is_tty) file_writer.file else null;
}

var interrupt_fd: std.atomic.Value(posix.fd_t) = .init(-1);
var interrupt_handler_installed: std.atomic.Value(bool) = .init(false);
var prev_interrupt_action: posix.Sigaction = undefined;

/// Ctrl+C would otherwise kill the process with the cursor still hidden.
/// Installs, once, a SIGINT handler that shows it again and then passes the
/// signal on to whatever handled it before.
fn restoreCursorOnInterrupt(terminal: Io.File) void {
    if (native_os == .windows or native_os == .wasi) return;

    interrupt_fd.store(terminal.handle, .monotonic);
    if (interrupt_handler_installed.swap(true, .monotonic)) return;

    const action: posix.Sigaction = .{
        .handler = .{ .handler = onInterrupt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, &prev_interrupt_action);
    // Leave an ignored SIGINT ignored.
    if (prev_interrupt_action.handler.handler == posix.SIG.IGN) posix.sigaction(.INT, &prev_interrupt_action, null);
}

fn onInterrupt(_: posix.SIG) callconv(.c) void {
    const restore = "\n" ++ show_cursor;
    _ = posix.system.write(interrupt_fd.load(.monotonic), restore, restore.len);
    posix.sigaction(.INT, &prev_interrupt_action, null);
    posix.raise(.INT) catch {};
}
