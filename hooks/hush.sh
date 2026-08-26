#!/bin/bash
# Voice Loop 一次性闭嘴：掐断所有正在播/排队的播报，但不进入静音状态——
# 下一轮播报照常。由 fn-hush（全局 Fn 键监听器）在按下 Fn 时调用；也可手动跑。
# 掐断逻辑与 mute.sh 的静音分支保持一致（进程组整组 kill + 清音频锁）。
set -u
# speak.sh 用 ${TMPDIR:-/tmp}；launchd 环境 TMPDIR 可能未设，用 getconf 兜到
# 同一个 per-user 临时目录（GUI 进程的 TMPDIR 就是它）。
CACHE_DIR="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)}/cc-voice"
for P in "$CACHE_DIR"/play-*.pid; do
  [ -f "$P" ] || continue
  PID="$(cat "$P" 2>/dev/null || true)"
  [ -n "$PID" ] && kill -- "-$PID" 2>/dev/null
  rm -f "$P"
done
rm -rf "$CACHE_DIR/lock" "$CACHE_DIR/qlock" 2>/dev/null
exit 0
