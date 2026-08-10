#!/bin/bash
# Voice Loop — Stop hook：回复结束后朗读播报。
# 提取回复里的「🔊 …」播报行；没有则剥掉代码/markdown 后念开头（≤200 字，
# 在最后一个完整句处收尾 + 补「细节在屏幕上」，不念半截话）。
# 全文模式（fcv，CC_VOICE_FULL=1）：不取 🔊 行，整篇回复剥码后完整朗读，不截断。
# 多 agent 车道模式（mcv，CC_VOICE_MULTI=1）：不念正文，只报一句「<车道名> 搞定了」——
#   几条 CLI 并行时耳朵只需要知道「谁干完了」；模型主动留了 🔊 行（卡住/要拍板）才改念
#   「<车道名>：<那句>」。车道名已在正文里，所以不再让 speak.sh 报家门（--lane 传空）。
# --dry-run：只打印将要念的文本，不发声（机器测试用，绕过 CC_VOICE 门）。
set -u
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

# 剥代码围栏/行内代码/markdown 链接与标记，压成 TTS 可念的一行（表格竖线一并转空格）
strip_md() {
  awk '/^[[:space:]]*```/{f=!f;next} !f' \
    | sed -E 's/`[^`]*`//g' \
    | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    | sed -E 's/^[[:space:]]*[#>*|-]+[[:space:]]*//' \
    | tr '\n|' '  ' \
    | sed -E 's/  +/ /g'
}

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

# 会话门：只有 CC_VOICE=1 的会话（cv 启动）才出声
if [ "$DRY" -eq 0 ] && [ "${CC_VOICE:-0}" != "1" ]; then
  exit 0
fi

INPUT="$(cat)"
TEXT="$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')"
[ -z "$TEXT" ] && exit 0
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "global"')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"

# 车道名 = cwd 目录名（剥掉 feat+/fix+ 前缀）。多 agent 模式念它，其余模式交给
# speak.sh 决定要不要报家门——念不念在开播那刻定，生成时定会串台（播报可能被闸憋着迟到）
LANE=""
[ -n "$CWD" ] && LANE="$(basename "$CWD" | sed -E 's/^[a-z]+\+//')"
SPEAK_LANE="$LANE"

if [ "${CC_VOICE_MULTI:-0}" = "1" ]; then
  # mcv 多 agent 车道模式：固定短句，正文一律不念
  NOTE="$(printf '%s\n' "$TEXT" | grep '^🔊' | sed 's/^🔊[[:space:]]*//' | tr '\n' ' ')"
  if [ -n "${NOTE// /}" ]; then
    # shellcheck disable=SC2059
    if [ -n "$LANE" ]; then
      SPOKEN="$(printf "${CC_TTS_NOTE_TEMPLATE:-%s：%s}" "$LANE" "$NOTE")"
    else
      SPOKEN="$NOTE"
    fi
  else
    # shellcheck disable=SC2059
    SPOKEN="$(printf "${CC_TTS_DONE_TEMPLATE:-%s 搞定了}" "$LANE")"
  fi
  SPEAK_LANE=""   # 车道名已经在正文里，别再报一次家门
elif [ "${CC_VOICE_FULL:-0}" = "1" ]; then
  # fcv 全文模式：整篇剥码后全念，不截断；万一混进 🔊 行只剥前缀不丢内容
  SPOKEN="$(printf '%s\n' "$TEXT" | sed 's/^🔊[[:space:]]*//' | strip_md)"
else
  # 优先取 🔊 播报行（可多行，合并）
  SPOKEN="$(printf '%s\n' "$TEXT" | grep '^🔊' | sed 's/^🔊[[:space:]]*//' | tr '\n' ' ')"

  # fallback：剥代码围栏/行内代码/markdown 符号，念开头。超 200 字时回退到
  # 200 字内最后一个句末标点收尾（找不到才保留硬截），再补「细节在屏幕上」——
  # 保证播报永远是完整句，不会念到一半戛然而止。
  if [ -z "${SPOKEN// /}" ]; then
    SPOKEN="$(printf '%s\n' "$TEXT" \
      | strip_md \
      | jq -Rrs 'gsub("^\\s+|\\s+$"; "")
          | if length <= 200 then .
            else (.[0:200] | sub("^(?<keep>.*[。！？!?；…]).*$"; .keep)) + " 细节在屏幕上。"
            end')"
  fi
fi

SPOKEN="$(printf '%s' "$SPOKEN" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -z "$SPOKEN" ] && exit 0

if [ "$DRY" -eq 1 ]; then
  printf '%s\n' "$SPOKEN"
  exit 0
fi

"$HOOK_DIR/speak.sh" --channel "$SESSION" --lane "$SPEAK_LANE" "$SPOKEN"
exit 0
