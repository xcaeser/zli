//! Spinner indicator for long running operations

const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;

const builtin = @import("builtin.zig");
pub const styles = builtin.styles;

const Spinner = @This();
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const clear_line = "\r\x1b[2K";

pub const SpinnerStyles = union(enum) {
    pub const none = &.{""};
    pub const line = &.{ "- ", "\\ ", "| ", "/ " };
    pub const arc = &.{ "◜ ", "◠ ", "◝ ", "◞ ", "◡ ", "◟ " };
    pub const point = &.{ "∙∙∙ ", "●∙∙ ", "∙●∙ ", "∙∙● ", "∙∙∙ " };

    pub const dots = &.{ "⠋ ", "⠙ ", "⠹ ", "⠸ ", "⠼ ", "⠴ ", "⠦ ", "⠧ ", "⠇ ", "⠏ " };
    pub const dots2 = &.{ "⣼ ", "⣹ ", "⢻ ", "⠿ ", "⡟ ", "⣏ ", "⣧ ", "⣶ " };
    pub const dots_wide = &.{ "⠉⠉ ", "⠈⠙ ", "⠀⠹ ", "⠀⢸ ", "⠀⣰ ", "⢀⣠ ", "⣀⣀ ", "⣄⡀ ", "⣆⠀ ", "⡇⠀ ", "⠏⠀ ", "⠋⠁ " };
    pub const dots_circle = &.{ "⢎  ", "⠎⠁ ", "⠊⠑ ", "⠈⠱ ", " ⡱ ", "⢀⡰ ", "⢄⡠ ", "⢆⡀ " };
    pub const dots_8bit = &.{ "  ", "⠁ ", "⠂ ", "⠃ ", "⠄ ", "⠅ ", "⠆ ", "⠇ ", "⡀ ", "⡁ ", "⡂ ", "⡃ ", "⡄ ", "⡅ ", "⡆ ", "⡇ ", "⠈ ", "⠉ ", "⠊ ", "⠋ ", "⠌ ", "⠍ ", "⠎ ", "⠏ ", "⡈ ", "⡉ ", "⡊ ", "⡋ ", "⡌ ", "⡍ ", "⡎ ", "⡏ ", "⠐ ", "⠑ ", "⠒ ", "⠓ ", "⠔ ", "⠕ ", "⠖ ", "⠗ ", "⡐ ", "⡑ ", "⡒ ", "⡓ ", "⡔ ", "⡕ ", "⡖ ", "⡗ ", "⠘ ", "⠙ ", "⠚ ", "⠛ ", "⠜ ", "⠝ ", "⠞ ", "⠟ ", "⡘ ", "⡙ ", "⡚ ", "⡛ ", "⡜ ", "⡝ ", "⡞ ", "⡟ ", "⠠ ", "⠡ ", "⠢ ", "⠣ ", "⠤ ", "⠥ ", "⠦ ", "⠧ ", "⡠ ", "⡡ ", "⡢ ", "⡣ ", "⡤  ", "⡥ ", "⡦ ", "⡧ ", "⠨ ", "⠩ ", "⠪ ", "⠫ ", "⠬ ", "⠭ ", "⠮ ", "⠯ ", "⡨ ", "⡩ ", "⡪ ", "⡫ ", "⡬ ", "⡭ ", "⡮ ", "⡯ ", "⠰ ", "⠱ ", "⠲ ", "⠳ ", "⠴ ", "⠵ ", "⠶ ", "⠷ ", "⡰ ", "⡱ ", "⡲ ", "⡳ ", "⡴ ", "⡵ ", "⡶ ", "⡷ ", "⠸ ", "⠹ ", "⠺ ", "⠻ ", "⠼ ", "⠽ ", "⠾ ", "⠿ ", "⡸ ", "⡹ ", "⡺ ", "⡻ ", "⡼ ", "⡽ ", "⡾ ", "⡿ ", "⢀ ", "⢁ ", "⢂ ", "⢃ ", "⢄ ", "⢅ ", "⢆ ", "⢇ ", "⣀ ", "⣁ ", "⣂ ", "⣃ ", "⣄ ", "⣅ ", "⣆ ", "⣇ ", "⢈ ", "⢉ ", "⢊ ", "⢋ ", "⢌ ", "⢍ ", "⢎ ", "⢏ ", "⣈ ", "⣉ ", "⣊ ", "⣋ ", "⣌ ", "⣍ ", "⣎ ", "⣏ ", "⢐ ", "⢑ ", "⢒ ", "⢓ ", "⢔ ", "⢕ ", "⢖ ", "⢗ ", "⣐ ", "⣑ ", "⣒ ", "⣓ ", "⣔ ", "⣕ ", "⣖ ", "⣗ ", "⢘ ", "⢙ ", "⢚ ", "⢛ ", "⢜ ", "⢝ ", "⢞ ", "⢟ ", "⣘ ", "⣙ ", "⣚ ", "⣛ ", "⣜ ", "⣝ ", "⣞ ", "⣟ ", "⢠ ", "⢡ ", "⢢ ", "⢣ ", "⢤ ", "⢥ ", "⢦ ", "⢧ ", "⣠ ", "⣡ ", "⣢ ", "⣣ ", "⣤ ", "⣥ ", "⣦ ", "⣧ ", "⢨ ", "⢩ ", "⢪ ", "⢫ ", "⢬ ", "⢭ ", "⢮ ", "⢯ ", "⣨ ", "⣩ ", "⣪ ", "⣫ ", "⣬ ", "⣭ ", "⣮ ", "⣯ ", "⢰ ", "⢱ ", "⢲ ", "⢳ ", "⢴ ", "⢵ ", "⢶ ", "⢷ ", "⣰ ", "⣱ ", "⣲ ", "⣳ ", "⣴ ", "⣵ ", "⣶ ", "⣷ ", "⢸ ", "⢹ ", "⢺ ", "⢻ ", "⢼ ", "⢽ ", "⢾ ", "⢿ ", "⣸ ", "⣹ ", "⣺ ", "⣻ ", "⣼ ", "⣽ ", "⣾ ", "⣿ " };
    pub const sand = &.{ "⠁ ", "⠂ ", "⠄ ", "⡀ ", "⡈ ", "⡐ ", "⢁ ", "⡠ ", "⣀ ", "⣁ ", "⣂ ", "⣄ ", "⣌ ", "⣔ ", "⣤ ", "⣥ ", "⣦ ", "⣮ ", "⣶ ", "⣷ ", "⣿ ", "⡿ ", "⠿ ", "⢟ ", "⠟ ", "⡛ ", "⠛ ", "⠫ ", "⢋ ", "⠋ ", "⠍ ", "⡉ ", "⠉ ", "⠑ ", "⠡ " };
    pub const dots_scrolling = &.{ ".   ", "..  ", "... ", " .. ", "  . ", "    " };
    pub const flip = &.{ "_ ", "_ ", "_ ", "- ", "` ", "` ", "' ", "´ ", "- ", "_ ", "_ ", "_ " };

    pub const aesthetic = &.{ "▰▰▱▱▱▱▱ ", "▰▱▱▱▱▱▱ ", "▰▰▰▱▱▱▱ ", "▰▰▰▰▱▱▱ ", "▰▰▰▰▰▱▱ ", "▰▰▰▰▰▰▱ ", "▰▰▰▰▰▰▰ ", "▰▱▱▱▱▱▱ " };
    pub const bouncing_ball = &.{ "( ●    ) ", "(  ●   ) ", "(   ●  ) ", "(    ● ) ", "(     ●) ", "(    ● ) ", "(   ●  ) ", "(  ●   ) ", "( ●    ) ", "(●     ) " };
    pub const bouncing_bar = &.{ "[    ] ", "[=   ] ", "[==  ] ", "[=== ] ", "[ ===] ", "[  ==] ", "[   =] ", "[    ] ", "[   =] ", "[  ==] ", "[ ===] ", "[====] ", "[=== ] ", "[==  ] ", "[=   ] " };

    pub const toggle = &.{ "◍ ", "◌ " };
    pub const toggle2 = &.{ "□ ", "■ " };
    pub const noise = &.{ "▓ ", "▒ ", "░ " };
    pub const hamburger = &.{ "☱ ", "☲ ", "☴ " };
    pub const triangle = &.{ "◢ ", "◣ ", "◤ ", "◥ " };
    pub const box_bounce = &.{ "▌ ", "▀ ", "▐ ", "▄ " };
    pub const circle_halvess = &.{ "◐ ", "◓ ", "◑ ", "◒ " };
    pub const star = &.{ "✶ ", "✸ ", "✹ ", "✺ ", "✹ ", "✷ " };
    pub const grow_vertical = &.{ "  ", "▃ ", "▄ ", "▅ ", "▆ ", "▇ ", "▆ ", "▅ ", "▄ ", "▃ " };

    pub const earth = &.{ "🌍 ", "🌎 ", "🌏 " };
    pub const monkey = &.{ "🙈 ", "🙈 ", "🙉 ", "🙊 " };
    pub const speaker = &.{ "🔈 ", "🔉 ", "🔊 ", "🔉 " };
    pub const moon = &.{ "🌑 ", "🌒 ", "🌓 ", "🌔 ", "🌕 ", "🌖 ", "🌗 ", "🌘 " };
    pub const mindblown = &.{ "😐 ", "😐 ", "😮 ", "😮 ", "😦 ", "😦 ", "😧 ", "😧 ", "🤯 ", "💥 ", "✨ " };
    pub const clock = &.{ "🕛 ", "🕐 ", "🕑 ", "🕒 ", "🕓 ", "🕔 ", "🕕 ", "🕖 ", "🕗 ", "🕘 ", "🕙 ", "🕚 " };
    pub const weather = &.{ "☀️ ", "☀️ ", "☀️ ", "🌤 ", "⛅️ ", "🌥 ", "☁️ ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "⛈ ", "🌨 ", "🌧 ", "🌨 ", "☁️ ", "🌥 ", "⛅️ ", "🌤 ", "☀️ ", "☀️ " };
};

/// The state of an individual line managed by the spinner.
const State = enum {
    success,
    fail,
    info,
    /// A static line (e.g., a log) that is not part of the active spinner.
    preserve,
};

pub const SpinnerOptions = struct {
    frames: []const []const u8 = SpinnerStyles.dots,
    refresh_rate_ms: u64 = 80,
};

frames: []const []const u8,
refresh_rate_ms: u64,
message: []const u8,
is_spinning: std.atomic.Value(bool),
frame_index: std.atomic.Value(usize),
allocator: Allocator,
io: Io,
writer: *Io.Writer,
reader: *Io.Reader,
thread: ?Thread = null,
mutex: Io.Mutex = .{ .state = .init(.unlocked) },

/// Initiate a new Spinner instance.
///
/// If no options are provided `init(..., .{})`, the default spinner will be dots with a 80ms refresh rate.
///
/// Use `Spinner.SpinnerStyles.[option]` or pass in `.{ .frames = " []const []const u8 " }` for a custom style.
///
pub fn init(io: Io, writer: *Io.Writer, reader: *Io.Reader, allocator: Allocator, options: SpinnerOptions) Spinner {
    return Spinner{
        .io = io,
        .writer = writer,
        .reader = reader,
        .allocator = allocator,
        .is_spinning = std.atomic.Value(bool).init(false),
        .frame_index = std.atomic.Value(usize).init(0),
        .refresh_rate_ms = options.refresh_rate_ms,
        .frames = normalizeFrames(options.frames),
        .message = "",
    };
}

pub fn deinit(self: *Spinner) void {
    self.stop();
    self.showCursor();
    if (self.message.len > 0) {
        self.allocator.free(self.message);
        self.message = "";
    }
}

pub fn print(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    self.writer.print(clear_line, .{}) catch {};
    try self.writer.print(format, args);
}

pub fn start(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    self.stop();

    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const new_message = try std.fmt.allocPrint(self.allocator, format, args);

    if (self.message.len > 0) {
        self.allocator.free(self.message);
    }
    self.message = new_message;

    self.is_spinning.store(true, .release);

    self.hideCursor();
    self.thread = Thread.spawn(.{}, spinLoop, .{self}) catch |err| {
        self.is_spinning.store(false, .release);
        self.showCursor();
        self.allocator.free(self.message);
        self.message = "";
        return err;
    };
}

pub fn stop(self: *Spinner) void {
    const was_spinning = self.is_spinning.swap(false, .acq_rel);

    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    if (was_spinning) {
        self.writer.print(clear_line, .{}) catch {};
        self.showCursor();
    }
}

pub fn updateStyle(self: *Spinner, options: SpinnerOptions) void {
    self.mutex.lock(self.io) catch return;
    defer self.mutex.unlock(self.io);

    self.frame_index.store(0, .release);

    self.frames = normalizeFrames(options.frames);
    self.refresh_rate_ms = options.refresh_rate_ms;
}

pub fn updateMessage(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    const new_message = try std.fmt.allocPrint(self.allocator, format, args);

    if (self.message.len > 0) {
        self.allocator.free(self.message);
    }
    self.message = new_message;
}

pub fn succeed(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.success, format, args);
}

pub fn fail(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.fail, format, args);
}

pub fn info(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.info, format, args);
}

pub fn preserve(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    try self.finalize(.preserve, format, args);
}

fn finalize(self: *Spinner, state: State, comptime format: []const u8, args: anytype) !void {
    if (!self.is_spinning.load(.monotonic)) return;

    self.stop();

    const ticker = switch (state) {
        .success => styles.GREEN ++ "✔ " ++ styles.RESET,
        .fail => styles.RED ++ "✖ " ++ styles.RESET,
        .info => styles.BLUE ++ "i " ++ styles.RESET,
        .preserve => styles.DIM ++ "» " ++ styles.RESET,
    };

    const new_message = try std.fmt.allocPrint(self.allocator, format, args);

    self.writer.print(clear_line, .{}) catch {};

    try self.writer.print("{s}{s}\n", .{ ticker, new_message });

    if (self.message.len > 0) {
        self.allocator.free(self.message);
    }
    self.allocator.free(new_message);
    self.message = "";
}

fn spinLoop(self: *Spinner) void {
    while (self.is_spinning.load(.acquire)) {
        self.mutex.lock(self.io) catch {
            self.io.sleep(.fromMilliseconds(@intCast(self.refresh_rate_ms)), .real) catch {};
            continue;
        };

        const index = self.frame_index.load(.acquire);
        self.writer.print(clear_line, .{}) catch {};
        self.writer.print("{s}{s}", .{ self.frames[index], self.message }) catch {};
        self.writer.flush() catch {};

        self.frame_index.store((index + 1) % self.frames.len, .release);
        const refresh_rate_ms = self.refresh_rate_ms;
        self.mutex.unlock(self.io);

        self.io.sleep(.fromMilliseconds(@intCast(refresh_rate_ms)), .real) catch {};
    }
}

fn normalizeFrames(frames: []const []const u8) []const []const u8 {
    return if (frames.len == 0) SpinnerStyles.none else frames;
}

fn hideCursor(self: *Spinner) void {
    self.writer.print(hide_cursor, .{}) catch {};
    self.writer.flush() catch {};
}

fn showCursor(self: *Spinner) void {
    self.writer.print(show_cursor, .{}) catch {};
    self.writer.flush() catch {};
}
