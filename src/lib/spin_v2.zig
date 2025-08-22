//! Progress indicator for long running operations

const std = @import("std");
const Io = std.Io;
const ArrayList = std.ArrayList;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin.zig");
pub const styles = builtin.styles;

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

pub const SpinnerStyles = union(enum) {
    pub const dots = &.{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    pub const dots2 = &.{ "⠉⠉", "⠈⠙", "⠀⠹", "⠀⢸", "⠀⣰", "⢀⣠", "⣀⣀", "⣄⡀", "⣆⠀", "⡇⠀", "⠏⠀", "⠋⠁" };
    pub const dots3 = &.{ "⣼", "⣹", "⢻", "⠿", "⡟", "⣏", "⣧", "⣶" };
    pub const dots_circle = &.{ "⢎ ", "⠎⠁", "⠊⠑", "⠈⠱", " ⡱", "⢀⡰", "⢄⡠", "⢆⡀" };
    pub const dots_8bit = &.{ " ", "⠁", "⠂", "⠃", "⠄", "⠅", "⠆", "⠇", "⡀", "⡁", "⡂", "⡃", "⡄", "⡅", "⡆", "⡇", "⠈", "⠉", "⠊", "⠋", "⠌", "⠍", "⠎", "⠏", "⡈", "⡉", "⡊", "⡋", "⡌", "⡍", "⡎", "⡏", "⠐", "⠑", "⠒", "⠓", "⠔", "⠕", "⠖", "⠗", "⡐", "⡑", "⡒", "⡓", "⡔", "⡕", "⡖", "⡗", "⠘", "⠙", "⠚", "⠛", "⠜", "⠝", "⠞", "⠟", "⡘", "⡙", "⡚", "⡛", "⡜", "⡝", "⡞", "⡟", "⠠", "⠡", "⠢", "⠣", "⠤", "⠥", "⠦", "⠧", "⡠", "⡡", "⡢", "⡣", "⡤", "⡥", "⡦", "⡧", "⠨", "⠩", "⠪", "⠫", "⠬", "⠭", "⠮", "⠯", "⡨", "⡩", "⡪", "⡫", "⡬", "⡭", "⡮", "⡯", "⠰", "⠱", "⠲", "⠳", "⠴", "⠵", "⠶", "⠷", "⡰", "⡱", "⡲", "⡳", "⡴", "⡵", "⡶", "⡷", "⠸", "⠹", "⠺", "⠻", "⠼", "⠽", "⠾", "⠿", "⡸", "⡹", "⡺", "⡻", "⡼", "⡽", "⡾", "⡿", "⢀", "⢁", "⢂", "⢃", "⢄", "⢅", "⢆", "⢇", "⣀", "⣁", "⣂", "⣃", "⣄", "⣅", "⣆", "⣇", "⢈", "⢉", "⢊", "⢋", "⢌", "⢍", "⢎", "⢏", "⣈", "⣉", "⣊", "⣋", "⣌", "⣍", "⣎", "⣏", "⢐", "⢑", "⢒", "⢓", "⢔", "⢕", "⢖", "⢗", "⣐", "⣑", "⣒", "⣓", "⣔", "⣕", "⣖", "⣗", "⢘", "⢙", "⢚", "⢛", "⢜", "⢝", "⢞", "⢟", "⣘", "⣙", "⣚", "⣛", "⣜", "⣝", "⣞", "⣟", "⢠", "⢡", "⢢", "⢣", "⢤", "⢥", "⢦", "⢧", "⣠", "⣡", "⣢", "⣣", "⣤", "⣥", "⣦", "⣧", "⢨", "⢩", "⢪", "⢫", "⢬", "⢭", "⢮", "⢯", "⣨", "⣩", "⣪", "⣫", "⣬", "⣭", "⣮", "⣯", "⢰", "⢱", "⢲", "⢳", "⢴", "⢵", "⢶", "⢷", "⣰", "⣱", "⣲", "⣳", "⣴", "⣵", "⣶", "⣷", "⢸", "⢹", "⢺", "⢻", "⢼", "⢽", "⢾", "⢿", "⣸", "⣹", "⣺", "⣻", "⣼", "⣽", "⣾", "⣿" };
    pub const sand = &.{ "⠁", "⠂", "⠄", "⡀", "⡈", "⡐", "⡠", "⣀", "⣁", "⣂", "⣄", "⣌", "⣔", "⣤", "⣥", "⣦", "⣮", "⣶", "⣷", "⣿", "⡿", "⠿", "⢟", "⠟", "⡛", "⠛", "⠫", "⢋", "⠋", "⠍", "⡉", "⠉", "⠑", "⠡", "⢁" };
    pub const dots_scrolling = &.{ ".  ", ".. ", "...", " ..", "  .", "   " };
    pub const box_bounce = &.{ "▌", "▀", "▐", "▄" };
    pub const noise = &.{ "▓", "▒", "░" };
    pub const grow_vertical = &.{ " ", "▃", "▄", "▅", "▆", "▇", "▆", "▅", "▄", "▃" };
    pub const aesthetic = &.{ "▰▱▱▱▱▱▱", "▰▰▱▱▱▱▱", "▰▰▰▱▱▱▱", "▰▰▰▰▱▱▱", "▰▰▰▰▰▱▱", "▰▰▰▰▰▰▱", "▰▰▰▰▰▰▰", "▰▱▱▱▱▱▱" };
    pub const bouncing_ball = &.{ "( ●    )", "(  ●   )", "(   ●  )", "(    ● )", "(     ●)", "(    ● )", "(   ●  )", "(  ●   )", "( ●    )", "(●     )" };
    pub const bouncing_bar = &.{ "[    ]", "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]", "[    ]", "[   =]", "[  ==]", "[ ===]", "[====]", "[=== ]", "[==  ]", "[=   ]" };

    pub const line = &.{ "-", "\\", "|", "/" };
    pub const arc = &.{ "◜", "◠", "◝", "◞", "◡", "◟" };
    pub const point = &.{ "∙∙∙", "●∙∙", "∙●∙", "∙∙●", "∙∙∙" };

    pub const toggle = &.{ "◍", "◌" };
    pub const circle_halvess = &.{ "◐", "◓", "◑", "◒" };
    pub const triangle = &.{ "◢", "◣", "◤", "◥" };
    pub const star = &.{ "✶", "✸", "✹", "✺", "✹", "✷" };

    pub const earth = &.{ "🌍", "🌎", "🌏" };
    pub const monkey = &.{ "🙈", "🙈", "🙉", "🙊" };
    pub const moon = &.{ "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" };
    pub const clock = &.{ "🕛", "🕐", "🕑", "🕒", "🕓", "🕔", "🕕", "🕖", "🕗", "🕘", "🕙", "🕚" };
    pub const weather = &.{ "☀️ ", "☀️ ", "☀️ ", "🌤 ", "⛅️ ", "🌥 ", "☁️ ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "🌧 ", "🌨 ", "⛈ ", "🌨 ", "🌧 ", "🌨 ", "☁️ ", "🌥 ", "⛅️ ", "🌤 ", "☀️ ", "☀️ " };
};

pub const SpinnerOptions = struct {
    frames: []const []const u8 = SpinnerStyles.dots,
    refresh_rate_ms: u64 = 80,
};

options: SpinnerOptions,
lines: ArrayList(SpinnerLine),
allocator: Allocator,
writer: *Writer,

pub fn init(writer: *Writer, allocator: Allocator, options: SpinnerOptions) Spinner {
    return Spinner{
        .writer = writer,
        .allocator = allocator,
        .lines = ArrayList(SpinnerLine).empty,
        .options = options,
    };
}

pub fn deinit(self: *Spinner) void {
    self.lines.deinit(self.allocator);
}

pub fn start(self: *Spinner, comptime format: []const u8, args: anytype) !void {
    const writer = self.writer;
    const allocator = self.allocator;
    const frames = self.options.frames;

    const interval = self.options.refresh_rate_ms * std.time.ns_per_ms;

    var frame_index: usize = 0;

    while (frame_index < frames.len) : (frame_index = (frame_index + 1) % frames.len) {
        const frame = frames[frame_index];
        const message = try std.fmt.allocPrint(allocator, format, args);
        defer self.allocator.free(message);
        try writer.print("{s} {s}\n", .{ frame, message });
        std.Thread.sleep(interval);
        try self.render();
    }
}

fn render(self: *Spinner) !void {
    try self.writer.print("\r\x1b[1A", .{});
    try self.writer.print("\x1b[J", .{});
}
