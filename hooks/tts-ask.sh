#!/bin/bash
# Voice Loop — PreToolUse[AskUserQuestion] hook：把选择题的题目和选项念出来。
# 永远 exit 0 不输出决策 JSON（不拦截工具，只旁路发声）。
# 开场白可用 CC_TTS_ASK_PHRASE 覆盖（默认「要选一下：」，英文可设 "Pick one: "）。
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
"$HOOK_DIR/speak.sh" --channel "${SESSION:-global}" --lane "$LANE" "${CC_TTS_ASK_PHRASE:-要选一下：}$Q"
exit 0
