#!/usr/bin/env bash
#
# Free edition: start the davinci-resolve MCP in-app bridge without a human.
# Drives the Resolve UI on the box's desktop with xdotool (no AI, no API key):
#
#   1. wait for Resolve (Project Manager or a project window)
#   2. Project Manager: open the first existing project, or create one
#   3. Workspace > Scripts > resolve_bridge
#   4. wait until the bridge port answers
#
#   start-bridge.sh            # run as the box user, after Resolve is starting
#   BRIDGE_TIMEOUT=180 start-bridge.sh
#
# Exit 0 when the bridge answers (also when it was already running).
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}"
log() { echo "[bridge-start] $*"; }

CONF="${DAVINCI_RESOLVE_BRIDGE_CONFIG:-$HOME/.config/davinci-resolve-mcp/bridge.json}"
PORT=$(jq -r '.port // 49632' "$CONF" 2>/dev/null || echo 49632)
TIMEOUT="${BRIDGE_TIMEOUT:-240}"

listening() { python3 - "$PORT" <<'EOF'
import socket, sys
s = socket.socket(); s.settimeout(1)
sys.exit(s.connect_ex(("127.0.0.1", int(sys.argv[1]))))
EOF
}
win() { xdotool search --name "$1" 2>/dev/null | head -1; }

if listening; then log "bridge already listening on $PORT"; exit 0; fi

# Resolve finds Python through libpython; without it the Scripts menu hides .py files.
ls /usr/lib/x86_64-linux-gnu/libpython3*.so* >/dev/null 2>&1 \
  || log "WARNING: no libpython3 found; resolve_bridge will not be listed (install libpython3.10)"

deadline=$((SECONDS + TIMEOUT))
log "waiting for Resolve ..."
while (( SECONDS < deadline )); do
  [[ -n "$(win '^DaVinci Resolve - ')" || -n "$(win '^Project Manager$')" ]] && break
  sleep 2
done

# 2. Project Manager -> a project window
pm=$(win '^Project Manager$')
if [[ -n "$pm" ]]; then
  log "Project Manager open: opening a project"
  sleep 3
  xdotool windowactivate --sync "$pm" 2>/dev/null
  # The "New Project" tile is selected; Right moves to the first existing project.
  xdotool key Right; sleep 1; xdotool key Return
  for _ in $(seq 20); do [[ -n "$(win '^DaVinci Resolve - ')" ]] && break; sleep 1; done
  if [[ -z "$(win '^DaVinci Resolve - ')" ]]; then
    # No existing project: Return opened "Create New Project"; confirm the default name.
    log "no existing project: creating one"
    xdotool key Return
  fi
fi

for _ in $(seq 60); do [[ -n "$(win '^DaVinci Resolve - ')" ]] && break; sleep 2; done
main=$(win '^DaVinci Resolve - ')
[[ -n "$main" ]] || { log "ERROR: no project window"; exit 1; }
log "project window: $(xdotool getwindowname "$main")"
sleep 5   # let the page finish loading before using the menu bar

# 3. Workspace > Scripts > resolve_bridge, by keyboard once the menu is open:
#    Up wraps to the last item (Scripts), Right opens it on its first entry
#    (resolve_bridge sorts first), Return runs it.
for attempt in 1 2 3; do
  xdotool windowactivate --sync "$main" 2>/dev/null
  read -r X Y < <(xdotool getwindowgeometry "$main" | awk '/Position/{split($2,p,","); print p[1], p[2]}')
  xdotool mousemove $((X + 647)) $((Y + 9)) click 1    # "Workspace" in the 1920-wide menu bar
  sleep 1; xdotool key Up; sleep 0.5; xdotool key Right; sleep 0.5; xdotool key Return
  for _ in $(seq 10); do listening && { log "bridge listening on 127.0.0.1:$PORT"; exit 0; }; sleep 1; done
  log "attempt $attempt: bridge not up yet"; xdotool key Escape Escape
done
log "ERROR: bridge did not start; run Workspace > Scripts > resolve_bridge by hand"
exit 1
