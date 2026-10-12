#!/bin/bash
# claude-voice-loop installer — idempotent; safe to re-run (updates scripts in place).
#
#   ./install.sh [--lang zh|en] [--with-fn-hush]
#
#   --lang zh|en      Voice-prompt language + spoken glue phrases (default: zh).
#   --with-fn-hush    Compile & install the Fn-key hush listener (needs Xcode CLT)
#                     as a LaunchAgent. Optional; everything else works without it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
LANG_CHOICE="zh"
WITH_FN_HUSH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_CHOICE="${2:?--lang needs zh|en}"; shift 2 ;;
    --with-fn-hush) WITH_FN_HUSH=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)"; exit 1 ;;
  esac
done
case "$LANG_CHOICE" in zh|en) ;; *) echo "--lang must be zh or en"; exit 1 ;; esac

[ "$(uname)" = "Darwin" ] || { echo "❌ macOS only for now (playback uses afplay/say). Linux PRs welcome!"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required:  brew install jq"; exit 1; }
command -v claude >/dev/null 2>&1 || echo "⚠️  'claude' CLI not found on PATH — install Claude Code first; continuing anyway."
if ! command -v edge-tts >/dev/null 2>&1; then
  echo "⚠️  edge-tts not found — will fall back to the macOS 'say' voice (works, sounds robotic)."
  echo "    Recommended:  pipx install edge-tts   (or: pip3 install --user edge-tts)"
fi

# ── 1. Hook scripts ──────────────────────────────────────────────────────────
mkdir -p "$HOOKS_DIR"
install_file() { # $1=src  $2=dst  (backs up a differing existing dst once)
  if [ -f "$2" ] && ! cmp -s "$1" "$2"; then cp "$2" "$2.bak"; fi
  cp "$1" "$2"
}
for f in speak.sh tts-stop.sh tts-ask.sh tts-ack.sh mute.sh hush.sh edge-tts-shim.py; do
  install_file "$REPO_DIR/hooks/$f" "$HOOKS_DIR/$f"
  chmod +x "$HOOKS_DIR/$f"
done
if [ "$LANG_CHOICE" = "en" ]; then
  install_file "$REPO_DIR/hooks/voice-prompt.en.txt"       "$HOOKS_DIR/voice-prompt.txt"
  install_file "$REPO_DIR/hooks/voice-prompt-full.en.txt"  "$HOOKS_DIR/voice-prompt-full.txt"
  install_file "$REPO_DIR/hooks/voice-prompt-multi.en.txt" "$HOOKS_DIR/voice-prompt-multi.txt"
else
  install_file "$REPO_DIR/hooks/voice-prompt.txt"       "$HOOKS_DIR/voice-prompt.txt"
  install_file "$REPO_DIR/hooks/voice-prompt-full.txt"  "$HOOKS_DIR/voice-prompt-full.txt"
  install_file "$REPO_DIR/hooks/voice-prompt-multi.txt" "$HOOKS_DIR/voice-prompt-multi.txt"
fi
echo "✓ hook scripts installed to $HOOKS_DIR"

# ── 2. Register hooks in ~/.claude/settings.json (idempotent merge) ──────────
[ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
TMP="$(mktemp)"
jq --arg h "$HOOKS_DIR" '
  def ensure(event; m; cmd):
    .hooks[event] = ((.hooks[event] // []) as $l
      | if ($l | map(.hooks // [] | map(.command)) | flatten | index(cmd)) != null
        then $l
        else $l + [ (if m == "" then {hooks: [{type: "command", command: cmd}]}
                     else {matcher: m, hooks: [{type: "command", command: cmd}]} end) ]
        end);
  ensure("Stop"; ""; $h + "/tts-stop.sh")
  | ensure("UserPromptSubmit"; ""; $h + "/tts-ack.sh")
  | ensure("PreToolUse"; "AskUserQuestion"; $h + "/tts-ask.sh")
' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
echo "✓ hooks registered in $SETTINGS (Stop / UserPromptSubmit / PreToolUse[AskUserQuestion])"

# ── 3. Shell aliases: cv / fcv / mcv / mute ──────────────────────────────────
RC="$HOME/.zshrc"
case "${SHELL:-}" in */bash) RC="$HOME/.bashrc" ;; esac
if grep -q "alias cv=" "$RC" 2>/dev/null; then
  echo "→ 'cv' alias already exists in $RC — leaving your aliases untouched."
  if ! grep -q "alias mcv=" "$RC" 2>/dev/null; then
    cat <<'EOF'
  ℹ️  New in this version: 'mcv' (multi-agent lane mode). Add it to your rc file by hand:
      alias mcv='CC_VOICE=1 CC_VOICE_MULTI=1 claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt-multi.txt)"'
EOF
  fi
else
  if [ "$LANG_CHOICE" = "en" ]; then
    cat >> "$RC" <<'EOF'

# >>> claude-voice-loop >>>
alias cv='CC_VOICE=1 CC_VOICE_NAME=en-US-ChristopherNeural CC_TTS_ASK_PHRASE="Pick one: " CC_TTS_LANE_TEMPLATE="%s here: " claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt.txt)"'
alias fcv='CC_VOICE=1 CC_VOICE_FULL=1 CC_VOICE_NAME=en-US-ChristopherNeural CC_TTS_ASK_PHRASE="Pick one: " CC_TTS_LANE_TEMPLATE="%s here: " claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt-full.txt)"'
alias mcv='CC_VOICE=1 CC_VOICE_MULTI=1 CC_VOICE_NAME=en-US-ChristopherNeural CC_TTS_DONE_TEMPLATE="%s is done" CC_TTS_NOTE_TEMPLATE="%s: %s" CC_TTS_ASK_MULTI_TEMPLATE="%s needs you" claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt-multi.txt)"'
alias mute='~/.claude/hooks/mute.sh'
# <<< claude-voice-loop <<<
EOF
  else
    cat >> "$RC" <<'EOF'

# >>> claude-voice-loop >>>
alias cv='CC_VOICE=1 claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt.txt)"'
alias fcv='CC_VOICE=1 CC_VOICE_FULL=1 claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt-full.txt)"'
alias mcv='CC_VOICE=1 CC_VOICE_MULTI=1 claude --dangerously-skip-permissions --append-system-prompt "$(cat ~/.claude/hooks/voice-prompt-multi.txt)"'
alias mute='~/.claude/hooks/mute.sh'
# <<< claude-voice-loop <<<
EOF
  fi
  echo "✓ aliases cv / fcv / mcv / mute appended to $RC"
  echo "  ⚠️  they include --dangerously-skip-permissions for a hands-free flow;"
  echo "      remove that flag from the aliases if you prefer permission prompts (TTS works either way)."
fi

# ── 4. Optional: Fn-key hush listener (LaunchAgent) ──────────────────────────
if [ "$WITH_FN_HUSH" -eq 1 ]; then
  command -v swiftc >/dev/null 2>&1 || { echo "❌ swiftc required for fn-hush:  xcode-select --install"; exit 1; }
  mkdir -p "$HOOKS_DIR/bin" "$HOME/.claude/debug" "$HOME/Library/LaunchAgents"
  FN_REBUILD=0
  [ -f "$HOOKS_DIR/bin/fn-hush" ] && FN_REBUILD=1
  swiftc -O -o "$HOOKS_DIR/bin/fn-hush" "$REPO_DIR/fn-hush/fn-hush.swift"
  PLIST="$HOME/Library/LaunchAgents/com.zcclabs.fn-hush.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.zcclabs.fn-hush</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.claude/hooks/bin/fn-hush</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>15</integer>
  <key>StandardErrorPath</key>
  <string>$HOME/.claude/debug/fn-hush.log</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "✓ fn-hush installed + loaded (press Fn to cut the current sentence; hold Fn to hold new broadcasts until release)"
  if [ "$FN_REBUILD" -eq 1 ]; then
    echo "  ⚠️  fn-hush was RECOMPILED — macOS ties the Input Monitoring grant to the binary's"
    echo "      code signature, so the old grant is now silently void: the listener still starts"
    echo "      and logs normally but receives no key events. To re-grant:"
    echo "      System Settings → Privacy & Security → Input Monitoring → remove fn-hush with −"
    echo "      (toggling it off/on is NOT enough), then run"
    echo "        launchctl kickstart -k gui/$(id -u)/com.zcclabs.fn-hush"
    echo "      re-enable the fn-hush row it re-creates, and kickstart once more."
  else
    echo "  If macOS asks for Input Monitoring permission: grant it, then run"
    echo "  launchctl kickstart -k gui/$(id -u)/com.zcclabs.fn-hush"
  fi
fi

echo ""
echo "Done. Open a NEW terminal, then:"
echo "  cv    # spoken one-line summaries after each reply"
echo "  fcv   # full replies read aloud"
echo "  mcv   # multi-agent lanes: just '<lane> is done', no ack gate"
echo "  mute  # toggle silence"
