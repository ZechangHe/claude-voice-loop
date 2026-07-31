# claude-voice-loop

[![test](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml/badge.svg)](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml)

**给 [Claude Code](https://claude.com/claude-code) 装上「嘴」——每条回复自动朗读，多会话不串音，解放双眼。** [English docs →](README.md)

Claude Code 官方有语音*输入*（`/voice`，且不支持中文），但语音*输出*的 feature request 被官方关闭为 not-planned。这个项目只用 Claude Code 自带的 hook 机制 + 几百行 bash + 免费神经网络 TTS，把这个环补上了。它是 [BufferMind](https://buffermind.com) 日常开发用了几个月的生产力工具，不是玩具 demo。

## 你会得到什么

- **`cv`** —— 对话模式。系统提示词教会模型在每条回复末尾附一行 🔊 口语播报（说人话：不带文件名、命令、术语，讲给「不懂编程的聪明人」听），Stop hook 只念这一行。
- **`fcv`** —— 全文朗读模式。整篇回复念出来；代码块、行内代码、表格、markdown 符号在进声道前全部剥掉。
- **多会话仲裁** —— 同时开几个 Claude Code 会话也不乱：音频排队不叠音；不是你刚才打字的那个会话开口时，会先报家门（「mobile 这边：」）；「应答闸」防止播报连珠炮——下一个会话的播报要等你任意会话敲一次回车（最多等 45 秒）才开播。
- **选择题也念** —— Claude 出选择题时，题目和选项一并念出来。
- **`mute`** —— 静音开关（顺手掐断正在播的）。**Fn 键** —— 可选的全局监听器，按一下掐断当前这句，不进入静音。
- **edge-tts** 免费神经网络嗓音（无需 API key），失败自动降级 macOS `say`。

## 真·语音对话开发

本仓库是「输出」这半环。配上**语音输入**，就能真正用嘴开发：

> 按住说话键 → 说出指令 → 文字直接进终端 → Claude 干活 → 结果念回你耳朵里。

输入侧推荐 [**BufferMind**](https://buffermind.com)（macOS，我们自己做的）：它的 Voice Typing 用 **Fn 按住说话**，把听写文本注入任意前台 App（终端当然算），中英文识别都很强。彩蛋：同一个 Fn 按下去还会自动掐断正在播的播报（见 `fn-hush`）——抢麦永远不用跟扬声器打架。任何能往终端打字的听写工具也都兼容。

## 安装

```bash
git clone https://github.com/ZechangHe/claude-voice-loop.git
cd claude-voice-loop
./install.sh                 # 中文播报 + 中文嗓音（默认）
./install.sh --lang en       # 英文播报 + 英文嗓音
./install.sh --with-fn-hush  # 顺带编译 Fn 掐断监听器（需要 Xcode CLT）
```

依赖：**macOS**（播放走 `afplay`/`say`）、**jq**、Claude Code。推荐 `pipx install edge-tts` 获得神经网络嗓音。安装脚本幂等——随时重跑即更新；替换文件前会留 `.bak` 备份，hook 注册和别名绝不重复追加。

然后**开个新终端**：

```bash
cv     # 每条回复念一句口语摘要
fcv    # 整篇回复全文朗读
mute   # 静音开关
```

> ⚠️ 生成的别名带 `--dangerously-skip-permissions`，为的是免打扰的纯语音心流。想保留 Claude Code 的权限确认，把别名里这个 flag 删掉即可——语音 hook 两种模式下都照常工作。

## 工作原理

```
你说话（Fn 按住说话听写）──────────────▶ claude 输入框

回复结束 ── Stop hook ──▶ tts-stop.sh ──▶ 🔊 行（cv）/ 洗净的全文（fcv）
                                            │
                                            ▼
                                      speak.sh ──▶ edge-tts mp3 ──▶ afplay
                                            （降级：macOS say）

你敲回车 ── UserPromptSubmit ──▶ tts-ack.sh   清应答闸放行下一条
Claude 出选择题 ── PreToolUse ──▶ tts-ask.sh  念题目 + 选项
你按 Fn ──▶ fn-hush（CGEventTap）──▶ hush.sh  掐断当前这句
```

给好奇的人看的设计细节：

- **先合成再抢锁** —— mp3 在等音频锁*之前*就合成好，排队时间纯花在播放上，永远不花在合成上。
- **报家门开播那刻才定** —— 要不要念「mobile 这边：」是在音频真正响起的瞬间判断的，不是生成播报时——被应答闸憋住的播报如果提前定，念出来就是过期信息（串台）。
- **同会话自我打断** —— 新回复直接杀掉自己上一句的播放（整个进程组），快问快答不会排在自己后面。
- **句边界收尾** —— `cv` 模式下没有 🔊 行的回复，在 200 字内退到最后一个完整句 + 补「细节在屏幕上」——绝不念半截话。
- **markdown 唯一咽喉** —— 四个调用方全走 `speak.sh` 同一个洗稿口，TTS 永远不会念出「星号星号」。

## 配置

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `CC_VOICE_NAME` | `zh-CN-YunjianNeural` | 任意 edge-tts 嗓音（`edge-tts --list-voices`） |
| `CC_VOICE_FULL` | 未设 | `1` = 全文朗读（`fcv` 的全部秘密就是它） |
| `CC_TTS_ACK_TIMEOUT` | `45` | 排队播报等回车的秒数，超时强制放行 |
| `CC_TTS_ASK_PHRASE` | `要选一下：` | 选择题的开场白 |
| `CC_TTS_LANE_TEMPLATE` | `%s 这边：` | 报家门句式（printf 模板，英文如 `"%s here: "`） |

播报文风在 `~/.claude/hooks/voice-prompt.txt`（cv）和 `voice-prompt-full.txt`（fcv）里——纯文本追加进系统提示词，想改口味直接编辑。

## 兼容性

在 macOS + Claude Code 2.x（2026-07）上验证。依赖 Stop hook payload 携带 `last_assistant_message` 字段。Linux 只差一个播放层替换（`afplay` → `mpv`/`paplay`）——欢迎 PR。

## 卸载

```bash
./uninstall.sh
```

移除 hook 脚本、settings 注册、带标记的别名块、fn-hush LaunchAgent 和运行时缓存；所有 `.bak` 备份原地保留。

## License

[MIT](LICENSE) © 2026 [ZCC Labs](https://zcclabs.com)
