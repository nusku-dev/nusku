//! UTC timestamp formatting without allocation.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn writeRfc3339(w: *Writer, ns: i96) Writer.Error!void {
    const total_ms: i64 = @intCast(@divFloor(ns, std.time.ns_per_ms));
    const secs: u64 = @intCast(@max(@divFloor(total_ms, 1000), 0));
    const ms: u64 = @intCast(@mod(total_ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };

    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    });
}
