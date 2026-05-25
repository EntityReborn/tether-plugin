---
description: End a Tether session cleanly. Asks for confirmation if there is more than one live session.
allowed-tools: [mcp__tether__list_sessions, mcp__tether__end_session]
---

End a Tether session.

1. Call `mcp__tether__list_sessions` first.
2. If `$ARGUMENTS` contains a session_id (or a code), use that. Otherwise:
   - If exactly one live session exists, end it.
   - If multiple, list them and ask the user which to end. Do NOT guess.
3. Call `mcp__tether__end_session` with the chosen session_id.
4. Confirm the session ended; mention that the remote agent's window has closed and the client's `tether-agent.exe` process has exited.
