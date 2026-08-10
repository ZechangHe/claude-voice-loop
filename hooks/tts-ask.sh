#!/bin/bash
# Voice Loop — PreToolUse[AskUserQuestion] hook：把选择题的题目和选项念出来。
# 永远 exit 0 不输出决策 JSON（不拦截工具，只旁路发声）。
# 开场白可用 CC_TTS_ASK_PHRASE 覆盖（默认「要选一下：」，英文可设 "Pick one: "）。
# 多 agent 车道模式（mcv，CC_VOICE_MULTI=1）：题面不念，只报「<车道名> 要你确认」——
# 几条 CLI 并行时耳朵只需要知道该去哪条看（句式 CC_TTS_ASK_MULTI_TEMPLATE 可覆盖）。
set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${CC_VOICE:-0}" != "1" ]; then
  cat >/dev/null
  exit 0
fi

INPUT="$(cat)"
Q="$(printf '%s' "$INPUT" | jq -r '
  [ .tool_input.questions // [] | .[]
    | (.question // "")
      + ( if ((.options // []) | length) > 0
          then "。选项：" + ((.options // []) | map(.label // "") | join("，"))
          else "" end )
  ] | join("。")
' 2>/dev/null)"

[ -z "$Q" ] && exit 0
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "global"' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
LANE=""
[ -n "$CWD" ] && LANE="$(basename "$CWD" | sed -E 's/^[a-z]+\+//')"

if [ "${CC_VOICE_MULTI:-0}" = "1" ]; then
  # shellcheck disable=SC2059
  MSG="$(printf "${CC_TTS_ASK_MULTI_TEMPLATE:-%s 要你确认}" "$LANE" | sed -E 's/^[[:space:]]+//')"
  "$HOOK_DIR/speak.sh" --channel "${SESSION:-global}" --lane "" "$MSG"
else
  "$HOOK_DIR/speak.sh" --channel "${SESSION:-global}" --lane "$LANE" "${CC_TTS_ASK_PHRASE:-要选一下：}$Q"
fi
exit 0
