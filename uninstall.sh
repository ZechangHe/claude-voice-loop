#!/bin/bash
# claude-voice-loop uninstaller — removes hooks, settings entries, aliases, fn-hush.
set -u

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

# 1. fn-hush LaunchAgent + binary
PLIST="$HOME/Library/LaunchAgents/com.zcclabs.fn-hush.plist"
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  echo "✓ fn-hush LaunchAgent removed"
fi
rm -f "$HOOKS_DIR/bin/fn-hush"

# 2. settings.json — strip our three hook commands (leaves everything else alone)
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp)"
  jq --arg h "$HOOKS_DIR" '
    def strip(event):
      .hooks[event] = ((.hooks[event] // [])
        | map(.hooks = ((.hooks // []) | map(select(
            (.command // "") as $c
            | ($c == $h + "/tts-stop.sh" or $c == $h + "/tts-ack.sh" or $c == $h + "/tts-ask.sh") | not))))
        | map(select((.hooks | length) > 0)));
    strip("Stop") | strip("UserPromptSubmit") | strip("PreToolUse")
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "✓ hook registrations removed from $SETTINGS"
fi

# 3. hook scripts + prompts + mute state
rm -f "$HOOKS_DIR/speak.sh" "$HOOKS_DIR/tts-stop.sh" "$HOOKS_DIR/tts-ask.sh" \
      "$HOOKS_DIR/tts-ack.sh" "$HOOKS_DIR/mute.sh" "$HOOKS_DIR/hush.sh" \
      "$HOOKS_DIR/voice-prompt.txt" "$HOOKS_DIR/voice-prompt-full.txt" "$HOOKS_DIR/tts-off"
echo "✓ hook scripts removed (any *.bak backups were left in place)"

# 4. alias block (only if it carries our markers; hand-written aliases are left alone)
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$RC" ] && grep -q "# >>> claude-voice-loop >>>" "$RC"; then
    sed -i '' '/# >>> claude-voice-loop >>>/,/# <<< claude-voice-loop <<</d' "$RC"
    echo "✓ alias block removed from $RC"
  fi
done

# 5. runtime cache
rm -rf "${TMPDIR:-/tmp}/cc-voice"

echo "Done. Open a new terminal to drop the aliases from your current shell."
