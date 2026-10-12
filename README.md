# claude-voice-loop

[![test](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml/badge.svg)](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml)

**Spoken output for [Claude Code](https://claude.com/claude-code) — every reply read aloud, multi-session aware, hands-free friendly.** [中文文档 →](README.zh-CN.md)

Claude Code ships voice *input* (`/voice`) but has no voice *output* — the feature request was closed as not-planned. This project closes the loop using nothing but Claude Code's own hook system, a few hundred lines of bash, and a free neural TTS voice. It has been the daily driver behind [BufferMind](https://buffermind.com)'s development for months.

## What you get

- **`cv`** — conversational mode. A system prompt teaches the model to end every reply with one plain-speech 🔊 summary line (no jargon, no file names — written for a smart listener who doesn't code). The Stop hook reads exactly that line aloud.
- **`fcv`** — full read-aloud mode. The entire reply is spoken; code blocks, inline code, tables, and markdown are stripped before they reach the voice.
- **`mcv`** — multi-agent lane mode, for babysitting several parallel Claude Code lanes. No summaries at all: each lane just says **"macos-1 is done"** (its worktree name) when a reply ends, and the ack gate is off — as soon as one lane finishes speaking the next one starts, no Enter required. A lane that needs you can still say so by ending its reply with a short 🔊 line.
- **Multi-session arbitration** — run several Claude Code sessions at once: broadcasts take a ticket **the moment their lane finishes**, so they play in finish order instead of overlapping or racing; a session announces itself ("mobile here:") when it isn't the one you were just typing in; an *ack gate* keeps broadcasts from machine-gunning back-to-back — one Enter releases exactly one, the next waits for the next Enter (up to 45 s); and a lane you have **already replied to** silently drops its still-queued broadcast (you read it on screen already — hearing it afterwards is just noise). In `mcv` the gate steps aside; the queue still orders playback.
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

you press Enter ── UserPromptSubmit ──▶ tts-ack.sh    releases the next one + cancels this lane's queued broadcast
Claude asks a question ── PreToolUse ──▶ tts-ask.sh   reads question + options
you press Fn ──▶ fn-hush (CGEventTap) ──▶ hush.sh     cuts off the current sentence
you hold Fn ──▶ heartbeat flag ──▶ speak.sh           holds new broadcasts until release
```

Design notes for the curious:

- **Ticket taken at finish time** — a broadcast takes its queue number *before* synthesis starts, so playback order follows which lane finished first, never which mp3 happened to render fastest (synthesis overlaps the wait, so the audio is ready by the time your turn comes). The old build had every broadcast `mkdir`-race for one lock — whoever's poll landed on the release won, which sounded random.
- **Only the head speaks** — the queue *is* the mutex; no separate audio lock. Waiters re-check the head every 0.15 s and prune dead tickets (interrupted or crashed lanes), so a corpse can never wedge the line.
- **Replying cancels** — pressing Enter in a lane drops an *expiry watermark* for it (`tts-ack.sh`); queued broadcasts with a ticket at or below the watermark bow out. The reply to that very prompt takes a higher ticket, so it is never affected.
- **Synthesis watchdog** — a stuck head would stall the whole line, so edge-tts is killed after 12 s (`CC_TTS_SYNTH_TIMEOUT`) and falls back to `say`.
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
| `CC_TTS_RATE` | `+25%` | edge-tts speaking rate (`+40%` faster, `+0%` original speed) |
| `CC_TTS_SAY_RATE` | `210` | Words per minute for the `say` fallback (system default is about 175) |
| `CC_VOICE_FULL` | unset | `1` = full read-aloud (this is all `fcv` adds) |
| `CC_VOICE_MULTI` | unset | `1` = multi-agent lane mode: fixed "<lane> is done" phrase, ack gate off (this is all `mcv` adds) |
| `CC_TTS_ACK_TIMEOUT` | `45` | Seconds a queued broadcast waits for your Enter before playing anyway |
| `CC_TTS_SYNTH_TIMEOUT` | `12` | Seconds before a hung edge-tts is killed and `say` takes over (keeps the queue head from stalling the line) |
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
