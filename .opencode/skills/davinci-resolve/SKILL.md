---
name: davinci-resolve
description: Drive DaVinci Resolve on a Daytona editing box through the davinci-resolve MCP server. Use for project/timeline setup, media pool imports, editing, color groups, markers, AI analysis, and render jobs.
---

# DaVinci Resolve on a Daytona editing box

You control a DaVinci Resolve instance running **inside a Daytona sandbox**
via the `davinci-resolve` MCP server. Every tool takes an `action` plus an
optional `params` object and returns `{ result }`.

## Prerequisites / health check

1. Confirm the sandbox is up: `daytona list`.
2. Confirm Resolve is running inside it:
   `daytona exec <sandbox> -- pgrep -a resolve`.
3. Confirm the MCP endpoint is reachable (see `mcp/README.md` for the tunnel
   and transport used for this box). If a tool returns a connection error,
   Resolve is closed or external scripting is disabled — relaunch it and retry.

## Tool map

| Area | Tool | Typical actions |
|------|------|-----------------|
| App control | `resolve_control` | open/quit app, get/set page, app info |
| Projects | `project_manager` | create/open/save/close/delete projects |
| Project DB | `project_manager_database` | create/list/restore project databases |
| Settings | `project_settings` | read/write project settings, color groups |
| Media pool | `folder` | list/add/delete folders and clips, import media |
| Timeline | `timeline_ai` | AI analysis, scene cut, smart reframe helpers |
| Timeline | `timeline_markers` | add/move/delete markers, playhead |
| Color | `color_group` | create/rename/assign color groups, node graphs |
| Fusion | `fusion_comp` | add/edit Fusion comps, nodes |
| Fusion | `fuse_plugin` | author/install `.fuse` plugins |
| Gallery | `gallery`, `gallery_stills` | album + still management |
| Analysis | `media_analysis` | analyze media, publish metadata |
| Render | `render`, `render_presets` | jobs, formats, codecs, burn-ins, render |
| Presets | `layout_presets`, `render_presets` | UI layout + render presets |
| Setup | `setup` | conversational defaults, prefs |

> The server exposes more actions than shown here. When unsure of an action
> name, prefer the documented common ones first; unknown actions return an
> error you can read.

## Standard workflows

### 1. Create a project and import media
```
project_manager   { action: "create", params: { name: "<project>" } }
folder            { action: "add",    params: { bin: "Footage", path: "/data/footage" } }
```
Media lives under the sandbox working dir (e.g. `/home/editor/media`). Upload
with `daytona exec`/`daytona cp` or mount a Daytona volume before importing.

### 2. Assemble and mark
```
timeline_markers  { action: "add", params: { frame: 0, name: "start" } }
timeline_markers  { action: "set_playhead", params: { frame: 120 } }
```

### 3. Color
```
color_group       { action: "create", params: { name: "Grade A" } }
project_settings  { action: "get", params: {} }   # inspect before changing
```

### 4. Render
```
render_presets    { action: "list", params: {} }
render            { action: "add_job", params: { preset: "<preset>", target_dir: "/home/editor/renders" } }
render            { action: "start",   params: {} }
render            { action: "status",  params: {} }
```

## Conventions & safety

- **Never run Resolve as root.** The container creates a non-root `editor` user.
- Prefer `project_settings { action: "get" }` before mutating settings.
- Large operations (render, analysis) are async — poll with `status` actions
  instead of assuming completion.
- The box is GPU-agnostic; if no GPU is attached, GPU-only effects fall back to
  software and are slow. Warn the user before starting long renders.
- Store projects/renders under `/home/editor/` so they survive within the
  sandbox lifetime; use a Daytona volume for anything that must persist.
