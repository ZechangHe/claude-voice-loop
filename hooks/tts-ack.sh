#!/bin/bash
# Voice Loop — UserPromptSubmit hook：用户回车提交 = 上一条播报已消化，
# 清掉「应答闸」放行排队中的下一条（见 speak.sh 的 await-ack 逻辑）；
# 顺手记下「用户最近在哪个会话打字」—— speak.sh 开播时靠它判断要不要念「xx 这边：」。
# 并给这个会话落一个「过期水位」：你既然已经在这条 CLI 上回复了，它排在队里还没开口的
# 那条播报你早就在屏幕上读完了——再念就成了「你回复完它才开始播」。号 ≤ 水位的排队播报
# 自己弃权；这次回复的答复是回车之后才拿的号，号更大，不受影响。
set -u
CACHE_DIR="${TMPDIR:-/tmp}/cc-voice"
mkdir -p "$CACHE_DIR"
SID="$(cat | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -n "$SID" ]; then
  printf '%s' "$SID" > "$CACHE_DIR/last-user-session"
  SAFE="$(printf '%s' "$SID" | tr -c 'a-zA-Z0-9_-' '_')"
  [ -f "$CACHE_DIR/seq" ] && cp "$CACHE_DIR/seq" "$CACHE_DIR/drop-$SAFE" 2>/dev/null
fi
rm -f "$CACHE_DIR/await-ack" 2>/dev/null
exit 0
