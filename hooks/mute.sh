#!/bin/bash
# Voice Loop 静音开关（toggle）：静音时掐断所有正在播/排队的播报；恢复时口头确认。
set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
F="$HOOK_DIR/tts-off"
CACHE_DIR="${TMPDIR:-/tmp}/cc-voice"

# 静音/恢复都清应答闸，别让陈旧闸卡住恢复后的第一条播报
rm -f "$CACHE_DIR/await-ack" 2>/dev/null

if [ -f "$F" ]; then
  rm -f "$F"
  echo "🔊 播报已恢复"
  "$HOOK_DIR/speak.sh" "播报已恢复"
else
  touch "$F"
  for P in "$CACHE_DIR"/play-*.pid; do
    [ -f "$P" ] || continue
    PID="$(cat "$P" 2>/dev/null || true)"
    [ -n "$PID" ] && kill -- "-$PID" 2>/dev/null
    rm -f "$P"
  done
  rm -rf "$CACHE_DIR/lock" 2>/dev/null
  echo "🔇 已静音（再敲一次 mute 恢复）"
fi
exit 0
