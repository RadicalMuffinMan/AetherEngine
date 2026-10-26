#!/usr/bin/env bash
# Reproduces an MP4 whose writer dropped `ctts` and then forced its decode-order presentation times
# to be monotonic: every sample reports PTS == DTS, an anchor keeps its own time, and each B picture
# that follows it in decode order is pushed 1001 ticks (a third of a 29.97 fps frame) past the picture
# decoded before it. The decode ladder then has no single step, which the #409 classifier needs.
# QuickTime and the Files app (AVFoundation) show such a file with its pictures stepping back and
# forth; FFmpeg-based players reorder by picture order count and look right.
#
#   bframes-healthy.mp4  H.264 High 1280x720 29.97 fps, B pyramid, GOP 90, 30 s + AAC (the twin)
#   clamped-ladder.mp4   the same stream, ctts dropped, ladder clamped as above
#
# testsrc2 draws a frame counter and a moving bar, so the order is visible by eye.
#
# Usage:
#   ./Scripts/make-clamped-ladder-fixture.sh [output-dir] [--check]
#
# --check builds aetherctl and prints the #409 verdict (pktdump) and the decoded order (swdecode)
# for the clamped file. Requires ffmpeg with libx264 (macOS: `brew install ffmpeg`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/Fixtures/clamped-ladder"
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) OUT="$arg" ;;
  esac
done
mkdir -p "$OUT"
FF=(ffmpeg -hide_banner -loglevel error -y)

"${FF[@]}" \
  -f lavfi -i "testsrc2=size=1280x720:rate=30000/1001:duration=30" \
  -f lavfi -i "sine=frequency=440:duration=30" \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -bf 3 -g 90 -x264-params b-pyramid=normal \
  -c:a aac -b:a 128k -video_track_timescale 90000 -movflags +faststart \
  "$OUT/bframes-healthy.mp4"

# setts runs per packet in decode order, so PREV_OUTDTS is the timestamp just written: the clamp
# keeps every anchor (its PTS is already past everything before it) and pushes each B picture.
"${FF[@]}" -i "$OUT/bframes-healthy.mp4" -map 0 -c copy \
  -bsf:v 'setts=ts=max(PTS\,PREV_OUTDTS+1001)' -video_track_timescale 90000 -movflags +faststart \
  "$OUT/clamped-ladder.mp4"

echo "wrote $OUT/bframes-healthy.mp4"
echo "wrote $OUT/clamped-ladder.mp4"
ffprobe -v error -select_streams v:0 -show_entries packet=pts,dts -of csv=p=0 "$OUT/clamped-ladder.mp4" \
  | awk -F, 'NR > 1 { step[$2 - prev]++ } { if ($1 == $2) same++; prev = $2; n++ }
      END { printf "clamped-ladder.mp4: %d packets, PTS == DTS on %d, DTS steps:", n, same
            for (s in step) printf " %s x%d", s, step[s]; print "" }'

if [[ $CHECK -eq 1 ]]; then
  swift build --package-path "$REPO_ROOT" --product aetherctl >/dev/null 2>&1
  CTL="$(swift build --package-path "$REPO_ROOT" --product aetherctl --show-bin-path 2>/dev/null)/aetherctl"
  "$CTL" pktdump --count 12 "$OUT/clamped-ladder.mp4" 2>&1 | grep -E '#409' || echo "no #409 verdict line"
  "$CTL" swdecode --frames 300 "$OUT/clamped-ladder.mp4" 2>&1 | grep -E 'Steps backwards' || true
fi
