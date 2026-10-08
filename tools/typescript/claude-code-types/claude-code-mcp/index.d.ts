// The MCP tools every mod is type checked against: none (#953). Claude Code lays this file from
// the MCP tools the session had connected when the mod last reloaded, so an installed copy's list
// changes with the session, and a mod's own tool.call matcher on its own tool failed the check
// while that tool happened not to be connected. With none declared, McpToolInputs stays empty and
// the engine's own fallback applies: every tool named mcp__<server>__<tool> is accepted, with loose
// arguments, so a verdict depends only on this repository. What that gives up: a misspelled tool
// name of the right shape is not caught by the types, which it only ever was while that server was
// connected. Kept by hand; tools/refresh-claude-code-types.sh never writes it.
export {}
