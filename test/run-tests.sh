#!/bin/bash
# claude-voice-loop test suite — silent (no audio); safe to run anywhere.
#  1. bash -n syntax check on every script
#  2. tts-stop.sh --dry-run behavior (cv summary line / fallback truncation /
#     fcv full mode / mcv lane phrase) + 2.4 the mcv speak.sh arg contract
#  2.5 speak.sh Fn gate — hold/stale/release, stubbed engines, silent (macOS only)
#  2.6 speak.sh ack gate — cv holds + times out, mcv bypasses (macOS only)
#  3. install.sh + uninstall.sh end-to-end against a throwaway $HOME (macOS + jq only)
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
# speak.sh 见到 hooks/edge-tts-shim.py 会绕过 PATH 上的 edge-tts 桩、直接用真 python 联网合成；
# 桩测试一律关掉垫片，只有 2.11 专门测垫片路由时再打开。
export CC_TTS_EDGE_SHIM=/nonexistent

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { # name, grep-pattern, actual
  if printf '%s' "$3" | grep -q "$2"; then ok "$1"; else bad "$1 — got: [$3]"; fi
}

# say 桩（所有桩测试共用）：-v ? 报一个 Tingting（让 auto 能选到它）；-v X / -r N 剥掉只把正文
# 记进 spoken.log；原始参数另记 say-args.log（2.12 查嗓音参数用）。$2 = 开口前先睡几秒（可选）。
mk_say_stub() { # $1=dir  $2=sleep
  cat > "$1/bin/say" <<STUB
#!/bin/bash
printf '%s\\n' "\$*" >> "$1/say-args.log"
[ "\$1" = "-v" ] && [ "\$2" = "?" ] && { echo "Tingting            zh_CN    # 你好！我叫婷婷。"; exit 0; }
${2:+sleep $2}
[ "\$1" = "-v" ] && shift 2
[ "\$1" = "-r" ] && shift 2
echo "\$*" >> "$1/spoken.log"
STUB
  chmod +x "$1/bin/say"
}

# ── 1. syntax ────────────────────────────────────────────────────────────────
for f in hooks/*.sh install.sh uninstall.sh test/run-tests.sh; do
  if bash -n "$f" 2>/dev/null; then ok "syntax: $f"; else bad "syntax: $f"; fi
done

# ── 2. tts-stop.sh dry-run behavior ─────────────────────────────────────────
HOOK="$ROOT/hooks/tts-stop.sh"
FILLER="$(printf '这里是很长的正文填充句子用来撑过两百字限制。%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
LONG_BODY="修好了侧栏的问题。原因是滚动容器少了一个约束。${FILLER}最后一句是收尾结论。"

# cv mode: 🔊 line wins, body ignored
P1=$(jq -n --arg t $'正文分析 blah\n```\ncode here\n```\n🔊 修好了，刷新就能看到。' '{last_assistant_message:$t, session_id:"s1", cwd:"/x/feat+mobile"}')
O1=$(printf '%s' "$P1" | "$HOOK" --dry-run)
check "cv: extracts 🔊 line only" "^修好了，刷新就能看到。$" "$O1"

# cv mode, no 🔊 line: fallback truncates at a sentence boundary + suffix
P2=$(jq -n --arg t "$LONG_BODY" '{last_assistant_message:$t, session_id:"s1"}')
O2=$(printf '%s' "$P2" | "$HOOK" --dry-run)
check "cv fallback: truncation suffix present" "细节在屏幕上。$" "$O2"
if printf '%s' "$O2" | grep -q "最后一句是收尾结论"; then
  bad "cv fallback: should have truncated before the last sentence"
else
  ok "cv fallback: long tail truncated"
fi

# fcv mode: full text, no truncation, no suffix
O3=$(printf '%s' "$P2" | CC_VOICE_FULL=1 "$HOOK" --dry-run)
check "fcv: reads through to the last sentence" "最后一句是收尾结论。" "$O3"
if printf '%s' "$O3" | grep -q "细节在屏幕上"; then
  bad "fcv: must not append truncation suffix"
else
  ok "fcv: no truncation suffix"
fi

# fcv mode: code fences / inline code / tables all stripped
P4=$(jq -n --arg t $'结论在这。\n```\nrm -rf /secret\n```\n用 `npm run dev` 起。\n| 列A | 列B |\n|---|---|\n| 甲 | 乙 |\n完事。' '{last_assistant_message:$t, session_id:"s1"}')
O4=$(printf '%s' "$P4" | CC_VOICE_FULL=1 "$HOOK" --dry-run)
check "fcv: prose survives stripping" "结论在这。.*完事。" "$O4"
if printf '%s' "$O4" | grep -Eq "rm -rf|npm run"; then bad "fcv: code leaked into speech: [$O4]"; else ok "fcv: code blocks + inline code stripped"; fi
if printf '%s' "$O4" | grep -q "|"; then bad "fcv: table pipes leaked into speech"; else ok "fcv: table pipes stripped"; fi

# fcv mode: a stray 🔊 line loses its prefix but keeps its content
P5=$(jq -n --arg t $'正文在此。\n🔊 口语摘要一句。' '{last_assistant_message:$t, session_id:"s1"}')
O5=$(printf '%s' "$P5" | CC_VOICE_FULL=1 "$HOOK" --dry-run)
check "fcv: stray 🔊 keeps content, drops prefix" "正文在此。 口语摘要一句。" "$O5"

# mcv mode: fixed "<lane> done" phrase, body never spoken
P6=$(jq -n --arg t "$LONG_BODY" '{last_assistant_message:$t, session_id:"s1", cwd:"/w/feat+macos-1"}')
O6=$(printf '%s' "$P6" | CC_VOICE_MULTI=1 "$HOOK" --dry-run)
check "mcv: says lane + done only" "^macos-1 搞定了$" "$O6"

# mcv mode: a deliberate 🔊 line is the escape hatch — spoken as "<lane>：<note>"
O7=$(printf '%s' "$P1" | CC_VOICE_MULTI=1 "$HOOK" --dry-run)
check "mcv: 🔊 escape hatch keeps the note" "^mobile：修好了，刷新就能看到。$" "$O7"

# mcv mode: no cwd → no lane name, still a clean phrase (no leading blank)
O8=$(printf '%s' "$P2" | CC_VOICE_MULTI=1 "$HOOK" --dry-run)
check "mcv: laneless fallback stays clean" "^搞定了$" "$O8"

# mcv templates are overridable (English deployments)
O9=$(printf '%s' "$P6" | CC_VOICE_MULTI=1 CC_TTS_DONE_TEMPLATE="%s is done" "$HOOK" --dry-run)
check "mcv: CC_TTS_DONE_TEMPLATE honored" "^macos-1 is done$" "$O9"

# ── 2.4 mcv arg contract: tts-stop hands speak.sh an EMPTY --lane ───────────
# (the lane name is already inside the phrase — announcing it twice would say
#  "macos-1 这边：macos-1 搞定了")
T1="$(mktemp -d)"
mkdir -p "$T1/hooks"
cp "$ROOT"/hooks/*.sh "$T1/hooks/"
printf '#!/bin/bash\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done >> "%s/args.log"\n' "$T1" > "$T1/hooks/speak.sh"
chmod +x "$T1/hooks"/*.sh
printf '%s' "$P6" | CC_VOICE=1 CC_VOICE_MULTI=1 "$T1/hooks/tts-stop.sh"
A1="$(cat "$T1/args.log" 2>/dev/null || true)"
if printf '%s\n' "$A1" | grep -qx '\[\]' && printf '%s\n' "$A1" | grep -q '\[macos-1 搞定了\]'; then
  ok "mcv: speak.sh called with an empty --lane"
else
  bad "mcv: wrong speak.sh args — got: [$A1]"
fi
rm -f "$T1/args.log"
printf '%s' "$P6" | CC_VOICE=1 "$T1/hooks/tts-stop.sh"
A2="$(cat "$T1/args.log" 2>/dev/null || true)"
check "cv: speak.sh still gets the lane name for its announcement" '\[macos-1\]' "$A2"
rm -rf "$T1"

# ── 2.5 speak.sh Fn gate (macOS only: BSD stat; engines stubbed, no audio) ──
if [ "$(uname)" = "Darwin" ]; then
  T2="$(mktemp -d)"
  mkdir -p "$T2/bin" "$T2/tmp/cc-voice"
  printf '#!/bin/bash\nexit 1\n' > "$T2/bin/edge-tts"   # force the say fallback
  mk_say_stub "$T2"
  chmod +x "$T2/bin/edge-tts" "$T2/bin/say"
  FN="$T2/tmp/cc-voice/fn-down"

  # stale flag (no heartbeat for >3 s = listener died mid-hold) is ignored
  touch -t 202601010000 "$FN"
  env PATH="$T2/bin:$PATH" TMPDIR="$T2/tmp" "$ROOT/hooks/speak.sh" --channel t1 "stale flag test"
  g1=0
  for _ in $(seq 1 40); do [ -f "$T2/spoken.log" ] && { g1=1; break; }; sleep 0.25; done
  [ "$g1" = 1 ] && ok "fn gate: stale flag ignored, playback proceeds" || bad "fn gate: stale flag blocked playback"
  # t1's playback wrote the ack gate — clear it so test 2 exercises the FN gate, not the ack gate
  rm -f "$FN" "$T2/spoken.log" "$T2/tmp/cc-voice/await-ack"

  # fresh flag holds playback; removing it (= fn released) lets it play
  touch "$FN"
  env PATH="$T2/bin:$PATH" TMPDIR="$T2/tmp" "$ROOT/hooks/speak.sh" --channel t2 "fresh flag test"
  sleep 1.5
  [ ! -f "$T2/spoken.log" ] && ok "fn gate: fresh flag holds playback" || bad "fn gate: played while flag fresh"
  rm -f "$FN"
  g2=0
  for _ in $(seq 1 40); do [ -f "$T2/spoken.log" ] && { g2=1; break; }; sleep 0.25; done
  [ "$g2" = 1 ] && ok "fn gate: releasing the flag releases playback" || bad "fn gate: never played after release"
  rm -rf "$T2"
else
  echo "SKIP: speak.sh fn-gate (needs macOS)"
fi

# ── 2.6 speak.sh ack gate: cv waits for Enter, mcv walks straight through ───
if [ "$(uname)" = "Darwin" ]; then
  T3="$(mktemp -d)"
  mkdir -p "$T3/bin" "$T3/tmp/cc-voice"
  printf '#!/bin/bash\nexit 1\n' > "$T3/bin/edge-tts"   # force the say fallback
  mk_say_stub "$T3"
  chmod +x "$T3/bin/edge-tts" "$T3/bin/say"
  GATEF="$T3/tmp/cc-voice/await-ack"

  # cv mode: someone else's un-acked broadcast holds this one back, then the
  # timeout releases it (2 s here instead of the 45 s default)
  printf 'other-session' > "$GATEF"
  env PATH="$T3/bin:$PATH" TMPDIR="$T3/tmp" CC_TTS_ACK_TIMEOUT=2 \
    "$ROOT/hooks/speak.sh" --channel c1 "held by the ack gate"
  sleep 1.2
  [ ! -f "$T3/spoken.log" ] && ok "ack gate: cv mode holds until Enter/timeout" || bad "ack gate: cv played through the gate"
  a1=0
  for _ in $(seq 1 40); do [ -f "$T3/spoken.log" ] && { a1=1; break; }; sleep 0.25; done
  [ "$a1" = 1 ] && ok "ack gate: timeout releases the held broadcast" || bad "ack gate: never released after timeout"
  rm -f "$T3/spoken.log"

  # mcv mode: same standing gate, plays immediately and leaves the gate alone
  printf 'other-session' > "$GATEF"
  env PATH="$T3/bin:$PATH" TMPDIR="$T3/tmp" CC_VOICE_MULTI=1 \
    "$ROOT/hooks/speak.sh" --channel c2 --lane "" "macos-1 搞定了"
  a2=0
  for _ in $(seq 1 24); do [ -f "$T3/spoken.log" ] && { a2=1; break; }; sleep 0.25; done
  [ "$a2" = 1 ] && ok "mcv: ack gate bypassed, next lane plays right away" || bad "mcv: still blocked by the ack gate"
  check "mcv: spoke the phrase verbatim" "macos-1 搞定了" "$(cat "$T3/spoken.log" 2>/dev/null || true)"
  [ "$(cat "$GATEF" 2>/dev/null)" = "other-session" ] && ok "mcv: does not arm the ack gate for others" || bad "mcv: overwrote the ack gate"
  rm -rf "$T3"
else
  echo "SKIP: speak.sh ack-gate (needs macOS)"
fi

# ── 2.7 播报队列：号在「干完活」那刻拿，播出顺序不跟着合成快慢走 ────────────
# 三条 CLI 依次干完（lane1 → lane2 → lane3），但合成耗时故意反过来（lane1 最慢、
# lane3 最快）。老的「先合成再抢锁」会念成 lane3 lane2 lane1；拿号排队必须是 1 2 3。
if [ "$(uname)" = "Darwin" ]; then
  T4="$(mktemp -d)"
  mkdir -p "$T4/bin" "$T4/tmp/cc-voice"
  cat > "$T4/bin/edge-tts" <<'STUB'
#!/bin/bash
case "$*" in
  *lane1*) sleep 1.2 ;;
  *lane2*) sleep 0.6 ;;
  *)       sleep 0.05 ;;
esac
exit 1
STUB
  mk_say_stub "$T4" 0.2
  chmod +x "$T4/bin/edge-tts" "$T4/bin/say"
  for i in 1 2 3; do
    env PATH="$T4/bin:$PATH" TMPDIR="$T4/tmp" CC_VOICE_MULTI=1 \
      "$ROOT/hooks/speak.sh" --channel "q$i" --lane "" "lane$i"
    sleep 0.15
  done
  for _ in $(seq 1 60); do
    if [ -f "$T4/spoken.log" ] && [ "$(wc -l < "$T4/spoken.log")" -ge 3 ]; then break; fi
    sleep 0.25
  done
  ORD="$(tr '\n' ' ' < "$T4/spoken.log" 2>/dev/null || true)"
  check "queue: plays in finish order, not synthesis order" "^lane1 lane2 lane3 *$" "$ORD"
  rm -rf "$T4"
else
  echo "SKIP: speak.sh queue order (needs macOS)"
fi

# ── 2.8 过期作废：你已经回复过的那条 CLI，排队里的播报不再开口 ────────────────
if [ "$(uname)" = "Darwin" ] && command -v jq >/dev/null 2>&1; then
  T5="$(mktemp -d)"
  mkdir -p "$T5/bin" "$T5/tmp/cc-voice"
  printf '#!/bin/bash\nexit 1\n' > "$T5/bin/edge-tts"
  mk_say_stub "$T5" 0.6
  chmod +x "$T5/bin/edge-tts" "$T5/bin/say"
  for c in one two three; do
    env PATH="$T5/bin:$PATH" TMPDIR="$T5/tmp" CC_VOICE_MULTI=1 \
      "$ROOT/hooks/speak.sh" --channel "s-$c" --lane "" "$c"
    sleep 0.1
  done
  # 「one」正在播，「two」「three」排在队里 —— 此刻你在 two 那条 CLI 上敲了回车
  printf '{"session_id":"s-two"}' | env TMPDIR="$T5/tmp" "$ROOT/hooks/tts-ack.sh"
  for _ in $(seq 1 40); do
    printf '%s' "$(cat "$T5/spoken.log" 2>/dev/null || true)" | grep -q three && break
    sleep 0.25
  done
  SPOKE="$(tr '\n' ' ' < "$T5/spoken.log" 2>/dev/null || true)"
  check "stale drop: the un-replied lanes still speak" "^one three *$" "$SPOKE"
  if printf '%s' "$SPOKE" | grep -qw two; then
    bad "stale drop: replied-to lane spoke anyway — got: [$SPOKE]"
  else
    ok "stale drop: replied-to lane stays quiet"
  fi
  rm -rf "$T5"
else
  echo "SKIP: speak.sh stale-drop (needs macOS + jq)"
fi

# 注：say 桩统一先吃掉 `-r <wpm>`（speak.sh 的 CC_TTS_SAY_RATE 会带这两个参数），
# 只把真正被念的文本记进 spoken.log —— 断言比的是"念了什么"，不该被语速参数污染。
# ── 2.9 合成看门狗：edge-tts 挂死不能拖住整个队列，超时降级 say ───────────────
if [ "$(uname)" = "Darwin" ]; then
  T6="$(mktemp -d)"
  mkdir -p "$T6/bin" "$T6/tmp/cc-voice"
  printf '#!/bin/bash\nsleep 30\n' > "$T6/bin/edge-tts"
  mk_say_stub "$T6"
  chmod +x "$T6/bin/edge-tts" "$T6/bin/say"
  env PATH="$T6/bin:$PATH" TMPDIR="$T6/tmp" CC_VOICE_MULTI=1 CC_TTS_SYNTH_TIMEOUT=1 \
    "$ROOT/hooks/speak.sh" --channel w1 --lane "" "watchdog test"
  w=0
  for _ in $(seq 1 24); do [ -f "$T6/spoken.log" ] && { w=1; break; }; sleep 0.25; done
  [ "$w" = 1 ] && ok "synth watchdog: hung edge-tts times out into say" || bad "synth watchdog: never fell back"
  rm -rf "$T6"
else
  echo "SKIP: speak.sh synth watchdog (needs macOS)"
fi

# ── 2.10 节奏本体：一次回车放一条，不是一次回车放一串 ──────────────────────
if [ "$(uname)" = "Darwin" ] && command -v jq >/dev/null 2>&1; then
  T7="$(mktemp -d)"
  mkdir -p "$T7/bin" "$T7/tmp/cc-voice"
  printf '#!/bin/bash\nexit 1\n' > "$T7/bin/edge-tts"
  mk_say_stub "$T7" 0.4
  chmod +x "$T7/bin/edge-tts" "$T7/bin/say"
  spoke7() { tr '\n' ' ' < "$T7/spoken.log" 2>/dev/null || true; }
  ack7() { printf '{"session_id":"%s"}' "$1" | env TMPDIR="$T7/tmp" "$ROOT/hooks/tts-ack.sh"; }
  for c in one two three; do
    env PATH="$T7/bin:$PATH" TMPDIR="$T7/tmp" CC_TTS_ACK_TIMEOUT=30 \
      "$ROOT/hooks/speak.sh" --channel "s-$c" --lane "" "$c"
    sleep 0.1
  done
  sleep 1.2
  check "ack rhythm: first lane speaks, the rest wait" "^one *$" "$(spoke7)"
  ack7 s-one; sleep 1.2
  check "ack rhythm: one Enter releases exactly one" "^one two *$" "$(spoke7)"
  ack7 s-two; sleep 1.2
  check "ack rhythm: next Enter releases the next" "^one two three *$" "$(spoke7)"
  rm -rf "$T7"
else
  echo "SKIP: speak.sh ack rhythm (needs macOS + jq)"
fi

# ── 2.11 edge-tts 端点垫片：垫片在 → 用 edge-tts 的 shebang python 跑垫片、参数原样透传 ──
if [ "$(uname)" = "Darwin" ]; then
  T8="$(mktemp -d)"
  mkdir -p "$T8/bin" "$T8/tmp/cc-voice"
  # 假 python：-c 探测 edge_tts 一律说有；被当解释器跑垫片时记下参数、写出非空 mp3
  cat > "$T8/bin/fakepy" <<STUB
#!/bin/bash
[ "\$1" = "-c" ] && exit 0
printf '%s\n' "\$@" > "$T8/shim-args.log"
while [ \$# -gt 0 ]; do [ "\$1" = "--write-media" ] && printf 'ID3' > "\$2"; shift; done
STUB
  printf '#!%s\nexit 1\n' "$T8/bin/fakepy" > "$T8/bin/edge-tts"   # 正牌命令若被走到就失败
  mk_say_stub "$T8"
  printf '#!/bin/bash\necho afplay >> "%s/spoken.log"\n' "$T8" > "$T8/bin/afplay"
  printf '# shim\n' > "$T8/shim.py"
  chmod +x "$T8/bin/fakepy" "$T8/bin/edge-tts" "$T8/bin/say" "$T8/bin/afplay"
  env PATH="$T8/bin:$PATH" TMPDIR="$T8/tmp" CC_VOICE_MULTI=1 CC_TTS_EDGE_SHIM="$T8/shim.py" \
    "$ROOT/hooks/speak.sh" --channel sh1 --lane "" "shim route"
  for _ in $(seq 1 40); do [ -s "$T8/spoken.log" ] && break; sleep 0.1; done
  check "shim: shebang python runs the shim first" "^$T8/shim.py$" "$(head -1 "$T8/shim-args.log" 2>/dev/null)"
  check "shim: CLI args pass through" "^shim route$" "$(grep -A1 -- '--text' "$T8/shim-args.log" 2>/dev/null | tail -1)"
  check "shim: shim audio plays (no say fallback)" "^afplay$" "$(cat "$T8/spoken.log" 2>/dev/null)"
  check "engine.log: records edge-tts on success" "engine=edge-tts text=shim route" "$(cat "$T8/tmp/cc-voice/engine.log" 2>/dev/null)"
  rm -rf "$T8"
else
  echo "SKIP: speak.sh edge-tts shim (needs macOS)"
fi

# ── 2.12 say 降级：中文点名 Tingting、拉丁文用系统默认、CC_TTS_SAY_VOICE 可强制；engine.log 记降级原因 ──
# 2026-10-14：系统默认嗓音是英文的，拿到中文念成一串「FFFFFF」——这就是播报时不时冒乱音的真凶。
if [ "$(uname)" = "Darwin" ]; then
  T9="$(mktemp -d)"
  mkdir -p "$T9/bin" "$T9/tmp/cc-voice"
  printf '#!/bin/bash\necho "  5%%|##  | 1/20" >&2\necho "WSServerHandshakeError: 403 Invalid response status" >&2\nexit 1\n' > "$T9/bin/edge-tts"
  chmod +x "$T9/bin/edge-tts"
  mk_say_stub "$T9"
  env PATH="$T9/bin:$PATH" TMPDIR="$T9/tmp" CC_VOICE_MULTI=1 \
    "$ROOT/hooks/speak.sh" --channel sv1 --lane "" "中文降级测试"
  for _ in $(seq 1 40); do [ -s "$T9/spoken.log" ] && break; sleep 0.1; done
  check "say voice: Chinese text names Tingting" "^-v Tingting -r " "$(grep -- '-r ' "$T9/say-args.log" 2>/dev/null | tail -1)"
  check "say voice: spoken text intact" "^中文降级测试$" "$(cat "$T9/spoken.log" 2>/dev/null)"
  check "engine.log: records say + the real error line" "engine=say reason=\[WSServerHandshakeError: 403" "$(cat "$T9/tmp/cc-voice/engine.log" 2>/dev/null)"
  rm -f "$T9/spoken.log" "$T9/say-args.log"
  env PATH="$T9/bin:$PATH" TMPDIR="$T9/tmp" CC_VOICE_MULTI=1 \
    "$ROOT/hooks/speak.sh" --channel sv2 --lane "" "english only"
  for _ in $(seq 1 40); do [ -s "$T9/spoken.log" ] && break; sleep 0.1; done
  check "say voice: Latin text keeps the system voice" "^-r " "$(grep -- '-r ' "$T9/say-args.log" 2>/dev/null | tail -1)"
  rm -f "$T9/spoken.log" "$T9/say-args.log"
  env PATH="$T9/bin:$PATH" TMPDIR="$T9/tmp" CC_VOICE_MULTI=1 CC_TTS_SAY_VOICE=Meijia \
    "$ROOT/hooks/speak.sh" --channel sv3 --lane "" "点名嗓音"
  for _ in $(seq 1 40); do [ -s "$T9/spoken.log" ] && break; sleep 0.1; done
  check "say voice: CC_TTS_SAY_VOICE forces a voice" "^-v Meijia -r " "$(grep -- '-r ' "$T9/say-args.log" 2>/dev/null | tail -1)"
  rm -rf "$T9"
else
  echo "SKIP: say voice / engine.log (needs macOS)"
fi

# ── 3. install / uninstall e2e (throwaway HOME) ─────────────────────────────
if [ "$(uname)" = "Darwin" ] && command -v jq >/dev/null 2>&1; then
  T="$(mktemp -d)"
  hooks_count() { jq '[.hooks | to_entries[].value[].hooks[].command] | length' "$T/.claude/settings.json"; }

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "3" ] && ok "install: registers exactly 3 hooks" || bad "install: hook count = $(hooks_count)"
  [ -x "$T/.claude/hooks/speak.sh" ] && ok "install: scripts in place + executable" || bad "install: scripts missing"
  grep -q "alias fcv=" "$T/.zshrc" && ok "install: cv/fcv/mute aliases written" || bad "install: aliases missing"
  grep -q "alias mcv=" "$T/.zshrc" && ok "install: mcv alias written" || bad "install: mcv alias missing"
  [ -f "$T/.claude/hooks/voice-prompt-multi.txt" ] && ok "install: mcv prompt installed" || bad "install: voice-prompt-multi.txt missing"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "3" ] && ok "re-install: idempotent (still 3 hooks)" || bad "re-install: hook count grew to $(hooks_count)"
  [ "$(grep -c "alias cv=" "$T/.zshrc")" = "1" ] && ok "re-install: aliases not duplicated" || bad "re-install: duplicate aliases"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" --lang en >/dev/null 2>&1
  grep -q "Voice broadcast rules" "$T/.claude/hooks/voice-prompt.txt" && ok "install --lang en: english prompts land" || bad "install --lang en: prompt not english"
  grep -q "Multi-agent lane mode" "$T/.claude/hooks/voice-prompt-multi.txt" && ok "install --lang en: english mcv prompt lands" || bad "install --lang en: mcv prompt not english"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/uninstall.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "0" ] && ok "uninstall: hook registrations stripped" || bad "uninstall: hooks remain"
  [ ! -f "$T/.claude/hooks/speak.sh" ] && ok "uninstall: scripts removed" || bad "uninstall: scripts remain"
  [ ! -f "$T/.claude/hooks/voice-prompt-multi.txt" ] && ok "uninstall: mcv prompt removed" || bad "uninstall: voice-prompt-multi.txt remains"
  if grep -q "claude-voice-loop" "$T/.zshrc" 2>/dev/null; then bad "uninstall: alias block left behind"; else ok "uninstall: alias block removed"; fi
  rm -rf "$T"
else
  echo "SKIP: install/uninstall e2e (needs macOS + jq)"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
