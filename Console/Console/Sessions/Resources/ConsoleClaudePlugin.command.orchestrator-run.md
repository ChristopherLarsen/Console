---
description: Propose a goal and plan for approval, then direct Console sessions through the approved plan
---

Run the orchestrator-run skill now. Read the Console scan brief file if named, or call list_console_sessions. Ask the user to approve the goal and plan once. Each step names an existing session or gives the purpose and name of a new child, along with its directive. Carry out approved steps using prompt_console_session for existing sessions and create_console_session with initial_prompt for new children. Console allows at most four live children. Blank sessions can be listed or closed and cannot receive directives or an initial prompt. Ask before closing a session or taking any off-plan action.
