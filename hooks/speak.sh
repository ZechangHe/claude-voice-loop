#!/bin/bash
# Voice Loop — TTS 引擎。用法: speak.sh [--channel <会话id>] [--lane <车道名>] "要念的文本"
# edge-tts 生成 mp3 → afplay 播放；失败降级 macOS say。
# 同一 channel：新话打断旧话；不同 channel（多个 cv 会话）：排队播，不叠音不丢报。
# 应答闸：开播那刻落闸 await-ack（播放中的回车也算消化——原来播完才落，回话快了回车被吞），
# 下一条（别的 channel）要等用户回车（tts-ack.sh / UserPromptSubmit 清闸）才开播；
# 兜底 CC_TTS_ACK_TIMEOUT 秒（默认 45）强制放行——闸的本意是防背靠背连播，不是每条欠一次回车。
# Fn 闸：用户摁着 Fn 说话时不开播（fn-hush 摁下落旗标、每秒心跳、松开清），
# 松开 Fn 才放行；心跳断了（fn-hush 没在跑/已崩）按过期忽略，不会哑掉。
# 身份前缀：开播那刻才定（生成时定会串台——播报可能被闸憋着迟到）：
# 用户最近打字的会话 ≠ 本条、或上一条开播的 ≠ 本条 → 先念「<lane> 这边：」报家门。
# 环境旋钮：CC_VOICE_NAME=edge-tts 嗓音；CC_TTS_LANE_TEMPLATE=报家门句式（printf 模板，
# 默认「%s 这边：」，英文可设 "%s here: "）。
# 存在 tts-off 文件时全局静音。
set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

CHANNEL="global"
LANE=""
while [ $# -gt 1 ]; do
  case "$1" in
    --channel) CHANNEL="${2:-global}"; shift 2 ;;
    --lane)    LANE="${2:-}";          shift 2 ;;
    *) break ;;
  esac
done
TEXT="${1:-}"
[ -z "$TEXT" ] && exit 0
[ -f "$HOOK_DIR/tts-off" ] && exit 0

# 进声道前剥 markdown 符号——TTS 会把 ** 念成「星号星号」
TEXT="$(printf '%s' "$TEXT" | sed -E 's/[*`~]+//g; s/__+//g; s/^#+[[:space:]]*//')"
[ -z "${TEXT// /}" ] && exit 0

CACHE_DIR="${TMPDIR:-/tmp}/cc-voice"
mkdir -p "$CACHE_DIR"
SAFE_CH="$(printf '%s' "$CHANNEL" | tr -c 'a-zA-Z0-9_-' '_')"
PIDFILE="$CACHE_DIR/play-$SAFE_CH.pid"
LOCK="$CACHE_DIR/lock"
GATE="$CACHE_DIR/await-ack"
VOICE="${CC_VOICE_NAME:-zh-CN-YunjianNeural}"
LANE_TMPL="${CC_TTS_LANE_TEMPLATE:-%s 这边：}"
MP3="$CACHE_DIR/say-$SAFE_CH-$$.mp3"

# 同 channel：打断上一句（整个进程组，含排队中的）
if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$OLD" ] && kill -- "-$OLD" 2>/dev/null
fi

set -m  # 后台子 shell 拿独立进程组，便于整组打断
(
  # 子 shell 自己的 PID（= 进程组号）。macOS bash 3.2 无 $BASHPID，用 sh 的 $PPID 拿
  MYPID="$(sh -c 'echo $PPID')"

  # 报家门文本（「xx 这边：」）——句式可用 CC_TTS_LANE_TEMPLATE 覆盖
  PRE_TEXT=""
  # shellcheck disable=SC2059
  [ -n "$LANE" ] && PRE_TEXT="$(printf "$LANE_TMPL" "$LANE")"

  # 先合成（不占音频锁，排队时间只花在播放上）
  ENGINE=say
  if edge-tts --voice "$VOICE" --text "$TEXT" --write-media "$MP3" >/dev/null 2>&1 \
     && [ -s "$MP3" ]; then
    ENGINE=edge-tts
  fi

  # 车道报家门 mp3 按 内容×嗓音 落盘缓存（key 含文本哈希，换句式/嗓音自动重烤）
  PRE_MP3=""
  if [ -n "$PRE_TEXT" ] && [ "$ENGINE" = "edge-tts" ]; then
    SAFE_LANE="$(printf '%s' "$LANE" | tr -c 'a-zA-Z0-9_-' '_')"
    PRE_HASH="$(printf '%s|%s' "$PRE_TEXT" "$VOICE" | cksum | cut -d' ' -f1)"
    PRE_MP3="$CACHE_DIR/lane-$SAFE_LANE-$PRE_HASH.mp3"
    if [ ! -s "$PRE_MP3" ]; then
      edge-tts --voice "$VOICE" --text "$PRE_TEXT" --write-media "$PRE_MP3" >/dev/null 2>&1 \
        || rm -f "$PRE_MP3"
    fi
  fi

  # 音频锁：跨 channel 排队；锁主已死（被打断的残留）则接管；应答闸可能一等几分钟，
  # 兜底上限放到 30min（纯防死锁，正常永远碰不到）
  n=0
  OWNED=0
  while :; do
    if mkdir "$LOCK" 2>/dev/null; then
      echo "$MYPID" > "$LOCK/owner"
      OWNED=1
      break
    fi
    OWNER="$(cat "$LOCK/owner" 2>/dev/null || true)"
    if [ -n "$OWNER" ] && ! kill -0 -- "-$OWNER" 2>/dev/null; then
      rm -rf "$LOCK" 2>/dev/null
      continue
    fi
    n=$((n+1))
    [ "$n" -gt 6000 ] && break
    sleep 0.3
  done

  # 应答闸：上一条播报还没被用户回车消化 → 憋住不播。
  # 同 channel 自己的后续播报不受闸（同一条 CLI 接着说，不用等确认，也防自锁死）。
  # tts-ack.sh（UserPromptSubmit）清闸放行；兜底超时后强制放行。
  MAXG=$(( ${CC_TTS_ACK_TIMEOUT:-45} * 10 / 3 ))
  g=0
  while [ -f "$GATE" ] && [ "$(cat "$GATE" 2>/dev/null)" != "$CHANNEL" ]; do
    [ -f "$HOOK_DIR/tts-off" ] && break
    g=$((g+1))
    [ "$g" -gt "$MAXG" ] && break
    sleep 0.3
  done

  # Fn 闸：旗标在且 3 秒内有心跳 = 用户正摁着 Fn 说话，憋住；过期视为残留，照播。
  # 旗标路径按 hush.sh 同款兜底——fn-hush 跑在 launchd 下，TMPDIR 可能未设。
  FN_FLAG="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)}/cc-voice/fn-down"
  f=0
  while [ -f "$FN_FLAG" ]; do
    AGE=$(( $(date +%s) - $(stat -f %m "$FN_FLAG" 2>/dev/null || echo 0) ))
    [ "$AGE" -gt 3 ] && break
    [ -f "$HOOK_DIR/tts-off" ] && break
    f=$((f+1))
    [ "$f" -gt 6000 ] && break
    sleep 0.3
  done

  # 身份前缀开播那刻才定：用户最近打字的不是这条 CLI、或耳朵上一条听的不是它 → 报家门
  SPEAK_PREFIX=0
  if [ -n "$LANE" ]; then
    LAST_IN="$(cat "$CACHE_DIR/last-user-session" 2>/dev/null || true)"
    LAST_PLAY="$(cat "$CACHE_DIR/last-played" 2>/dev/null || true)"
    if [ "$LAST_IN" != "$CHANNEL" ] || [ "$LAST_PLAY" != "$CHANNEL" ]; then
      SPEAK_PREFIX=1
    fi
  fi

  # 排队期间可能被 mute 了，播前再查一次
  if [ ! -f "$HOOK_DIR/tts-off" ]; then
    # 开播即落闸/记账：播放中的回车也能清闸放行下一条
    printf '%s' "$CHANNEL" > "$GATE"
    printf '%s' "$CHANNEL" > "$CACHE_DIR/last-played"
    echo "$ENGINE" > "$CACHE_DIR/last-engine"
    if [ "$ENGINE" = "edge-tts" ]; then
      if [ "$SPEAK_PREFIX" -eq 1 ] && [ -s "$PRE_MP3" ]; then afplay "$PRE_MP3"; fi
      afplay "$MP3"
    else
      MSG="$TEXT"
      [ "$SPEAK_PREFIX" -eq 1 ] && MSG="${PRE_TEXT}${TEXT}"
      say "$MSG"
    fi
  fi
  rm -f "$MP3"
  [ "$OWNED" -eq 1 ] && rm -rf "$LOCK"
) </dev/null >/dev/null 2>&1 &
echo $! > "$PIDFILE"
exit 0
