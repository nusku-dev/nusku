//! The agent's log, under the scope "agent".

const logger = @import("log");

pub const agent = logger.scope("agent");
