# This box: DaVinci Resolve (free 21.0.3) + davinci-resolve MCP

You are running inside a Daytona GPU sandbox. DaVinci Resolve is installed at
`/opt/resolve` and shown on the VNC desktop (display `:0`). The
`davinci-resolve` MCP server (compound mode, `/opt/davinci-resolve-mcp`) is
registered for you at user scope — use its tools to drive Resolve.

- Media lives on the persistent volume at `~/media`
  (`footage/ audio/ assets/ exports/ project-archives/`). Render to `~/media/exports`.
- This is the **free edition**: external scripting is gated, so the MCP talks
  to Resolve through the **in-app bridge**. It is started automatically when the
  box comes up. If a tool returns a connection error, run
  `/opt/scripts/start-bridge.sh` (opens a project and starts the bridge, ~20 s),
  then retry. Only if that fails, ask the user to run
  **Workspace ▸ Scripts ▸ resolve_bridge** in the desktop.
- Do not launch a second Resolve. If Resolve is closed, start it with
  `/opt/scripts/start-resolve.sh` (it uses VirtualGL for the GPU).
- Never modify, transcode or delete source media unless explicitly asked.
