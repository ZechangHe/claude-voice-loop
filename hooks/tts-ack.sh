#!/bin/bash
# Voice Loop — UserPromptSubmit hook：用户回车提交 = 上一条播报已消化，
# 清掉「应答闸」放行排队中的下一条（见 speak.sh 的 await-ack 逻辑）；
# 顺手记下「用户最近在哪个会话打字」—— speak.sh 开播时靠它判断要不要念「xx 这边：」。
set -u
CACHE_DIR="${TMPDIR:-/tmp}/cc-voice"
mkdir -p "$CACHE_DIR"
SID="$(cat | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SID" ] && printf '%s' "$SID" > "$CACHE_DIR/last-user-session"
rm -f "$CACHE_DIR/await-ack" 2>/dev/null
exit 0
