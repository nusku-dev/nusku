//! The agent's log, under the scope "agent". Quiet until the program installs a logger, and
//! never on the sampling path.
//!
//!     const log = @import("log.zig").agent;
//!     log.info("profiling started", .{ .pid = pid });

const logger = @import("log");

pub const agent = logger.scope("agent");
