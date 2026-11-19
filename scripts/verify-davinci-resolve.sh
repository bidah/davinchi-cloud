#!/usr/bin/env bash
#
# Smoke test inside a running sandbox (run as the sandbox user):
#   GPU visible, CUDA/OpenCL/EGL usable, Resolve libs resolve, Resolve stays up.
#
set -uo pipefail
ok()   { echo "[verify] OK   $*"; }
warn() { echo "[verify] WARN $*"; }
fail() { echo "[verify] FAIL $*" >&2; exit 1; }

[[ -x /opt/resolve/bin/resolve ]] || fail "/opt/resolve/bin/resolve missing"
ok "Resolve installed: $(ls /opt/resolve/bin | tr '\n' ' ')"

if nvidia-smi -L >/dev/null 2>&1; then
  ok "GPU: $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader)"
else
  warn "no NVIDIA GPU visible (CPU-only sandbox?)"
fi

n=$(clinfo -l 2>/dev/null | grep -c Device || true)
[[ "$n" -gt 0 ]] && ok "OpenCL devices: $n" || warn "no OpenCL devices"

if command -v vglrun >/dev/null && [[ -e /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]]; then
  [[ -e /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0 ]] || sudo -n ldconfig
  own_x0=""
  if ! ls /tmp/.X11-unix/X* >/dev/null 2>&1; then Xvfb :98 >/dev/null 2>&1 & own_x0=$!; sleep 2; fi
  d=":$(ls /tmp/.X11-unix | head -1 | tr -d X)"
  r=$(DISPLAY=$d vglrun -d egl glxinfo -B 2>/dev/null | grep -m1 "OpenGL renderer" || true)
  [[ -n "$own_x0" ]] && kill "$own_x0"
  [[ "$r" == *NVIDIA* ]] && ok "GPU OpenGL via VirtualGL: ${r#*: }" || warn "VirtualGL not on NVIDIA GL: $r"
fi

missing=$(LD_LIBRARY_PATH=/opt/resolve/libs ldd /opt/resolve/bin/resolve | grep "not found" || true)
[[ -z "$missing" ]] && ok "no missing shared libraries" || { echo "$missing"; fail "missing shared libraries"; }

# Qt's xcb platform plugin (Resolve crashes with SIGABRT without its deps)
qmiss=$(LD_LIBRARY_PATH=/opt/resolve/libs ldd /opt/resolve/libs/plugins/platforms/libqxcb.so 2>/dev/null | grep "not found" || true)
[[ -z "$qmiss" ]] && ok "Qt xcb plugin dependencies present" || warn "Qt xcb plugin missing: $qmiss (start-resolve.sh installs it)"

# Running session: check it instead of starting (and killing) a second Resolve.
rpid=$(pgrep -f /opt/resolve/bin/resolve | head -1)
if [[ -n "$rpid" ]]; then
  ok "Resolve is running (pid $rpid, up $(ps -o etime= -p "$rpid" | tr -d ' '))"
  mem=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null | grep -E "^$rpid," | cut -d, -f2)
  [[ -n "$mem" ]] && ok "Resolve is using the GPU:${mem}" || warn "Resolve not listed on the GPU"
  grep -q "CRASH DUMP" "$HOME/.local/share/DaVinciResolve/logs/ResolveDebug.txt" 2>/dev/null \
    && warn "ResolveDebug.txt contains a crash dump" || ok "no crash dump in ResolveDebug.txt"
  ok "verification passed"
  exit 0
fi

own_x=""
if ! ls /tmp/.X11-unix/X* >/dev/null 2>&1; then
  Xvfb :99 -screen 0 1920x1080x24 >/tmp/xvfb-verify.log 2>&1 & own_x=$!
  export DISPLAY=:99; sleep 2
fi

/opt/scripts/start-resolve.sh >/tmp/resolve-verify.log 2>&1 &
pid=$!
echo "[verify] waiting 40s for Resolve to start..."
sleep 40
if kill -0 "$pid" 2>/dev/null; then
  ok "Resolve still running after 40s (pid $pid)"
  kill "$pid" 2>/dev/null; pkill -f /opt/resolve/bin/resolve 2>/dev/null  # only our own test instance
else
  tail -n 60 /tmp/resolve-verify.log >&2
  [[ -n "$own_x" ]] && kill "$own_x"
  fail "Resolve exited early (log: /tmp/resolve-verify.log)"
fi
[[ -n "$own_x" ]] && kill "$own_x" 2>/dev/null
ok "verification passed"
