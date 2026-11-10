//! What the views share to draw on a terminal.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

pub const bold = "\x1b[1m";
pub const bold_cyan = "\x1b[1;36m";
pub const dim = "\x1b[2m";
pub const cyan = "\x1b[36m";
pub const yellow = "\x1b[33m";
pub const red = "\x1b[1;31m";
const reset = "\x1b[0m";

pub const cursor_hide = "\x1b[?25l";
pub const cursor_show = "\x1b[?25h";

pub const Style = struct {
    color: bool,

    pub fn on(style: Style, code: []const u8) []const u8 {
        return if (style.color) code else "";
    }

    pub fn off(style: Style) []const u8 {
        return style.on(reset);
    }

    pub fn heat(style: Style, per_mille: u64, red_from: u64) []const u8 {
        assert(red_from > 100);
        if (per_mille >= red_from) return style.on(red);
        if (per_mille >= 100) return style.on(yellow);
        if (per_mille < 10) return style.on(dim);
        return "";
    }
};

pub fn bar_write(w: *Writer, per_mille: u64, columns: usize) !void {
    const eighths = [_][]const u8{
        "",
        "\u{258f}",
        "\u{258e}",
        "\u{258d}",
        "\u{258c}",
        "\u{258b}",
        "\u{258a}",
        "\u{2589}",
    };
    const units: usize = @intCast(@min(per_mille, 1000) * columns * 8 / 1000);
    const full = units / 8;
    for (0..full) |_| try w.writeAll("\u{2588}");
    try w.writeAll(eighths[units % 8]);
    try w.splatByteAll(' ', columns - full - @intFromBool(units % 8 != 0));
}

pub fn lines_erase(w: *Writer, lines: usize) !void {
    if (lines == 0) return;
    try w.print("\x1b[{d}F\x1b[J", .{lines});
}

pub const Size = struct { rows: usize, cols: usize };

pub fn size() ?Size {
    var window: std.posix.winsize = undefined;
    const linux = std.os.linux;
    const result = linux.ioctl(std.posix.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&window));
    if (linux.errno(result) != .SUCCESS or window.row == 0 or window.col == 0) return null;
    return .{ .rows = window.row, .cols = window.col };
}

pub fn text_cut_write(w: *Writer, text: []const u8, width: usize) !void {
    if (width == 0 or text.len <= width) return w.writeAll(text);
    try w.writeAll(text[0 .. width - 1]);
    try w.writeAll("\u{2026}");
}

const testing = std.testing;

fn bar_test(per_mille: u64, columns: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    try bar_write(&out.writer, per_mille, columns);
    return out.toOwnedSlice();
}

test "a bar is whole blocks and an eighth, always as wide as asked" {
    const six = try bar_test(600, 10);
    defer testing.allocator.free(six);
    try testing.expectEqualStrings("\u{2588}" ** 6 ++ "    ", six);

    const almost = try bar_test(980, 6);
    defer testing.allocator.free(almost);
    try testing.expectEqualStrings("\u{2588}" ** 5 ++ "\u{2589}", almost);

    const past = try bar_test(1500, 4);
    defer testing.allocator.free(past);
    try testing.expectEqualStrings("\u{2588}" ** 4, past);
}

test "text is cut with an ellipsis, only when it does not fit" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try text_cut_write(&out.writer, "abcdef", 4);
    try text_cut_write(&out.writer, "ab", 4);
    try text_cut_write(&out.writer, "abcdef", 0);
    try testing.expectEqualStrings("abc\u{2026}ababcdef", out.written());
}
