#!/usr/bin/env bash
#
# Free-edition only: install the in-app bridge script into Resolve's
# Fusion Scripts/Utility folder. Run AS THE EDITOR USER inside the box.
#
#   daytona exec <box> -- sudo -u editor /opt/scripts/setup-free-bridge.sh
#
# Then, in the Resolve GUI:
#   open/create a project  ->  Workspace > Scripts > resolve_bridge
#
# Works on free 21.0.x. Free 21.1+ removed Python from the Scripts menu, so the
# bridge is unavailable there (use Studio for hands-free control).
#
set -euo pipefail

DEST="${MCP_DEST:-/opt/davinci-resolve-mcp}"

if [[ ! -f "$DEST/scripts/install_resolve_bridge.py" ]]; then
  echo "[bridge] install_resolve_bridge.py not found under $DEST" >&2
  exit 1
fi

echo "[bridge] installing in-app bridge for user $(id -un)"
"$DEST/venv/bin/python" "$DEST/scripts/install_resolve_bridge.py"
echo "[bridge] done. In Resolve: Workspace > Scripts > resolve_bridge"
