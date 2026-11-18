# DaVinci Resolve MCP on the editing box

This box is designed to be driven by the **`davinci-resolve` MCP server**:

- Upstream project: <https://github.com/samuelgursky/davinci-resolve-mcp>
- npm package: `davinci-resolve-mcp` (also installable from source with `python install.py`)
- Compound mode: 37 grouped tools (matches the `action` + `params` shape used by
  the `davinci-resolve` skill in `.opencode/skills/davinci-resolve/`).

## Edition matters — read this first

| Resolve edition | External scripting | MCP transport |
|---|---|---|
| **Studio** (paid license) | Enabled natively (`Preferences ▸ General ▸ External scripting using ▸ Local`) | Direct scripting API. Works headless. |
| **Free 21.0.x** | Gated, but the **in-app bridge** works | Run `resolve_bridge` from **Workspace ▸ Scripts** once per session; the MCP connects over an authenticated loopback listener. |
| **Free 21.1+** | Gated, and Python was removed from the Scripts menu | **Not controllable** by the MCP. |

So:

- If you need the MCP to reliably drive the box **with no manual step**, use
  **Resolve Studio** (official installer + your own license key injected at
  sandbox launch — never baked into the image).
- If you want **zero license cost**, install **free 21.0.x** and accept a
  one-click "Workspace ▸ Scripts ▸ resolve_bridge" per editing session.
- Free 21.2 is fine as a *plain editor* but cannot be agent-driven.

## Install on the box (already wired in the image build)

The Dockerfile clones the MCP server into `/opt/davinci-resolve-mcp` (Python venv, build arg `INSTALL_MCP=1`).
If you need to (re)install inside a running box:

```bash
# MCP server (managed install + client configs)
npx -y davinci-resolve-mcp setup

# Free-edition bridge (installs the in-app script into Resolve's script folder)
python3 -m venv /opt/davinci-mcp-venv
/opt/davinci-mcp-venv/bin/pip install davinci-resolve-mcp
/opt/davinci-mcp-venv/bin/python scripts/install_resolve_bridge.py || true
```

Then, for the **free edition**: open Resolve → open/create a project →
**Workspace ▸ Scripts ▸ resolve_bridge**. The bridge config lands at
`~/.config/davinci-resolve-mcp/bridge.json`.

## Connecting the agent (local opencode) to the box

The bridge/listener binds loopback **inside** the sandbox, so the cleanest setup
is to run the MCP server **on the box** in its networked transport mode and
expose it, then point the local agent at that URL:

```bash
# inside the box (via `daytona exec <box> -- ...`)
# start the networked MCP transport on loopback, e.g. port 8765 (see repo docs
# for the exact flag: `python -m src.server --transport http --port 8765`)
daytona preview-url <box> 8765      # signed HTTPS URL for the agent
```

Then register it in the local `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "davinci-resolve": {
      "type": "remote",
      "url": "https://<signed-preview-url-from-daytona>/mcp",
      "enabled": true
    }
  }
}
```

Alternative (simpler, local-network): run the MCP on your Mac and SSH-tunnel the
box's bridge port to localhost:

```bash
daytona ssh <box> -L 9876:127.0.0.1:9876
```

> Exact transport flags can change between MCP releases — check
> `davinci-resolve-mcp --help` / the repo's `docs/install.md` if a flag differs.

## Skill

The agent skill lives at `.opencode/skills/davinci-resolve/SKILL.md`. It maps the
tool areas (projects, media pool, timeline, color, render, …) and the standard
workflows, and encodes the edition/bridge caveats above.
