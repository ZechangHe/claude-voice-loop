#!/bin/bash
# Voice Loop — TTS 引擎。用法: speak.sh [--channel <会话id>] [--lane <车道名>] "要念的文本"
# edge-tts 生成 mp3 → afplay 播放；失败降级 macOS say。
# 同一 channel：新话打断旧话；不同 channel（多个 cv 会话）：排队播，不叠音不丢报。
#
# 播报队列（FIFO，按「干完活」的先后）：进来先拿号（$SEQ）再合成——号在合成之前拿，
# 所以顺序只认「谁先干完」，跟 edge-tts 快慢、跟谁先抢到锁都无关（老版本是 mkdir 抢锁，
# 谁的轮询恰好撞上释放那刻谁播 = 乱序）。只有队头能开口，这也顺带做了互斥。
# 排队者每 0.15s 复查一次队头，并顺手剔除已死的号（被打断/崩掉的），队列不会被卡住。
#
# 应答闸：开播那刻落闸 await-ack（播放中的回车也算消化），下一条（别的 channel）要等用户
# 回车（tts-ack.sh / UserPromptSubmit 清闸）才开播；兜底 CC_TTS_ACK_TIMEOUT 秒（默认 45）。
# 过期作废：你回复了某条 CLI（在它那儿敲了回车）= 它排在队里那条播报你早已在屏幕上读完，
# 再念就是「回复完了它才开口」。tts-ack.sh 会落一个水位号 drop-<channel>，号 ≤ 水位的
# 排队播报自己弃权退出；水位之后新拿的号（正是这次回复的答复）不受影响。
# 多 agent 车道模式（mcv，CC_VOICE_MULTI=1）整体绕开应答闸：既不等闸也不落闸
# （落了会把别的 cv 会话憋住），一条播完下一条立刻接上，中间只留 0.35s 换气。排队照旧。
# Fn 闸：用户摁着 Fn 说话时不开播（fn-hush 摁下落旗标、每秒心跳、松开清），
# 松开 Fn 才放行；心跳断了（fn-hush 没在跑/已崩）按过期忽略，不会哑掉。
# 身份前缀：开播那刻才定（生成时定会串台——播报可能被闸憋着迟到）：
# 用户最近打字的会话 ≠ 本条、或上一条开播的 ≠ 本条 → 先念「<lane> 这边：」报家门。
# 环境旋钮：CC_TTS_RATE=语速（edge-tts 格式，默认 +25%；要更快 +40%，回原速 +0%）；
# CC_TTS_SAY_RATE=say 降级时的语速（词/分钟，默认 210，系统默认约 175）；
# CC_TTS_SAY_VOICE=say 降级用的嗓音（默认 auto：文本带汉字且本机装了 Tingting 就点名它，
# 否则系统默认嗓音；系统默认嗓音多半是英文的，拿到中文会念成一串乱音——2026-10-14 实测
# 「FFFFFF」就是它；填任意 `say -v '?'` 里的名字可强制，填空串 = 永远系统默认）；
# 每次开播在 $TMPDIR/cc-voice/engine.log 记一行（时间 / 会话 / 引擎 / 降级原因 / 文本开头），
# 嗓音突然不对劲先看它；超 2000 行自动砍到 1000；
# CC_VOICE_NAME=edge-tts 嗓音；CC_TTS_LANE_TEMPLATE=报家门句式（printf 模板，
# 默认「%s 这边：」，英文可设 "%s here: "）；CC_TTS_SYNTH_TIMEOUT=合成挂死的兜底秒数
# （默认 12——队头卡在合成上会拖住整队，超时就掐掉降级 say）。
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
QUEUE="$CACHE_DIR/queue"
QLOCK="$CACHE_DIR/qlock"
SEQF="$CACHE_DIR/seq"
DROPF="$CACHE_DIR/drop-$SAFE_CH"
GATE="$CACHE_DIR/await-ack"
MULTI="${CC_VOICE_MULTI:-0}"
VOICE="${CC_VOICE_NAME:-zh-CN-YunjianNeural}"
LANE_TMPL="${CC_TTS_LANE_TEMPLATE:-%s 这边：}"
SYNTH_TO="${CC_TTS_SYNTH_TIMEOUT:-12}"
RATE="${CC_TTS_RATE:-+25%}"
SAY_RATE="${CC_TTS_SAY_RATE:-210}"
SAY_VOICE="${CC_TTS_SAY_VOICE-auto}"
ELOG="$CACHE_DIR/engine.log"
MP3="$CACHE_DIR/say-$SAFE_CH-$$.mp3"

# 同 channel：打断上一句（整个进程组，含排队中的）
if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$OLD" ] && kill -- "-$OLD" 2>/dev/null
fi

set -m  # 后台子 shell 拿独立进程组，便于整组打断
(
  # 组内再开的后台任务（合成、超时看门狗）留在本组里，整组打断才掐得干净
  set +m
  # 子 shell 自己的 PID（= 进程组号）。macOS bash 3.2 无 $BASHPID，用 sh 的 $PPID 拿
  MYPID="$(sh -c 'echo $PPID')"

  # 队列互斥：临界区都是几毫秒的文件读写；万一持锁者被 kill 掉，10 秒后砸开
  qlock() {
    i=0
    while :; do
      mkdir "$QLOCK" 2>/dev/null && return 0
      i=$((i+1))
      [ "$i" -gt 500 ] && { rm -rf "$QLOCK" 2>/dev/null; i=0; }
      sleep 0.02
    done
  }
  qunlock() { rm -rf "$QLOCK" 2>/dev/null; }

  # 拿号入队 —— 在合成之前，号才等于「干完活的先后」
  qlock
  SEQ=$(( $(cat "$SEQF" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$SEQ" > "$SEQF"
  printf '%s %s %s\n' "$SEQ" "$SAFE_CH" "$MYPID" >> "$QUEUE"
  qunlock

  q_leave() {
    qlock
    if [ -f "$QUEUE" ]; then
      awk -v me="$MYPID" '$3 != me' "$QUEUE" > "$QUEUE.$MYPID" 2>/dev/null
      mv "$QUEUE.$MYPID" "$QUEUE" 2>/dev/null
    fi
    qunlock
  }

  # 轮到我了吗：先剔除已死的号（被打断/崩掉的进程组），再看队头是不是我
  q_my_turn() {
    qlock
    HEAD=""
    if [ -f "$QUEUE" ]; then
      : > "$QUEUE.$MYPID"
      while read -r qs qc qp; do
        [ -z "${qs:-}" ] && continue
        if [ "$qp" != "$MYPID" ] && ! kill -0 -- "-$qp" 2>/dev/null; then continue; fi
        printf '%s %s %s\n' "$qs" "$qc" "$qp" >> "$QUEUE.$MYPID"
        [ -z "$HEAD" ] && HEAD="$qs"
      done < "$QUEUE"
      mv "$QUEUE.$MYPID" "$QUEUE" 2>/dev/null
    fi
    qunlock
    [ "$HEAD" = "$SEQ" ]
  }

  # 用户已经回复过这条 CLI（tts-ack.sh 落的水位号）→ 这条播报过期了，弃权
  stale() {
    [ -f "$DROPF" ] || return 1
    D="$(cat "$DROPF" 2>/dev/null || echo 0)"
    case "$D" in ''|*[!0-9]*) return 1 ;; esac
    [ "$D" -ge "$SEQ" ]
  }
  give_up() { q_leave; rm -f "$MP3" "$MP3.err"; exit 0; }

  # edge-tts 端点垫片（2026-10-12）：微软把朗读服务搬到 api.msedgeservices.com，旧端点握手 403，
  # PyPI 上的 edge-tts 还指着旧端点。垫片文件在 → 用装着 edge_tts 的那个 python 跑垫片
  # （先认 edge-tts 命令自己的 shebang，再试 python3 / python——Windows 的 python3 是商店空壳）；
  # 垫片不在或找不到 python → 正牌 edge-tts 命令。上游修好后删垫片文件即回落。
  EDGE_SHIM="${CC_TTS_EDGE_SHIM:-$HOOK_DIR/edge-tts-shim.py}"
  EDGE_PY=""
  if [ -f "$EDGE_SHIM" ]; then
    SHEBANG_PY="$(sed -n '1s/^#![[:space:]]*//p' "$(command -v edge-tts 2>/dev/null || echo /dev/null)" 2>/dev/null)"
    for py in "$SHEBANG_PY" python3 python; do
      [ -n "$py" ] || continue
      "$py" -c 'import importlib.util as u,sys; sys.exit(u.find_spec("edge_tts") is None)' >/dev/null 2>&1 \
        && { EDGE_PY="$py"; break; }
    done
  fi

  # 合成带超时：队头卡在合成上会拖住整个队列，挂死就掐掉降级 say。
  # 失败原因留在 SYNTH_ERR（stderr 最后一行有料的 / 超时 / 空输出），开播时记进 engine.log。
  SYNTH_ERR=""
  synth() { # $1=文本 $2=输出 mp3
    SYNTH_ERR=""
    ERRF="$2.err"
    if [ -n "$EDGE_PY" ]; then
      "$EDGE_PY" "$EDGE_SHIM" --voice "$VOICE" --rate "$RATE" --text "$1" --write-media "$2" >/dev/null 2>"$ERRF" &
    else
      command -v edge-tts >/dev/null 2>&1 || { SYNTH_ERR="edge-tts not installed"; return 1; }
      edge-tts --voice "$VOICE" --rate "$RATE" --text "$1" --write-media "$2" >/dev/null 2>"$ERRF" &
    fi
    ep=$!
    s=0
    timed_out=0
    while kill -0 "$ep" 2>/dev/null; do
      s=$((s+1))
      [ "$s" -gt $((SYNTH_TO * 20)) ] && { kill "$ep" 2>/dev/null; timed_out=1; break; }
      sleep 0.05
    done
    wait "$ep" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$timed_out" = 1 ]; then
        SYNTH_ERR="timeout after ${SYNTH_TO}s"
      else
        # 7.3.0 起 edge-tts 往 stderr 画进度条，跳过带百分号的行，只留最后一行真报错
        SYNTH_ERR="$(grep -vE '^[[:space:]]*$|[0-9]+%' "$ERRF" 2>/dev/null | tail -1 | cut -c1-160)"
        [ -n "$SYNTH_ERR" ] || SYNTH_ERR="exit $rc"
      fi
      rm -f "$ERRF"
      return 1
    fi
    rm -f "$ERRF"
    [ -s "$2" ] || { SYNTH_ERR="empty output"; return 1; }
  }

  # say 降级用哪个嗓音：auto = 文本带汉字（UTF-8 首字节 E4–E9）且本机装了 Tingting 就点名它，
  # 否则交给系统默认。系统默认嗓音多半是英文的，拿到中文会念成一串「FFFFFF」乱音（2026-10-14）。
  say_voice() { # $1=要念的文本 → 打印嗓音名，或空 = 系统默认
    case "$SAY_VOICE" in
      auto)
        if printf '%s' "$1" | LC_ALL=C grep -q "$(printf '[\xe4-\xe9]')" \
           && say -v '?' 2>/dev/null | grep -q '^Tingting '; then printf 'Tingting'; fi ;;
      *) printf '%s' "$SAY_VOICE" ;;
    esac
  }

  # 每次开播记一行 engine.log；超 2000 行砍到最近 1000 行
  elog() { # $1=engine $2=降级原因（空 = 没降级）
    printf '%s ch=%s engine=%s%s text=%s\n' "$(date '+%F %T')" "$SAFE_CH" "$1" "${2:+ reason=[$2]}" \
      "$(printf '%s' "$TEXT" | LC_ALL=en_US.UTF-8 cut -c1-80)" >> "$ELOG" 2>/dev/null
    if [ "$(wc -l < "$ELOG" 2>/dev/null | tr -d ' ')" -gt 2000 ] 2>/dev/null; then
      tail -1000 "$ELOG" > "$ELOG.tmp" 2>/dev/null && mv "$ELOG.tmp" "$ELOG"
    fi
  }

  # 报家门文本（「xx 这边：」）——句式可用 CC_TTS_LANE_TEMPLATE 覆盖
  PRE_TEXT=""
  # shellcheck disable=SC2059
  [ -n "$LANE" ] && PRE_TEXT="$(printf "$LANE_TMPL" "$LANE")"

  # 先合成（排在队里的时间跟合成重叠，等到轮到自己时已经烤好了）
  ENGINE=say
  REASON=""
  if synth "$TEXT" "$MP3"; then ENGINE=edge-tts; else REASON="$SYNTH_ERR"; fi

  # 车道报家门 mp3 按 内容×嗓音×语速 落盘缓存（key 含文本哈希，换句式/嗓音/语速自动重烤）
  # ⚠️ 语速必须进 key：不进的话调快语速后，缓存里那句「xx 这边：」还是旧速度，
  #    跟提速后的正文接在一起听着像卡带。
  PRE_MP3=""
  if [ -n "$PRE_TEXT" ] && [ "$ENGINE" = "edge-tts" ]; then
    SAFE_LANE="$(printf '%s' "$LANE" | tr -c 'a-zA-Z0-9_-' '_')"
    PRE_HASH="$(printf '%s|%s|%s' "$PRE_TEXT" "$VOICE" "$RATE" | cksum | cut -d' ' -f1)"
    PRE_MP3="$CACHE_DIR/lane-$SAFE_LANE-$PRE_HASH.mp3"
    if [ ! -s "$PRE_MP3" ]; then
      synth "$PRE_TEXT" "$PRE_MP3" || rm -f "$PRE_MP3"
    fi
  fi

  # 排队：只有队头能开口。等待期间随时可能被静音、或被你的回复判为过期 → 直接弃权。
  # 兜底 30min（纯防死锁，正常永远碰不到）
  n=0
  while :; do
    [ -f "$HOOK_DIR/tts-off" ] && give_up
    stale && give_up
    q_my_turn && break
    n=$((n+1))
    [ "$n" -gt 12000 ] && break
    sleep 0.15
  done

  # 应答闸：上一条播报还没被用户回车消化 → 憋住不播。
  # 同 channel 自己的后续播报不受闸（同一条 CLI 接着说，不用等确认，也防自锁死）。
  # tts-ack.sh（UserPromptSubmit）清闸放行；兜底超时后强制放行。
  # mcv 多 agent 模式不进这道闸——那边要的就是一条播完立刻接下一条。
  if [ "$MULTI" != "1" ]; then
    MAXG=$(( ${CC_TTS_ACK_TIMEOUT:-45} * 10 / 3 ))
    g=0
    while [ -f "$GATE" ] && [ "$(cat "$GATE" 2>/dev/null)" != "$CHANNEL" ]; do
      [ -f "$HOOK_DIR/tts-off" ] && break
      stale && give_up
      g=$((g+1))
      [ "$g" -gt "$MAXG" ] && break
      sleep 0.3
    done
  fi

  # Fn 闸：旗标在且 3 秒内有心跳 = 用户正摁着 Fn 说话，憋住；过期视为残留，照播。
  # 旗标路径按 hush.sh 同款兜底——fn-hush 跑在 launchd 下，TMPDIR 可能未设。
  FN_FLAG="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)}/cc-voice/fn-down"
  f=0
  while [ -f "$FN_FLAG" ]; do
    AGE=$(( $(date +%s) - $(stat -f %m "$FN_FLAG" 2>/dev/null || echo 0) ))
    [ "$AGE" -gt 3 ] && break
    [ -f "$HOOK_DIR/tts-off" ] && break
    stale && give_up
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

  # 排队期间可能被 mute 了、或被你的回复判为过期，播前再查一次
  if [ ! -f "$HOOK_DIR/tts-off" ] && ! stale; then
    # 开播即落闸/记账：播放中的回车也能清闸放行下一条（mcv 不落闸，免得憋住别的会话）
    [ "$MULTI" = "1" ] || printf '%s' "$CHANNEL" > "$GATE"
    printf '%s' "$CHANNEL" > "$CACHE_DIR/last-played"
    echo "$ENGINE" > "$CACHE_DIR/last-engine"
    elog "$ENGINE" "$REASON"
    if [ "$ENGINE" = "edge-tts" ]; then
      if [ "$SPEAK_PREFIX" -eq 1 ] && [ -s "$PRE_MP3" ]; then afplay "$PRE_MP3"; fi
      afplay "$MP3"
    else
      MSG="$TEXT"
      [ "$SPEAK_PREFIX" -eq 1 ] && MSG="${PRE_TEXT}${TEXT}"
      SV="$(say_voice "$MSG")"
      if [ -n "$SV" ]; then say -v "$SV" -r "$SAY_RATE" "$MSG"; else say -r "$SAY_RATE" "$MSG"; fi
    fi
    # mcv 没有回车当节拍器，两条之间留半口气，别糊成一句
    [ "$MULTI" = "1" ] && sleep 0.35
  fi
  rm -f "$MP3" "$MP3.err"
  q_leave
) </dev/null >/dev/null 2>&1 &
echo $! > "$PIDFILE"
exit 0
