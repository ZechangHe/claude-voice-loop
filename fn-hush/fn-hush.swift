// fn-hush — 全局监听 Fn 键按下沿，掐断 Voice Loop 正在播放的 TTS 播报。
//
// 原理与 BufferMind 的 fn 监听同款：fn 在 macOS 上不是普通键码，而是
// flagsChanged 事件里的 kCGEventFlagMaskSecondaryFn 标志位，所以装一个
// listen-only 的 CGEventTap 盯上升沿（按下），触发 ~/.claude/hooks/hush.sh。
// 只掐当前正在播/排队的句子，不设静音——下一轮播报照常。
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

func runHush() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [hushPath]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
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
            if fnDown && !prevFn { runHush() }
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

gTap = tap
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, CFRunLoopMode.commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
FileHandle.standardError.write("fn-hush: listening for fn presses\n".data(using: .utf8)!)
CFRunLoopRun()
