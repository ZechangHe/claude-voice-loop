#!/bin/bash
# claude-voice-loop test suite — silent (no audio); safe to run anywhere.
#  1. bash -n syntax check on every script
#  2. tts-stop.sh --dry-run behavior (cv summary line / fallback truncation / fcv full mode)
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

# ── 3. install / uninstall e2e (throwaway HOME) ─────────────────────────────
if [ "$(uname)" = "Darwin" ] && command -v jq >/dev/null 2>&1; then
  T="$(mktemp -d)"
  hooks_count() { jq '[.hooks | to_entries[].value[].hooks[].command] | length' "$T/.claude/settings.json"; }

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "3" ] && ok "install: registers exactly 3 hooks" || bad "install: hook count = $(hooks_count)"
  [ -x "$T/.claude/hooks/speak.sh" ] && ok "install: scripts in place + executable" || bad "install: scripts missing"
  grep -q "alias fcv=" "$T/.zshrc" && ok "install: cv/fcv/mute aliases written" || bad "install: aliases missing"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "3" ] && ok "re-install: idempotent (still 3 hooks)" || bad "re-install: hook count grew to $(hooks_count)"
  [ "$(grep -c "alias cv=" "$T/.zshrc")" = "1" ] && ok "re-install: aliases not duplicated" || bad "re-install: duplicate aliases"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/install.sh" --lang en >/dev/null 2>&1
  grep -q "Voice broadcast rules" "$T/.claude/hooks/voice-prompt.txt" && ok "install --lang en: english prompts land" || bad "install --lang en: prompt not english"

  env HOME="$T" SHELL=/bin/zsh TMPDIR="$T/tmp" "$ROOT/uninstall.sh" >/dev/null 2>&1
  [ "$(hooks_count)" = "0" ] && ok "uninstall: hook registrations stripped" || bad "uninstall: hooks remain"
  [ ! -f "$T/.claude/hooks/speak.sh" ] && ok "uninstall: scripts removed" || bad "uninstall: scripts remain"
  if grep -q "claude-voice-loop" "$T/.zshrc" 2>/dev/null; then bad "uninstall: alias block left behind"; else ok "uninstall: alias block removed"; fi
  rm -rf "$T"
else
  echo "SKIP: install/uninstall e2e (needs macOS + jq)"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
