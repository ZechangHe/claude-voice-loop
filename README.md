# claude-voice-loop

[![test](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml/badge.svg)](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml)

**Spoken output for [Claude Code](https://claude.com/claude-code) — every reply read aloud, multi-session aware, hands-free friendly.** [中文文档 →](README.zh-CN.md)

Claude Code ships voice *input* (`/voice`) but has no voice *output* — the feature request was closed as not-planned. This project closes the loop using nothing but Claude Code's own hook system, a few hundred lines of bash, and a free neural TTS voice. It has been the daily driver behind [BufferMind](https://buffermind.com)'s development for months.

## What you get

- **`cv`** — conversational mode. A system prompt teaches the model to end every reply with one plain-speech 🔊 summary line (no jargon, no file names — written for a smart listener who doesn't code). The Stop hook reads exactly that line aloud.
- **`fcv`** — full read-aloud mode. The entire reply is spoken; code blocks, inline code, tables, and markdown are stripped before they reach the voice.
- **`mcv`** — multi-agent lane mode, for babysitting several parallel Claude Code lanes. No summaries at all: each lane just says **"macos-1 is done"** (its worktree name) when a reply ends, and the ack gate is off — as soon as one lane finishes speaking the next one starts, no Enter required. A lane that needs you can still say so by ending its reply with a short 🔊 line.
- **Multi-session arbitration** — run several Claude Code sessions at once: audio queues instead of overlapping, a session announces itself ("mobile here:") when it isn't the one you were just typing in, and an *ack gate* keeps broadcasts from machine-gunning back-to-back — the next session's broadcast waits for your Enter (up to 45 s). In `mcv` the gate steps aside; the queue still serializes playback.
- **Questions read aloud** — when Claude asks a multiple-choice question, the question and options are spoken too.
- **`mute`** — toggle silence (also cuts off anything currently playing). **Fn key** — optional global listener: press to cut off the current sentence without muting; keep it held (push-to-talk) and new broadcasts wait until you release.
- **edge-tts** neural voice (free, no API key) with automatic fallback to macOS `say`.

## True voice-conversation development

This repo is the *output* half. Pair it with **voice input** and you can genuinely develop by talking:

> hold a push-to-talk key → speak your instruction → it lands in the terminal as text → Claude works → the result is spoken back to you.

We recommend [**BufferMind**](https://buffermind.com) (macOS, built by us) for the input half: its Voice Typing dictates into any focused app — terminal included — via **Fn push-to-talk**, with strong Chinese + English recognition. As a bonus, the same Fn press automatically cuts off any in-flight broadcast, and while you keep Fn held the loop stays quiet — new broadcasts wait until you release (see `fn-hush`), so grabbing the mic never fights the speaker. Any dictation tool that types into the terminal works too.

## Install

```bash
git clone https://github.com/ZechangHe/claude-voice-loop.git
cd claude-voice-loop
./install.sh                 # Chinese prompts + voice (default)
./install.sh --lang en       # English prompts + voice
./install.sh --with-fn-hush  # also build the Fn-key hush listener (needs Xcode CLT)
```

Requirements: **macOS** (playback uses `afplay`/`say`), **jq**, Claude Code. Recommended: `pipx install edge-tts` for the neural voice. The installer is idempotent — re-run it any time to update; it backs up files it replaces and never duplicates hook registrations or aliases.

> ⚠️ **Recompiling fn-hush?** macOS ties the Input Monitoring grant to the binary's code signature, so after any rebuild the old grant silently stops delivering events — the listener still starts and logs normally, it just hears nothing. Fix: System Settings → Privacy & Security → Input Monitoring → remove `fn-hush` with **−** (toggling it off/on is not enough), run `launchctl kickstart -k gui/$UID/com.zcclabs.fn-hush`, re-enable the row it re-creates, then kickstart once more.

Then open a **new terminal**:

```bash
cv     # spoken one-line summaries
fcv    # full replies read aloud
mcv    # parallel lanes: "<lane> is done", no ack gate
mute   # toggle silence
```

> ⚠️ The generated aliases include `--dangerously-skip-permissions` for an uninterrupted hands-free flow. If you prefer Claude Code's permission prompts, delete that flag from the aliases — the voice hooks work either way.

## How it works

```
you speak (Fn push-to-talk dictation) ──────────▶ claude prompt

reply ends ── Stop hook ──▶ tts-stop.sh ──▶ 🔊 line (cv) / cleaned full reply (fcv)
                                            / "<lane> is done" (mcv)
                                              │
                                              ▼
                                       speak.sh ──▶ edge-tts mp3 ──▶ afplay
                                              (fallback: macOS say)

you press Enter ── UserPromptSubmit ──▶ tts-ack.sh    releases the ack gate
Claude asks a question ── PreToolUse ──▶ tts-ask.sh   reads question + options
you press Fn ──▶ fn-hush (CGEventTap) ──▶ hush.sh     cuts off the current sentence
you hold Fn ──▶ heartbeat flag ──▶ speak.sh           holds new broadcasts until release
```

Design notes for the curious:

- **Synthesis before the lock** — mp3 is generated *before* a session waits for the shared audio lock, so queue time is pure playback, never synthesis.
- **Identity decided at play time** — whether to announce "mobile here:" is checked the moment audio starts, not when the text was generated; a broadcast held back by the ack gate would otherwise announce stale context.
- **Same-session interruption** — a new reply kills its own previous playback (whole process group), so a fast follow-up never queues behind itself.
- **Sentence-boundary fallback** — in `cv` mode, replies without a 🔊 line get truncated at the last full sentence within 200 chars plus "details are on screen" — never mid-sentence.
- **Terse by construction, not by prompting** — `mcv`'s phrase is built by the hook from the lane name, so a chatty model can't make it long; the only text it controls is the optional one-line 🔊 escape hatch. Its broadcasts also never *arm* the ack gate, so an `mcv` lane can't hold up a `cv` session running alongside it.
- **One markdown choke point** — all four callers pass through the same stripper in `speak.sh`, so TTS never says "asterisk asterisk".
- **Heartbeat flag, not a mute** — while Fn is held, fn-hush refreshes a flag file every second and `speak.sh` waits before starting playback; a flag older than 3 s means the listener died mid-hold and is ignored — a crashed listener can never leave the loop permanently silent.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `CC_VOICE_NAME` | `zh-CN-YunjianNeural` | Any edge-tts voice (`edge-tts --list-voices`) |
| `CC_VOICE_FULL` | unset | `1` = full read-aloud (this is all `fcv` adds) |
| `CC_VOICE_MULTI` | unset | `1` = multi-agent lane mode: fixed "<lane> is done" phrase, ack gate off (this is all `mcv` adds) |
| `CC_TTS_ACK_TIMEOUT` | `45` | Seconds a queued broadcast waits for your Enter before playing anyway |
| `CC_TTS_ASK_PHRASE` | `要选一下：` | Spoken lead-in for multiple-choice questions |
| `CC_TTS_LANE_TEMPLATE` | `%s 这边：` | printf template for the session announcement (e.g. `"%s here: "`) |
| `CC_TTS_DONE_TEMPLATE` | `%s 搞定了` | mcv: what a finished lane says (e.g. `"%s is done"`) |
| `CC_TTS_NOTE_TEMPLATE` | `%s：%s` | mcv: lane + the 🔊 note, when a lane needs you (e.g. `"%s: %s"`) |
| `CC_TTS_ASK_MULTI_TEMPLATE` | `%s 要你确认` | mcv: spoken instead of reading a whole question aloud |

The broadcast style lives in `~/.claude/hooks/voice-prompt.txt` (cv), `voice-prompt-full.txt` (fcv), and `voice-prompt-multi.txt` (mcv) — plain text appended to the system prompt; edit to taste.

## Compatibility

Tested with Claude Code 2.x (July 2026) on macOS. Relies on the Stop hook payload carrying `last_assistant_message`. Linux would need a small playback shim (`afplay` → `mpv`/`paplay`) — PRs welcome.

## Uninstall

```bash
./uninstall.sh
```

Removes the hook scripts, settings registrations, the marker-delimited alias block, the fn-hush LaunchAgent, and the runtime cache. Anything it backed up as `*.bak` stays put.

## License

[MIT](LICENSE) © 2026 [ZCC Labs](https://zcclabs.com)
