#!/usr/bin/env bash
#
# Persist DaVinci Resolve state across ephemeral sandboxes.
#
# Media/assets live directly on the Daytona volume ($RESOLVE_MEDIA, default
# ~/media). Resolve's project database (SQLite under ~/.local/share/DaVinciResolve)
# must NOT run on the FUSE volume, so it runs on local disk and is synced as a
# single tarball:
#
#   resolve-state.sh init      create the media folder layout on the volume
#   resolve-state.sh restore   volume -> local disk (run before Resolve starts)
#   resolve-state.sh save      local disk -> volume (new timestamped generation, keeps last 5)
#   resolve-state.sh loop [s]  save every s seconds (default 300) when something changed
#   resolve-state.sh status
#   resolve-state.sh save-home      agent setup -> volume (Claude Code + MCP logins, gh)
#   resolve-state.sh restore-home   volume -> home (run first on a new box)
#
# GPU boxes are always deleted when they stop (Daytona: "GPU sandboxes must remain
# ephemeral"; pausing isn't supported). Saving the projects AND the agent setup
# makes `down` + `up` behave like a pause: nothing to set up or log in again.
#
set -euo pipefail

MEDIA="${RESOLVE_MEDIA:-$HOME/media}"
STATE="$MEDIA/.resolve-state"
PARENT="$HOME/.local/share"
NAME="DaVinciResolve"
KEEP="${RESOLVE_STATE_KEEP:-5}"   # generations kept on the volume
SAVED_FP=/tmp/resolve-state.saved-fingerprint   # fingerprint of what is on the volume
log() { echo "[resolve-state] $(date +%H:%M:%S) $*"; }

# The volume is mountpoint-s3: sequential writes, overwrite and delete work, rename does NOT.
# So every save is a new file  state-<UTC timestamp>.tar.gz  (only visible once fully written),
# and old generations are pruned. Restore takes the newest one that extracts cleanly.

init() {
  mkdir -p "$MEDIA"/{footage,audio,assets,exports,project-archives} "$STATE"
}

generations() { ls -1 "$STATE"/state-*.tar.gz 2>/dev/null | sort -r; }

restore() {
  init
  local g
  for g in $(generations); do
    rm -rf "${PARENT:?}/$NAME"; mkdir -p "$PARENT"
    if tar -xzf "$g" -C "$PARENT" 2>/dev/null; then
      log "restored $NAME from $(basename "$g") ($(du -h "$g" | cut -f1))"
      fingerprint > "$SAVED_FP"
      return 0
    fi
    log "skipping unreadable $(basename "$g")"
  done
  log "no saved Resolve state yet (first run)"
  echo none > "$SAVED_FP"
}

fingerprint() {
  [[ -d "$PARENT/$NAME" ]] || { echo none; return; }
  find "$PARENT/$NAME" -type f -not -path "*/logs/*" -printf '%P %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

save() {
  [[ -d "$PARENT/$NAME" ]] || { log "nothing to save yet"; return 0; }
  init
  local tmp ts dst
  tmp="$(mktemp /tmp/resolve-state.XXXXXX.tar.gz)"
  local fp; fp="$(fingerprint)"
  tar -czf "$tmp" -C "$PARENT" --exclude="$NAME/logs" --exclude="*/CacheClip" "$NAME"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dst="$STATE/state-$ts.tar.gz"
  cp "$tmp" "$dst"
  rm -f "$tmp"
  echo "$fp" > "$SAVED_FP"
  generations | tail -n +$((KEEP + 1)) | xargs -r rm -f
  log "saved $NAME -> $(basename "$dst") ($(du -h "$dst" | cut -f1))"
}

# The agent setup: Claude Code's config + sessions, MCP OAuth logins, the gh login.
# ~/.claude/CLAUDE.md is the image's (kept current there), so it's left out.
# Contains credentials: written 0600 to the volume, last 3 generations kept.
HOME_ITEMS=(.claude .claude.json .config/gh)
HOME_KEEP=3
home_generations() { ls -1 "$STATE"/home-*.tar.gz 2>/dev/null | sort -r; }

save_home() {
  init
  local items=() i
  for i in "${HOME_ITEMS[@]}"; do [[ -e "$HOME/$i" ]] && items+=("$i"); done
  (( ${#items[@]} )) || { log "no agent setup to save"; return 0; }
  local tmp dst
  tmp="$(mktemp /tmp/home-state.XXXXXX.tar.gz)"; chmod 600 "$tmp"
  tar -czf "$tmp" -C "$HOME" --exclude=".claude/CLAUDE.md" --exclude=".claude/cache" \
      --exclude=".claude/statsig" --exclude=".claude/shell-snapshots" "${items[@]}"
  dst="$STATE/home-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  cp "$tmp" "$dst"; chmod 600 "$dst" 2>/dev/null || true; rm -f "$tmp"
  home_generations | tail -n +$((HOME_KEEP + 1)) | xargs -r rm -f
  log "saved agent setup -> $(basename "$dst") ($(du -h "$dst" | cut -f1))"
}

restore_home() {
  init
  local g
  for g in $(home_generations); do
    if tar -xzf "$g" -C "$HOME" 2>/dev/null; then
      log "restored agent setup from $(basename "$g")"
      return 0
    fi
    log "skipping unreadable $(basename "$g")"
  done
  log "no saved agent setup yet (first box)"
}

loop() {
  local every="${1:-300}"
  log "autosave every ${every}s (only when projects changed)"
  while sleep "$every"; do
    if [[ "$(fingerprint)" != "$(cat "$SAVED_FP" 2>/dev/null)" ]]; then
      save || log "autosave failed"
      save_home || log "agent setup save failed"
    fi
  done
}

status() {
  echo "media volume : $MEDIA ($(df -h "$MEDIA" 2>/dev/null | tail -1 | awk '{print $1}'))"
  du -sh "$MEDIA"/{footage,audio,assets,exports,project-archives} 2>/dev/null || true
  local g; g="$(generations | head -1)"
  local hg; hg="$(home_generations | head -1)"
  echo "agent setup  : $( [[ -n $hg ]] && basename "$hg" || echo "none saved yet" )"
  echo "projects     : $( [[ -n $g ]] && echo "$(basename "$g") ($(du -h "$g" | cut -f1)), $(generations | wc -l) generation(s)" || echo "none saved yet" )"
}

case "${1:-}" in
  init) init ;; restore) restore ;; save) save ;; loop) loop "${2:-300}" ;; status) status ;;
  save-home) save_home ;; restore-home) restore_home ;;
  *) echo "usage: $0 init|restore|save|loop [seconds]|status|save-home|restore-home" >&2; exit 2 ;;
esac
