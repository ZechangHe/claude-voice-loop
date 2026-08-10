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

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
check() { # name, grep-pattern, actual
  if printf '%s' "$3" | grep -q "$2"; then ok "$1"; else bad "$1 — got: [$3]"; fi
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
  printf '#!/bin/bash\necho spoken >> "%s/spoken.log"\n' "$T2" > "$T2/bin/say"
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
  printf '#!/bin/bash\necho "$*" >> "%s/spoken.log"\n' "$T3" > "$T3/bin/say"
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
