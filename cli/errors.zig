//! Error vocabulary shared by commands and `execute`.

pub const RunError = error{ Reported, InvalidUsage };

pub const exit_success: u8 = 0;
pub const exit_failure: u8 = 1;
pub const exit_usage: u8 = 2;
