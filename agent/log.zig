//! The agent's log: every line the agent writes goes through here, under the scope "agent".
//!
//!     const log = @import("log.zig").agent;     // "../log.zig" from a folder
//!     log.info("profiling started", .{ .pid = pid });
//!
//! It writes to the logger the program installs (logger/, `log.setDefault`), and does nothing
//! without one, so the agent is quiet as a library until its host asks for logs. Nothing on the
//! sampling path logs: lines come once per run, per binary, per report, or when something
//! changes or goes wrong.

const logger = @import("log");

pub const agent = logger.scope("agent");
