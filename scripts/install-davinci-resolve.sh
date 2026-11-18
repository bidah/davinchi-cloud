#!/usr/bin/env bash
#
# Unattended DaVinci Resolve (Linux) install from Blackmagic's official
# installer. Runs as root during the image build.
#
#   install-davinci-resolve.sh [DIR]   # DIR holds DaVinci_Resolve*_Linux.zip or *.run
#
# Recipe follows davincibox (github.com/zelikos/davincibox):
#   extract the AppImage-style .run -> AppRun -i -a -y with SKIP_PACKAGE_CHECK,
#   then patch binaries to use the system glib stack.
#
set -euo pipefail
log() { echo "[resolve-install] $*"; }
die() { echo "[resolve-install] ERROR: $*" >&2; exit 1; }

SRC="${1:-/tmp/installer}"
WORK="$(mktemp -d)"
shopt -s nullglob nocaseglob

zips=("$SRC"/DaVinci_Resolve*Linux*.zip)
runs=("$SRC"/DaVinci_Resolve*Linux*.run)

if [[ ${#runs[@]} -gt 0 ]]; then
  RUN_FILE="${runs[0]}"
elif [[ ${#zips[@]} -gt 0 ]]; then
  log "unzipping ${zips[0]}"
  unzip -q -o "${zips[0]}" -d "$WORK/zip"
  found=("$WORK"/zip/*.run "$WORK"/zip/*/*.run)
  [[ ${#found[@]} -gt 0 ]] || die "no .run inside ${zips[0]}"
  RUN_FILE="${found[0]}"
else
  die "No installer in $SRC. Put DaVinci_Resolve[_Studio]_<ver>_Linux.zip (or .run) in ./optional/
  Download it from https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion"
fi
shopt -u nocaseglob

log "installer: $(basename "$RUN_FILE")"
chmod +x "$RUN_FILE"

cd "$WORK"
log "extracting installer"
"$RUN_FILE" --appimage-extract >/dev/null
[[ -x "$WORK/squashfs-root/AppRun" ]] || die "extraction failed (no squashfs-root/AppRun)"

log "running installer (unattended)"
QT_QPA_PLATFORM=minimal SKIP_PACKAGE_CHECK=1 "$WORK/squashfs-root/AppRun" -i -a -y \
  || log "installer exited non-zero (often udev/desktop steps in containers); verifying files"

[[ -x /opt/resolve/bin/resolve ]] || die "/opt/resolve/bin/resolve missing after install"

# Resolve bundles an old glib; force the system one (davincibox workaround).
log "patching binaries to load system glib"
LIBDIR=/usr/lib/x86_64-linux-gnu
args=()
for lib in libglib-2.0.so.0 libgdk_pixbuf-2.0.so.0 libgio-2.0.so.0 libgmodule-2.0.so.0; do
  [[ -e "$LIBDIR/$lib" ]] && args+=(--add-needed "$LIBDIR/$lib")
done
find /opt/resolve/bin -maxdepth 1 -type f -executable -print0 | while IFS= read -r -d '' bin; do
  if file -b "$bin" | grep -q ELF; then patchelf "${args[@]}" "$bin" || log "patchelf skipped $bin"; fi
done

# BRAW companion tools crash on the bundled OpenCL decoder without a GPU ICD.
for dec in /opt/resolve/BlackmagicRAWPlayer/BlackmagicRawAPI/libDecoderOpenCL.so \
           /opt/resolve/BlackmagicRAWSpeedTest/BlackmagicRawAPI/libDecoderOpenCL.so; do
  [[ -f "$dec" ]] && mv "$dec" "$dec.bak"
done

mkdir -p /var/BlackmagicDesign
rm -rf "$WORK" "$SRC"

log "missing shared libs (should be empty):"
LD_LIBRARY_PATH=/opt/resolve/libs ldd /opt/resolve/bin/resolve | grep "not found" | grep -v -E "libcuda|libnvidia" || true
log "installed: $(ls /opt/resolve)"
log "done"
