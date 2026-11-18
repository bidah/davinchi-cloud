#!/usr/bin/env bash
#
# Install the davinci-resolve MCP server (compound/Python mode) into the image.
#
#   DEST=/opt/davinci-resolve-mcp   MCP version pinned via MCP_VERSION
#
# On Linux the Resolve scripting API lives at:
#   /opt/resolve/Developer/Scripting
#   /opt/resolve/libs/Fusion/fusionscript.so
#
set -euo pipefail

log() { echo "[resolve-mcp] $*"; }

MCP_VERSION="${MCP_VERSION:-5.3.1}"
DEST="${MCP_DEST:-/opt/davinci-resolve-mcp}"
REPO="https://github.com/samuelgursky/davinci-resolve-mcp.git"

apt-get update
apt-get install -y --no-install-recommends \
  git ffmpeg python3-venv python3-pip
rm -rf /var/lib/apt/lists/*

if [[ -d "$DEST/.git" ]]; then
  log "repo already present at $DEST"
else
  log "cloning davinci-resolve-mcp v${MCP_VERSION}"
  if ! git clone --depth 1 --branch "v${MCP_VERSION}" "$REPO" "$DEST" 2>/dev/null; then
    log "tag v${MCP_VERSION} not found, falling back to default branch"
    git clone --depth 1 "$REPO" "$DEST"
  fi
fi

log "creating virtualenv"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --upgrade pip >/dev/null
# mcp 2.x removed fastmcp; pin <2 as upstream requires.
"$DEST/venv/bin/pip" install "mcp[cli]>=1.30,<2" "pyaaf2>=1.7.1"

log "installed:"
"$DEST/venv/bin/python" -c "import mcp; print('mcp', getattr(mcp,'__version__','?'))" || true
log "done -> $DEST"
