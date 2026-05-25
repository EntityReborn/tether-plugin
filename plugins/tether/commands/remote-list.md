---
description: List the active Tether sessions held by this Claude Code window.
allowed-tools: [mcp__tether__list_sessions]
---

Call `mcp__tether__list_sessions` and render the result as a short table:

- Session ID (first 8 chars is enough for human use)
- Code
- State (pending / live)
- Created-at timestamp

If there are no sessions, say so plainly. If there is exactly one live session, mention that subsequent remote tool calls will target it implicitly (no `session_id` argument needed).
