const r = @import("reader.zig");
const a = @import("abbrevs.zig");

pub const decoder = @import("decoder.zig");
pub const FORM = @import("form.zig").FORM;

pub const Reader = r.Reader;
pub const Error = r.Error;
pub const Abbrevs = a.Abbrevs;
pub const Abbrev = a.Abbrev;
