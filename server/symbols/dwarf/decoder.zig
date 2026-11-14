//! Decodes DWARF attribute values according to their forms and compilation-unit settings.
const std = @import("std");
const reader = @import("reader.zig");
const FORM = @import("form.zig").FORM;

const Reader = reader.Reader;
const Error = reader.Error;

pub const Unit = struct {
    version: u16,
    wide: bool,
    address_size: u8,
};

pub const Value = union(enum) {
    none,
    unsigned: u64,
    signed: i64,
    string: []const u8,
    strp: u64,
    line_strp: u64,
    strx: u64,
    addr: u64,
    addrx: u64,
    unit_ref: u64,
    section_ref: u64,
    sec_offset: u64,
    rnglistx: u64,

    pub fn number(value: Value) ?u64 {
        return switch (value) {
            .unsigned, .sec_offset => |n| n,
            .signed => |n| if (n >= 0) @intCast(n) else null,
            else => null,
        };
    }
};

pub fn string_at(section: []const u8, at: u64) ?[]const u8 {
    if (at >= section.len) return null;
    const rest = section[@intCast(at)..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    return rest[0..end];
}

pub fn value_read(r: *Reader, form_given: u64, implicit: i64, unit: Unit) Error!Value {
    var form = form_given;
    for (0..4) |_| {
        if (form != FORM.indirect) break;
        form = try r.uleb();
    }
    return switch (form) {
        FORM.addr => .{ .addr = try r.sized(unit.address_size) },
        FORM.data1, FORM.ref1, FORM.flag, FORM.strx1, FORM.addrx1 => tagged(form, try r.int(u8)),
        FORM.data2, FORM.ref2, FORM.strx2, FORM.addrx2 => tagged(form, try r.int(u16)),
        FORM.strx3, FORM.addrx3 => tagged(form, try r.int(u24)),
        FORM.data4,
        FORM.ref4,
        FORM.strx4,
        FORM.addrx4,
        FORM.ref_sup4,
        => tagged(form, try r.int(u32)),
        FORM.data8, FORM.ref8, FORM.ref_sig8, FORM.ref_sup8 => tagged(form, try r.int(u64)),
        FORM.data16 => skipped(r, 16),
        FORM.udata, FORM.ref_udata => tagged(form, try r.uleb()),
        FORM.sdata => .{ .signed = try r.sleb() },
        FORM.implicit_const => .{ .signed = implicit },
        FORM.flag_present => .{ .unsigned = 1 },
        FORM.string => .{ .string = try r.string() },
        FORM.strp, FORM.strp_sup, FORM.GNU_strp_alt => tagged(form, try r.offset(unit.wide)),
        FORM.line_strp => .{ .line_strp = try r.offset(unit.wide) },
        FORM.sec_offset, FORM.GNU_ref_alt => .{ .sec_offset = try r.offset(unit.wide) },
        FORM.ref_addr => .{ .section_ref = if (unit.version <= 2)
            try r.sized(unit.address_size)
        else
            try r.offset(unit.wide) },
        FORM.strx, FORM.GNU_str_index => .{ .strx = try r.uleb() },
        FORM.addrx, FORM.GNU_addr_index => .{ .addrx = try r.uleb() },
        FORM.rnglistx => .{ .rnglistx = try r.uleb() },
        FORM.loclistx => .{ .unsigned = try r.uleb() },
        FORM.block1 => skipped(r, try r.int(u8)),
        FORM.block2 => skipped(r, try r.int(u16)),
        FORM.block4 => skipped(r, try r.int(u32)),
        FORM.block, FORM.exprloc => skipped(r, try r.uleb()),
        else => error.Malformed,
    };
}

fn tagged(form: u64, n: u64) Value {
    return switch (form) {
        FORM.ref1, FORM.ref2, FORM.ref4, FORM.ref8, FORM.ref_udata => .{ .unit_ref = n },
        FORM.strx1, FORM.strx2, FORM.strx3, FORM.strx4 => .{ .strx = n },
        FORM.addrx1, FORM.addrx2, FORM.addrx3, FORM.addrx4 => .{ .addrx = n },
        FORM.strp => .{ .strp = n },
        FORM.strp_sup, FORM.GNU_strp_alt, FORM.ref_sup4, FORM.ref_sup8, FORM.ref_sig8 => .none,
        else => .{ .unsigned = n },
    };
}

fn skipped(r: *Reader, n: u64) Error!Value {
    _ = try r.take(n);
    return .none;
}

const testing = std.testing;

test "reads fixed-width numeric values" {
    var r: Reader = undefined;
    r.init(&.{ 0x78, 0x56, 0x34, 0x12 }, 0);
    const unit = Unit{ .version = 4, .wide = false, .address_size = 4 };

    const value = try value_read(&r, FORM.data4, 0, unit);

    try testing.expectEqual(@as(?u64, 0x12345678), value.number());
}

test "reads null-terminated strings" {
    var r: Reader = undefined;
    r.init("hello\x00", 0);
    const unit = Unit{ .version = 4, .wide = false, .address_size = 8 };

    const value = try value_read(&r, FORM.string, 0, unit);

    try testing.expectEqualStrings("hello", value.string);
    try testing.expect(r.done());
}

test "reads signed and implicit constant values" {
    var r: Reader = undefined;
    r.init(&.{0x7b}, 0);
    const unit = Unit{ .version = 4, .wide = false, .address_size = 8 };

    const signed = try value_read(&r, FORM.sdata, 0, unit);
    const implicit = try value_read(&r, FORM.implicit_const, -42, unit);

    try testing.expectEqual(@as(i64, -5), signed.signed);
    try testing.expectEqual(@as(i64, -42), implicit.signed);
}

test "resolves indirect forms" {
    var r: Reader = undefined;
    r.init(&.{ FORM.data1, 0x2a }, 0);
    const unit = Unit{ .version = 4, .wide = false, .address_size = 8 };

    const value = try value_read(&r, FORM.indirect, 0, unit);

    try testing.expectEqual(@as(?u64, 42), value.number());
    try testing.expect(r.done());
}
