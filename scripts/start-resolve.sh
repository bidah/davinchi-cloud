#!/usr/bin/env bash
#
# Launch DaVinci Resolve on the sandbox desktop (the X display started by
# Daytona Computer Use). Uses VirtualGL's EGL back end so OpenGL renders on the
# NVIDIA GPU; falls back to Mesa software GL when no GPU EGL is available.
#
#   start-resolve.sh            # foreground
#   RESOLVE_LOG=/tmp/resolve.log start-resolve.sh &
#
set -uo pipefail

if [[ -z "${DISPLAY:-}" ]]; then
  sock="$(ls /tmp/.X11-unix/ 2>/dev/null | sort | head -1)"
  export DISPLAY=":${sock#X}"
  [[ "$DISPLAY" == ":" ]] && export DISPLAY=":0"
fi

# Daytona's NVIDIA runtime mounts libEGL_nvidia.so.<ver> etc. but does not run
# ldconfig, so the .so.0 sonames glvnd looks for are missing -> create them.
if ls /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.* >/dev/null 2>&1 \
   && [[ ! -e /usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.0 ]]; then
  sudo -n ldconfig 2>/dev/null || ldconfig 2>/dev/null || true
fi

RESOLVE=/opt/resolve/bin/resolve
export LD_LIBRARY_PATH="/opt/resolve/libs:${LD_LIBRARY_PATH:-}"

if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 \
   && [[ -e /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]] && command -v vglrun >/dev/null; then
  echo "[start-resolve] DISPLAY=$DISPLAY, GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1), VirtualGL EGL"
  exec vglrun -d egl "$RESOLVE" "$@"
else
  echo "[start-resolve] DISPLAY=$DISPLAY, no NVIDIA EGL found, using software GL (slow)"
  export LIBGL_ALWAYS_SOFTWARE=1
  exec "$RESOLVE" "$@"
fi
