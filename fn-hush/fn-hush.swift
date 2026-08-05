// fn-hush — 全局监听 Fn 键，管住 Voice Loop 的 TTS 播报。
//
// 原理与 BufferMind 的 fn 监听同款：fn 在 macOS 上不是普通键码，而是
// flagsChanged 事件里的 kCGEventFlagMaskSecondaryFn 标志位，所以装一个
// listen-only 的 CGEventTap 盯两个沿：
// - 按下沿：触发 ~/.claude/hooks/hush.sh 掐断正在播/排队的句子（不设静音，
//   下一轮播报照常）；同时落「Fn 闸」旗标 $TMPDIR/cc-voice/fn-down。
// - 松开沿：清掉 fn-down 旗标。
// 摁住期间每秒心跳 touch 一次旗标——speak.sh 开播前见到新鲜旗标就憋住不播，
// 松开才放行；本进程要是死了，旗标几秒内过期，speak.sh 自动忽略，不会哑掉。
//
// 权限：首次运行 macOS 会弹「输入监控」(Input Monitoring) 授权；拒绝则
// tap 创建失败、进程退出（LaunchAgent 会按 ThrottleInterval 重试，授权后自愈）。
//
// 编译：swiftc -O -o ~/.claude/hooks/bin/fn-hush ~/.claude/hooks/fn-hush.swift

import CoreGraphics
import Foundation

let fnFlag: UInt64 = 0x0080_0000 // kCGEventFlagMaskSecondaryFn
var prevFn = false
var gTap: CFMachPort?

let hushPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/hooks/hush.sh")

// NSTemporaryDirectory()：有 TMPDIR 用 TMPDIR，launchd 下没有则落到同一个
// per-user 临时目录（DARWIN_USER_TEMP_DIR）——和 speak.sh/hush.sh 看到的是一处
let flagDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("cc-voice")
let flagPath = (flagDir as NSString).appendingPathComponent("fn-down")
var heartbeat: DispatchSourceTimer?

func runHush() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [hushPath]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

func touchFlag() {
    try? FileManager.default.createDirectory(atPath: flagDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: flagPath, contents: Data())
}

func onFnDown() {
    runHush()
    guard heartbeat == nil else { return }
    touchFlag()
    let t = DispatchSource.makeTimerSource(queue: .global())
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler { touchFlag() }
    t.resume()
    heartbeat = t
}

func onFnUp() {
    heartbeat?.cancel()
    heartbeat = nil
    try? FileManager.default.removeItem(atPath: flagPath)
}

let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        // 系统在负载高时会临时禁用 tap——自愈重挂，别让监听器悄悄死掉。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = gTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            let fnDown = (event.flags.rawValue & fnFlag) != 0
            if fnDown && !prevFn { onFnDown() }
            if !fnDown && prevFn { onFnUp() }
            prevFn = fnDown
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    FileHandle.standardError.write(
        "fn-hush: 无法创建事件监听 — 请在 系统设置 > 隐私与安全性 > 输入监控 里授权 fn-hush，然后它会自动重启。\n"
            .data(using: .utf8)!)
    exit(1)
}

// 上次退出时可能留下没清的旗标（比如摁着 Fn 时崩了）——开机先擦干净
try? FileManager.default.removeItem(atPath: flagPath)

gTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, CFRunLoopMode.commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
FileHandle.standardError.write("fn-hush: listening for fn presses\n".data(using: .utf8)!)
CFRunLoopRun()
