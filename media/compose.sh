#!/bin/sh
# Co-stream compositor. MediaMTX runs this on demand for path costream/<session_id> (see mediamtx.yml)
# and stops it with SIGINT when nobody watches. The backend decides who is on screen:
#   GET $LEAGUEHUB_API/internal/media/costream/<session>/plan  ->  LAYOUT, XSTACK and one INPUT per tile
# Output: one H.264 video, tiles of 640x360 arranged by ffmpeg xstack (1 tile = 1280x720). No audio mix yet.
set -u
SESSION="$1"
AUTH="$LEAGUEHUB_MEDIA_USER:$LEAGUEHUB_MEDIA_PASS"
RTSP="rtsp://$AUTH@127.0.0.1:${RTSP_PORT:-8554}"

PLAN=$(wget -q -O - "$LEAGUEHUB_API/internal/media/costream/$SESSION/plan?token=$LEAGUEHUB_HOOK_TOKEN") || {
  echo "compose.sh: no plan for $SESSION (missing or terminated session)" >&2; sleep 3; exit 1; }

ARGS=""; LABELS=""; SCALE=""; XSTACK=""; N=0
while read -r KIND VALUE; do
  case "$KIND" in
    XSTACK) XSTACK="$VALUE" ;;
    INPUT)
      ARGS="$ARGS -rtsp_transport tcp -i $RTSP/$VALUE"
      SCALE="$SCALE[$N:v]scale=640:360,setsar=1[v$N];"
      LABELS="$LABELS[v$N]"
      N=$((N + 1)) ;;
  esac
done <<EOF
$PLAN
EOF

if [ "$N" -eq 0 ]; then echo "compose.sh: plan has no inputs" >&2; sleep 3; exit 1; fi
if [ "$N" -eq 1 ]; then
  FILTER="[0:v]scale=1280:720,setsar=1[out]"
else
  FILTER="${SCALE}${LABELS}xstack=inputs=$N:layout=$XSTACK:fill=black[out]"
fi

# exec: ffmpeg replaces the shell, so MediaMTX's SIGINT stops the encoder itself (no orphan process)
# shellcheck disable=SC2086
exec ffmpeg -hide_banner -loglevel warning $ARGS -filter_complex "$FILTER" -map "[out]" \
  -c:v libx264 -preset veryfast -tune zerolatency -g 30 -an -f rtsp "$RTSP/costream/$SESSION"
