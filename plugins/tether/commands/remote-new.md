---
description: Start a new Tether remote session. Mints a short code (ADJ-NOUN-ADJ-NOUN) to read aloud to the remote user.
allowed-tools: [mcp__tether__new_session, mcp__tether__wait_for_pair]
---

You are starting a new Tether remote-support session.

1. Call `mcp__tether__new_session` (no arguments needed; the MCP server uses the configured display name).
2. Show the user the returned `code` (the human-readable ADJ-NOUN-ADJ-NOUN) and the `hint` text from the response.
3. Remind them: the code is single-use and expires in 10 minutes if no agent claims it. Read it over voice (phone), not text/chat.
4. IMMEDIATELY after printing the code, call `mcp__tether__wait_for_pair`, passing the `session_id` you just got back. The call blocks server-side until the agent pairs (or until the 10-minute code expiry), so you do not need the operator to confirm "they're connected."
   - When it returns `paired: true`, briefly announce that the agent has joined (include `agent_info` if present) and then wait for the operator's next instruction. Do NOT start investigating anything until told.
   - When it returns `paired: false` (the wait timed out), tell the operator the code expired without being claimed and suggest running `/remote-new` again to mint a fresh one.

Do not call any other `mcp__tether__*` tool while `wait_for_pair` is in flight - it owns the session-establishment phase. If the user asks you to do something else mid-wait, ask them whether to abandon this pair attempt first.
