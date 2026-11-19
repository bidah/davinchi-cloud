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
- Never modify, overwrite or delete source media unless explicitly asked.
  Converted copies (below) are new files next to the sources, which is fine.

## Required: media formats

Resolve **free on Linux has no H.264, H.265 (HEVC) or AAC** — Blackmagic ships
those codecs on Linux only in Studio. This box runs free 21.0.3 on purpose (the
last free build with Python scripting, which the MCP needs), so this is a hard
limit, not a setting. Clips in those formats fail to import or show as offline
/ "media offline" / no audio. Phone, camera and web footage almost always is.

1. **Before importing anything**, run
   `/opt/scripts/media-convert.sh ingest ~/media/footage` (or the folder you're
   importing). It writes DNxHR HQ (HQX for 10-bit) + PCM copies to
   `<folder>/_edit/`, keeps the folder structure, and skips files already done.
   **Import only from `_edit/`** for those clips; formats Resolve already reads
   (ProRes, DNxHR, WAV, images) import directly.
2. **Render** to `~/media/exports` as **QuickTime DNxHR HQ or ProRes 422 HQ
   `.mov`** with Linear PCM audio. Never pick H.264, H.265 or AAC in the Deliver
   page; on this box they fail or are missing.
3. **If the user wants an `.mp4`** (web, social, sharing), run
   `/opt/scripts/media-convert.sh deliver ~/media/exports/<name>.mov` after the
   render. It writes `<name>.mp4` (H.264 + AAC, GPU encoder) next to it.
4. DNxHR copies are ~10x larger than H.264 and volume storage is billed per GB.
   Don't convert media you won't use, and offer to delete `_edit/` when a
   project is finished (the sources stay; `ingest` can recreate it).
