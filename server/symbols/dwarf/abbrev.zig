/// Parses DWARF abbreviation tables into DIE definitions and their attribute specifications.
const std = @import("std");
const r = @import("reader.zig");
const FORM = @import("form.zig").FORM;
const Reader = r.Reader;
const Error = r.Error;

pub const Attr = struct {
    name: u64,
    form: u64,
    implicit: i64,
};

pub const Abbrev = struct {
    code: u64,
    tag: u64,
    children: bool,
    attrs: []const Attr,
};

pub const Abbrevs = struct {
    list: []Abbrev,
    attrs: []Attr,

    pub fn init(abbrevs: *Abbrevs, gpa: std.mem.Allocator, section: []const u8, at: u64) Error!void {
        if (at >= section.len) return error.Malformed;
        var reader: Reader = undefined;
        reader.init(section, @intCast(at));

        var list: std.ArrayList(Abbrev) = .empty;
        defer list.deinit(gpa);

        var attrs: std.ArrayList(Attr) = .empty;
        defer attrs.deinit(gpa);

        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(gpa);

        while (true) {
            const code = try reader.uleb();
            if (code == 0) break;
            const tag = try reader.uleb();
            const children = try reader.int(u8) != 0;
            try starts.append(gpa, attrs.items.len);

            while (true) {
                const name = try reader.uleb();
                const form = try reader.uleb();
                if (name == 0 and form == 0) break;
                const implicit = if (form == FORM.implicit_const) try reader.sleb() else 0;
                try attrs.append(gpa, .{
                    .name = name,
                    .form = form,
                    .implicit = implicit,
                });
            }

            try list.append(gpa, .{
                .code = code,
                .tag = tag,
                .children = children,
                .attrs = &.{},
            });
        }

        const attrs_owned = try attrs.toOwnedSlice(gpa);
        errdefer gpa.free(attrs_owned);
        const list_owned = try list.toOwnedSlice(gpa);
        for (list_owned, starts.items, 0..) |*abbrev, start, index| {
            const last = index + 1 == starts.items.len;
            const end = if (last) attrs_owned.len else starts.items[index + 1];
            abbrev.attrs = attrs_owned[start..end];
        }
        abbrevs.* = .{ .list = list_owned, .attrs = attrs_owned };
    }

    pub fn deinit(abbrevs: *Abbrevs, gpa: std.mem.Allocator) void {
        gpa.free(abbrevs.list);
        gpa.free(abbrevs.attrs);
        abbrevs.* = undefined;
    }

    pub fn find(abbrevs: *const Abbrevs, code: u64) ?*const Abbrev {
        if (code > 0 and code <= abbrevs.list.len and abbrevs.list[code - 1].code == code) {
            return &abbrevs.list[code - 1];
        }
        for (abbrevs.list) |*abbrev| if (abbrev.code == code) return abbrev;
        return null;
    }
};

test "parse a single abbreviation" {
    // One abbreviation: code=1, tag=DW_TAG_compile_unit,
    // children=no, one attribute (DW_AT_name, DW_FORM_string).
    const section = [_]u8{
        0x01, // code
        0x11, // tag
        0x00, // children
        0x03, // DW_AT_name
        0x08, // DW_FORM_string
        0x00, 0x00, // attribute terminator
        0x00, // table terminator
    };

    var abbrevs: Abbrevs = undefined;
    try abbrevs.init(std.testing.allocator, &section, 0);
    defer abbrevs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), abbrevs.list.len);
    try std.testing.expectEqual(@as(u64, 1), abbrevs.list[0].code);
    try std.testing.expectEqual(@as(u64, 0x11), abbrevs.list[0].tag);
    try std.testing.expect(!abbrevs.list[0].children);
    try std.testing.expectEqual(@as(usize, 1), abbrevs.list[0].attrs.len);
}

test "parse multiple abbreviations" {
    const section = [_]u8{
        0x01, 0x11, 0x00, 0x00, 0x00,
        0x02, 0x24, 0x01, 0x00, 0x00,
        0x00,
    };

    var abbrevs: Abbrevs = undefined;
    try abbrevs.init(std.testing.allocator, &section, 0);
    defer abbrevs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), abbrevs.list.len);
    try std.testing.expectEqual(@as(u64, 1), abbrevs.list[0].code);
    try std.testing.expectEqual(@as(u64, 2), abbrevs.list[1].code);
    try std.testing.expect(abbrevs.list[1].children);
}

test "parse implicit constant attribute" {
    const section = [_]u8{
        0x01, 0x11, 0x00,
        0x03, 0x21, // DW_AT_name, DW_FORM_implicit_const
        0x05, // SLEB128 value: 5
        0x00,
        0x00,
        0x00,
    };

    var abbrevs: Abbrevs = undefined;
    try abbrevs.init(std.testing.allocator, &section, 0);
    defer abbrevs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), abbrevs.list[0].attrs.len);
    try std.testing.expectEqual(@as(i64, 5), abbrevs.list[0].attrs[0].implicit);
}

test "find abbreviation by code" {
    const section = [_]u8{
        0x01, 0x11, 0x00, 0x00, 0x00,
        0x02, 0x24, 0x00, 0x00, 0x00,
        0x00,
    };

    var abbrevs: Abbrevs = undefined;
    try abbrevs.init(std.testing.allocator, &section, 0);
    defer abbrevs.deinit(std.testing.allocator);

    try std.testing.expect(abbrevs.find(1) != null);
    try std.testing.expect(abbrevs.find(2) != null);
    try std.testing.expect(abbrevs.find(3) == null);
}
