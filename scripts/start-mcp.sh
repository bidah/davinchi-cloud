#!/usr/bin/env bash
#
# Launch the davinci-resolve MCP server on the box.
#
# Defaults to the networked streamable-http transport on 127.0.0.1:8000 so a
# local agent can reach it through `daytona preview-url <box> 8000`.
# Set MCP_TRANSPORT=stdio for a local (same-box) client.
#
#   MCP_PORT=8000 MCP_TRANSPORT=streamable-http ./start-mcp.sh
#
set -euo pipefail

DEST="${MCP_DEST:-/opt/davinci-resolve-mcp}"
export RESOLVE_SCRIPT_API="${RESOLVE_SCRIPT_API:-/opt/resolve/Developer/Scripting}"
export RESOLVE_SCRIPT_LIB="${RESOLVE_SCRIPT_LIB:-/opt/resolve/libs/Fusion/fusionscript.so}"
export PYTHONPATH="${RESOLVE_SCRIPT_API}/Modules:${PYTHONPATH:-}"

TRANSPORT="${MCP_TRANSPORT:-streamable-http}"
PORT="${MCP_PORT:-8000}"

if [[ "$TRANSPORT" == "stdio" ]]; then
  exec "$DEST/venv/bin/python" "$DEST/src/server.py"
else
  exec "$DEST/venv/bin/python" "$DEST/src/server.py" \
    --transport "$TRANSPORT" --port "$PORT"
fi
