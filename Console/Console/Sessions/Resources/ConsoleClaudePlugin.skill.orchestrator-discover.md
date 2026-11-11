---
name: orchestrator-discover
description: Discover which Claude Code and Console sessions are reachable for orchestration. Use when preparing an orchestrator run or when the user asks what sessions are open.
---

# Orchestrator Discover

Use these tools to inventory sessions before recommending next steps:

1. Prefer any Console scan brief already in the conversation.
2. Console MCP `list_console_sessions` — Console rows (id, name, purpose, activity, attention, summary, bridge_status, artifacts).
3. Claude Code `ListAgents` (or `/list-agents`) — other Claude sessions that can receive FYI `SendMessage`.

Map Console names to Claude agent names when both are available. Treat the Orchestrator row as yourself; do not target it for close or prompt. Prefer Console session ids with `prompt_console_session`, `create_console_session`, and `close_console_session`.
