#!/usr/bin/env bash
#
# Resolve FREE on Linux can't decode or encode H.264 / H.265, or AAC audio
# (Blackmagic licenses those only for Studio on Linux). This converts around it:
#
#   media-convert.sh ingest [dir]    H.264/H.265/AAC files under dir (default
#                                    ~/media/footage) -> <dir>/_edit/<name>.mov
#                                    DNxHR (HQ, or HQX for 10-bit) + PCM: import these
#   media-convert.sh deliver FILE    a render (DNxHR/ProRes .mov) -> <same dir>/<name>.mp4
#                                    H.264 (GPU NVENC, CPU x264 fallback) + AAC
#
# Already-converted files are skipped. ffmpeg writes to local disk first and then
# copies, because the volume (mountpoint-s3) can't seek back into a file.
set -uo pipefail

MEDIA="${RESOLVE_MEDIA:-$HOME/media}"
TMP="${TMPDIR:-/tmp}/media-convert"; mkdir -p "$TMP"
log() { echo "[media] $*"; }

probe() {  # probe FILE STREAM FIELD
  ffprobe -v error -select_streams "$2" -show_entries "stream=$3" -of csv=p=0 "$1" 2>/dev/null | head -1
}

needs_ingest() {
  local v a; v="$(probe "$1" v:0 codec_name)"; a="$(probe "$1" a:0 codec_name)"
  [[ "$v" == h264 || "$v" == hevc || "$a" == aac ]]
}

ingest_one() {
  local src="$1" dir="$2" rel stem out tmp v pix profile pixout vargs
  rel="${src#"$dir"/}"; stem="${rel%.*}"
  v="$(probe "$src" v:0 codec_name)"
  if [[ -z "$v" ]]; then
    # audio only (e.g. .m4a): just PCM
    out="$dir/_edit/$stem.wav"
    [[ -s "$out" ]] && { log "skip $rel (done)"; return 0; }
    mkdir -p "$(dirname "$out")"; tmp="$TMP/$(basename "$out")"
    ffmpeg -nostdin -v error -y -i "$src" -c:a pcm_s24le "$tmp" && cp "$tmp" "$out" && rm -f "$tmp" \
      && log "ok   $rel -> _edit/$stem.wav" || log "FAIL $rel"
    return
  fi
  out="$dir/_edit/$stem.mov"
  [[ -s "$out" ]] && { log "skip $rel (done)"; return 0; }
  pix="$(probe "$src" v:0 pix_fmt)"
  if [[ "$pix" == *10* || "$pix" == *12* ]]; then profile=dnxhr_hqx; pixout=yuv422p10le
  else profile=dnxhr_hq; pixout=yuv422p; fi
  # DNxHR needs even dimensions.
  vargs=(-c:v dnxhd -profile:v "$profile" -pix_fmt "$pixout" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2")
  mkdir -p "$(dirname "$out")"; tmp="$TMP/$(basename "$out")"
  log "conv $rel ($v $pix -> $profile)"
  if ffmpeg -nostdin -v error -stats -y -i "$src" -map 0:v:0 -map '0:a?' "${vargs[@]}" \
       -c:a pcm_s24le -map_metadata 0 "$tmp" && cp "$tmp" "$out"; then
    log "ok   $rel -> _edit/$stem.mov ($(du -h "$out" | cut -f1))"
  else
    log "FAIL $rel"; rm -f "$out"
  fi
  rm -f "$tmp"
}

ingest() {
  local dir="${1:-$MEDIA/footage}" n=0 f
  # On the S3 volume an empty folder only exists while it holds a file.
  [[ -d "$dir" ]] || { mkdir -p "$dir"; log "nothing in $dir yet (push footage there first)"; return 0; }
  while IFS= read -r -d '' f; do
    needs_ingest "$f" || continue
    ingest_one "$f" "$dir"; n=$((n + 1))
  done < <(find "$dir" -type f -not -path "*/_edit/*" \
             \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.mkv' -o -iname '*.mts' \
                -o -iname '*.m2ts' -o -iname '*.avi' -o -iname '*.m4a' -o -iname '*.aac' \) -print0 | sort -z)
  log "$n H.264/H.265/AAC file(s) in $dir (new ones converted); import from $dir/_edit"
}

deliver() {
  local src="$1" out tmp
  [[ -f "$src" ]] || { log "no file $src"; return 1; }
  out="${src%.*}.mp4"; [[ "$out" == "$src" ]] && out="${src%.*}-h264.mp4"
  tmp="$TMP/$(basename "$out")"
  log "deliver $(basename "$src") -> $(basename "$out")"
  if ! ffmpeg -nostdin -v error -stats -y -i "$src" -c:v h264_nvenc -preset p6 -rc vbr -cq 19 -b:v 0 \
         -pix_fmt yuv420p -c:a aac -b:a 320k -movflags +faststart "$tmp"; then
    log "NVENC unavailable, using x264"
    ffmpeg -nostdin -v error -stats -y -i "$src" -c:v libx264 -preset slow -crf 18 \
      -pix_fmt yuv420p -c:a aac -b:a 320k -movflags +faststart "$tmp" || { log "FAIL"; return 1; }
  fi
  cp "$tmp" "$out" && rm -f "$tmp" && log "ok   $out ($(du -h "$out" | cut -f1))"
}

case "${1:-}" in
  ingest) ingest "${2:-}" ;;
  deliver) [[ -n "${2:-}" ]] || { echo "usage: $0 deliver FILE" >&2; exit 2; }; deliver "$2" ;;
  *) echo "usage: $0 ingest [dir] | deliver FILE" >&2; exit 2 ;;
esac
