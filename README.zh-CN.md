# claude-voice-loop

[![test](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml/badge.svg)](https://github.com/ZechangHe/claude-voice-loop/actions/workflows/test.yml)

**给 [Claude Code](https://claude.com/claude-code) 装上「嘴」——每条回复自动朗读，多会话不串音，解放双眼。** [English docs →](README.md)

Claude Code 官方有语音*输入*（`/voice`，且不支持中文），但语音*输出*的 feature request 被官方关闭为 not-planned。这个项目只用 Claude Code 自带的 hook 机制 + 几百行 bash + 免费神经网络 TTS，把这个环补上了。它是 [BufferMind](https://buffermind.com) 日常开发用了几个月的生产力工具，不是玩具 demo。

## 你会得到什么

- **`cv`** —— 对话模式。系统提示词教会模型在每条回复末尾附一行 🔊 口语播报（说人话：不带文件名、命令、术语，讲给「不懂编程的聪明人」听），Stop hook 只念这一行。
- **`fcv`** —— 全文朗读模式。整篇回复念出来；代码块、行内代码、表格、markdown 符号在进声道前全部剥掉。
- **`mcv`** —— 多 agent 车道模式，专门用来盯并行跑的好几条 CLI。不念摘要了：每条回复结束只报一句**「macos-1 搞定了」**（车道名 = worktree 目录名），并且应答闸关掉——上一条播完下一条立刻接上，不用你去哪个 CLI 敲回车。车道真卡住时，模型可以在回复末尾留一行短 🔊 说明，那时才会念内容。
- **多会话仲裁** —— 同时开几个 Claude Code 会话也不乱：播报按**干完活的先后拿号排队**（先干完的先播），不叠音不抢拍；不是你刚才打字的那个会话开口时，会先报家门（「mobile 这边：」）；「应答闸」防止播报连珠炮——一次回车放一条，下一条要等你任意会话再敲一次回车（最多等 45 秒）才开播；而你**已经回复过**的那条 CLI，它排在队里还没开口的播报会自动作废（你早在屏幕上读完了，再念就成了「你回复完它才开始播」）。`mcv` 模式下应答闸让开，排队照旧。
- **选择题也念** —— Claude 出选择题时，题目和选项一并念出来。
- **`mute`** —— 静音开关（顺手掐断正在播的）。**Fn 键** —— 可选的全局监听器：按一下掐断当前这句（不进入静音）；按住不放（按住说话）期间新播报憋住不响，松开才放行。
- **edge-tts** 免费神经网络嗓音（无需 API key），失败自动降级 macOS `say`。
  - **端点垫片（2026-10-12）** —— 微软把朗读服务搬到了 `api.msedgeservices.com`，旧地址现在一律 403，而 PyPI 上的 edge-tts（7.2.8）还指着旧地址（[rany2/edge-tts#490](https://github.com/rany2/edge-tts/issues/490)）。`hooks/edge-tts-shim.py` 让正牌 edge-tts 命令改连新地址（旧地址留作 403 时的退路）。等 `pip install -U edge-tts` 之后裸跑 `edge-tts --text hi --write-media x.mp3` 又能出声了，删掉 `~/.claude/hooks/edge-tts-shim.py`，speak.sh 自动回到正牌命令。

## 真·语音对话开发

本仓库是「输出」这半环。配上**语音输入**，就能真正用嘴开发：

> 按住说话键 → 说出指令 → 文字直接进终端 → Claude 干活 → 结果念回你耳朵里。

输入侧推荐 [**BufferMind**](https://buffermind.com)（macOS，我们自己做的）：它的 Voice Typing 用 **Fn 按住说话**，把听写文本注入任意前台 App（终端当然算），中英文识别都很强。彩蛋：同一个 Fn 按下去自动掐断正在播的播报，按住说话期间新播报也会憋住、松开才响（见 `fn-hush`）——抢麦永远不用跟扬声器打架。任何能往终端打字的听写工具也都兼容。

## 安装

```bash
git clone https://github.com/ZechangHe/claude-voice-loop.git
cd claude-voice-loop
./install.sh                 # 中文播报 + 中文嗓音（默认）
./install.sh --lang en       # 英文播报 + 英文嗓音
./install.sh --with-fn-hush  # 顺带编译 Fn 掐断监听器（需要 Xcode CLT）
```

依赖：**macOS**（播放走 `afplay`/`say`）、**jq**、Claude Code。推荐 `pipx install edge-tts` 获得神经网络嗓音。安装脚本幂等——随时重跑即更新；替换文件前会留 `.bak` 备份，hook 注册和别名绝不重复追加。

> ⚠️ **重编译过 fn-hush？** macOS 的「输入监控」授权认二进制签名，重编译后旧授权会静默失效——监听器照常启动、日志照常打印，就是收不到任何按键。修法：系统设置 → 隐私与安全性 → 输入监控 → 用 **−** 把 fn-hush 整条删掉（只拨开关没用），跑 `launchctl kickstart -k gui/$UID/com.zcclabs.fn-hush`，等它重新出现在列表里勾上，最后再 kickstart 一次。

然后**开个新终端**：

```bash
cv     # 每条回复念一句口语摘要
fcv    # 整篇回复全文朗读
mcv    # 多车道并行：只报「<车道名> 搞定了」，不等回车
mute   # 静音开关
```

> ⚠️ 生成的别名带 `--dangerously-skip-permissions`，为的是免打扰的纯语音心流。想保留 Claude Code 的权限确认，把别名里这个 flag 删掉即可——语音 hook 两种模式下都照常工作。

## 工作原理

```
你说话（Fn 按住说话听写）──────────────▶ claude 输入框

回复结束 ── Stop hook ──▶ tts-stop.sh ──▶ 🔊 行（cv）/ 洗净的全文（fcv）
                                          / 「<车道名> 搞定了」（mcv）
                                            │
                                            ▼
                                      speak.sh ──▶ edge-tts mp3 ──▶ afplay
                                            （降级：macOS say）

你敲回车 ── UserPromptSubmit ──▶ tts-ack.sh   放行下一条 + 作废这条 CLI 排队中的播报
Claude 出选择题 ── PreToolUse ──▶ tts-ask.sh  念题目 + 选项
你按 Fn ──▶ fn-hush（CGEventTap）──▶ hush.sh  掐断当前这句
你按住 Fn ──▶ 心跳旗标 ──▶ speak.sh           憋住新播报，松开放行
```

给好奇的人看的设计细节：

- **号在「干完活」那刻拿** —— 进队列先拿号再合成，所以播出顺序只认「谁先干完」，跟 edge-tts 快慢无关（合成与排队等待是重叠的，轮到自己时早已烤好）。老版本是几条播报各自 `mkdir` 抢锁，谁的轮询恰好撞上释放那一刻谁先播 = 听起来是随机序。
- **只有队头能开口** —— 队列本身就是互斥，不再需要另一把音频锁；排队者每 0.15 秒复查队头，并顺手剔除已死的号（被打断/崩掉的），队列不会被尸体堵死。
- **回复即作废** —— 你在某条 CLI 敲回车时，`tts-ack.sh` 给它落一个「过期水位号」；号 ≤ 水位的排队播报自己弃权退场，这次回复的答复是回车之后才拿的号，不受影响。
- **合成看门狗** —— 队头卡在合成上会拖住整队，所以 edge-tts 超过 12 秒（`CC_TTS_SYNTH_TIMEOUT`）就掐掉降级 `say`。
- **报家门开播那刻才定** —— 要不要念「mobile 这边：」是在音频真正响起的瞬间判断的，不是生成播报时——被应答闸憋住的播报如果提前定，念出来就是过期信息（串台）。
- **同会话自我打断** —— 新回复直接杀掉自己上一句的播放（整个进程组），快问快答不会排在自己后面。
- **句边界收尾** —— `cv` 模式下没有 🔊 行的回复，在 200 字内退到最后一个完整句 + 补「细节在屏幕上」——绝不念半截话。
- **简短是结构决定的，不是求出来的** —— `mcv` 那句话是 hook 拿车道名拼的，模型话再多也拉不长；它唯一能左右的只有那行可选的 🔊 逃生口。而且 `mcv` 的播报**不落**应答闸，所以它不会把旁边正常跑的 `cv` 会话憋住。
- **markdown 唯一咽喉** —— 四个调用方全走 `speak.sh` 同一个洗稿口，TTS 永远不会念出「星号星号」。
- **心跳旗标而非静音锁** —— 按住 Fn 期间 fn-hush 每秒刷新一次旗标文件，`speak.sh` 开播前见旗标就等；旗标超过 3 秒没心跳 = 监听器按着按着崩了，按残留忽略照播——监听器怎么死都不会把播报永久憋哑。

## 配置

| 环境变量 | 默认值 | 含义 |
|---|---|---|
| `CC_VOICE_NAME` | `zh-CN-YunjianNeural` | 任意 edge-tts 嗓音（`edge-tts --list-voices`） |
| `CC_TTS_RATE` | `+25%` | edge-tts 语速（要更快 `+40%`，回原速 `+0%`） |
| `CC_TTS_SAY_RATE` | `210` | 降级到 `say` 时的语速（词/分钟，系统默认约 175） |
| `CC_VOICE_FULL` | 未设 | `1` = 全文朗读（`fcv` 的全部秘密就是它） |
| `CC_VOICE_MULTI` | 未设 | `1` = 多 agent 车道模式：固定念「车道名 + 搞定了」，应答闸关掉（`mcv` 的全部秘密） |
| `CC_TTS_ACK_TIMEOUT` | `45` | 排队播报等回车的秒数，超时强制放行 |
| `CC_TTS_SYNTH_TIMEOUT` | `12` | edge-tts 合成挂死多少秒后掐掉降级 `say`（防队头拖住整队） |
| `CC_TTS_EDGE_SHIM` | `~/.claude/hooks/edge-tts-shim.py` | 端点垫片：文件在就经它合成（见上方 edge-tts 那条）；指到不存在的路径 = 直接用正牌 `edge-tts` 命令 |
| `CC_TTS_ASK_PHRASE` | `要选一下：` | 选择题的开场白 |
| `CC_TTS_LANE_TEMPLATE` | `%s 这边：` | 报家门句式（printf 模板，英文如 `"%s here: "`） |
| `CC_TTS_DONE_TEMPLATE` | `%s 搞定了` | mcv：车道干完活念的那句 |
| `CC_TTS_NOTE_TEMPLATE` | `%s：%s` | mcv：车道要你介入时，车道名 + 那行 🔊 短句 |
| `CC_TTS_ASK_MULTI_TEMPLATE` | `%s 要你确认` | mcv：出选择题时不念题面，只报这句 |

播报文风在 `~/.claude/hooks/voice-prompt.txt`（cv）、`voice-prompt-full.txt`（fcv）、`voice-prompt-multi.txt`（mcv）里——纯文本追加进系统提示词，想改口味直接编辑。

## 兼容性

在 macOS + Claude Code 2.x（2026-07）上验证。依赖 Stop hook payload 携带 `last_assistant_message` 字段。Linux 只差一个播放层替换（`afplay` → `mpv`/`paplay`）——欢迎 PR。

## 卸载

```bash
./uninstall.sh
```

移除 hook 脚本、settings 注册、带标记的别名块、fn-hush LaunchAgent 和运行时缓存；所有 `.bak` 备份原地保留。

## License

[MIT](LICENSE) © 2026 [ZCC Labs](https://zcclabs.com)
