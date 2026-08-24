//
//  MouseWheelReverser（滚轮反转）
//  只反转鼠标滚轮方向，触摸板不受影响的 macOS 守护进程。
//
//  工作原理：
//  1. CGEventTap 挂在 HID 层（cghidEventTap）拦截全局滚轮事件。
//     ⚠️ macOS 26 (Tahoe) 起，系统的平滑滚动引擎在会话层之前就完成了滚动方向计算，
//     会话层（cgSessionEventTap）上修改增量不会再有任何可见效果，必须挂在 HID 层。
//  2. 离散事件（IsContinuous = 0，传统滚轮）→ 反转 DeltaAxis1（与 UnnaturalScrollWheels
//     1.3.0 在 macOS 26 上验证有效的方式一致，只改行增量，其余字段由系统自行推导）。
//  3. 连续事件（IsContinuous = 1）通过 IOHID 硬件层监测“物理滚轮是否刚动过”来区分：
//     物理滚轮近期有动作 → 平滑滚轮/系统惯性，反转；否则视为触摸板手势，放行。
//  4. 自愈：事件监听被系统静默失效时（无任何通知），依据 HID 旁证自动重建。
//
//  权限：需要“辅助功能”授权（系统设置 → 隐私与安全性 → 辅助功能）。
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

var eventTap: CFMachPort?
var runLoopSource: CFRunLoopSource?

/// 反转模式。
/// - deltaOnly：只反转 DeltaAxis1/2（与 UnnaturalScrollWheels 1.3.0 在 macOS 26 上验证有效的方式一致）
/// - allFields：反转全部增量字段（行/像素/定点）
/// - repost：吞掉原事件并以反转后的合成事件重新注入（对抗系统忽略字段修改的终极手段）
enum InvertMode {
    case deltaOnly
    case allFields
    case repost
}

var invertMode: InvertMode = .deltaOnly

/// 是否同时反转水平方向（滚轮左右倾斜）。
var invertHorizontal = false

/// 调试模式：把每个滚轮事件的关键字段写入日志，用于排查问题。
var debug = false

// ---- HID 物理滚轮监测 ----

/// HID 管理器，保持强引用防止被释放。
var hidManager: IOHIDManager?

/// 物理滚轮最后一次动作的时间。
var lastMouseWheelAt: CFAbsoluteTime = 0

/// 物理滚轮动作后的生效时间窗口（秒），覆盖系统为鼠标合成的惯性滚动尾巴。
let mouseWheelWindow: CFAbsoluteTime = 0.6

// ---- 自愈状态 ----

/// 最近一次收到滚轮 CG 事件的时间。
var lastWheelCGEventAt = CFAbsoluteTimeGetCurrent()

/// 最近一次收到非零滚轮 HID 报告的时间，以及当前滚动突发开始的时间。
var lastRealWheelReportAt: CFAbsoluteTime = 0
var wheelBurstStartAt: CFAbsoluteTime = 0

/// 最近一次尝试重建事件监听的时间。
var lastRebuildAttemptAt: CFAbsoluteTime = 0

/// 事件流当前是否处于中断状态（用于恢复时打日志）。
var tapInterrupted = false

/// 连续重建失败次数（权限被收回等情况），过多则退出交给 launchd 重启。
var rebuildFailures = 0

let startTime = CFAbsoluteTimeGetCurrent()

func logDebug(_ message: String) {
    guard debug else { return }
    let elapsed = String(format: "%8.3f", CFAbsoluteTimeGetCurrent() - startTime)
    fputs("[\(elapsed)] \(message)\n", stderr)
    fflush(stderr)
}

/// 调试输出滚轮事件的关键字段。
/// rawValue 99 / 123 是手势滚动的相位字段（ScrollPhase / MomentumPhase）。
func logScrollEvent(_ event: CGEvent, action: String) {
    guard debug else { return }
    let cont = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let pd1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let phase = event.getIntegerValueField(CGEventField(rawValue: 99) ?? .scrollWheelEventDeltaAxis1)
    let momentum = event.getIntegerValueField(CGEventField(rawValue: 123) ?? .scrollWheelEventDeltaAxis1)
    logDebug("滚轮事件 cont=\(cont) d1=\(d1) pd1=\(pd1) phase=\(phase) mom=\(momentum) → \(action)")
}

/// 按当前模式反转滚轮事件。
func invertScrollEvent(_ event: CGEvent) {
    switch invertMode {
    case .deltaOnly:
        // 只反转“行”增量，与被验证有效的 UnnaturalScrollWheels 1.3.0 一致
        event.setIntegerValueField(
            .scrollWheelEventDeltaAxis1,
            value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        if invertHorizontal {
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis2,
                value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
    case .allFields:
        let fields: [CGEventField] = [
            .scrollWheelEventDeltaAxis1,
            .scrollWheelEventPointDeltaAxis1,
            .scrollWheelEventFixedPtDeltaAxis1,
        ]
        for field in fields {
            let value = event.getIntegerValueField(field)
            if value != 0 {
                event.setIntegerValueField(field, value: -value)
            }
        }
    case .repost:
        // 由调用方处理（需要返回 NULL 并重新注入事件）
        break
    }
}

/// 创建（或重建）事件监听。成功返回 true。
/// 注意必须挂在 HID 层（cghidEventTap）：macOS 26 的平滑滚动引擎在会话层
/// 之前就已计算好滚动方向，会话层（cgSessionEventTap）上修改增量不会有任何可见效果。
func installTap() -> Bool {
    let eventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .tailAppendEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: eventTapCallback,
        userInfo: nil
    ) else {
        return false
    }
    if let source = runLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = nil
    }
    if let old = eventTap {
        CFMachPortInvalidate(old)
        eventTap = nil
    }
    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    runLoopSource = source
    return true
}

/// HID 输入回调：任何鼠标设备的值变化都会到这里，只关心滚轮元素。
let hidValueCallback: IOHIDValueCallback = { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    // 0x01/0x38 = 垂直滚轮；0x0C/0x238 = 水平滚轮（AC Pan）
    guard (page == 0x01 && usage == 0x38) || (page == 0x0C && usage == 0x238) else { return }
    let wheelValue = IOHIDValueGetIntegerValue(value)
    let now = CFAbsoluteTimeGetCurrent()
    logDebug("HID：滚轮报告 usage=\(usage) v=\(wheelValue)")
    // 零值报告（传感器噪声/重复值）不更新时间戳，也不参与自愈判定
    guard wheelValue != 0 else { return }
    // 停止超过 0.5 秒后再次滚动视为新一轮突发
    if now - lastRealWheelReportAt > 0.5 {
        wheelBurstStartAt = now
    }
    lastRealWheelReportAt = now
    lastMouseWheelAt = now
    // 自愈：真实滚轮持续滚动超过 0.5 秒，但 CG 事件流中断超过 0.5 秒
    // → 事件监听被系统静默失效，重建它。
    if now - wheelBurstStartAt > 0.5, now - lastWheelCGEventAt > 0.5, now - lastRebuildAttemptAt > 10.0 {
        lastRebuildAttemptAt = now
        tapInterrupted = true
        if installTap() {
            rebuildFailures = 0
            logDebug("⚠️ 检测到滚轮事件流中断，事件监听已重建")
        } else {
            rebuildFailures += 1
            logDebug("⚠️ 检测到滚轮事件流中断，且重建失败（辅助功能权限可能被关闭）第 \(rebuildFailures) 次")
            if rebuildFailures >= 10 {
                fail("""
                事件监听反复重建失败，“辅助功能”权限可能被收回。

                请检查：系统设置 → 隐私与安全性 → 辅助功能 → 「滚轮反转」开关是否打开。
                （LaunchAgent 会在数秒后自动重启本程序）
                """)
            }
        }
    }
}

/// 开启 HID 层的鼠标滚轮监测（被动监听，不独占设备）。
func setupMouseWheelMonitor() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
    let matching = [kIOHIDDeviceUsagePageKey as String: 1, kIOHIDDeviceUsageKey as String: 2] as CFDictionary
    IOHIDManagerSetDeviceMatching(manager, matching)
    IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue as CFString)
    let result = IOHIDManagerOpen(manager, IOOptionBits(0))
    guard result == kIOReturnSuccess else {
        logDebug("HID 滚轮监测开启失败（错误 0x\(String(result, radix: 16))），将只反转离散滚轮事件")
        return
    }
    hidManager = manager
    logDebug("HID 滚轮监测已开启")
}

/// 最近是否检测到物理滚轮动作。
func mouseWheelRecentlyActive() -> Bool {
    guard hidManager != nil else { return false }
    return CFAbsoluteTimeGetCurrent() - lastMouseWheelAt < mouseWheelWindow
}

/// repost 模式：创建反转后的合成事件并注入系统，原事件由调用方吞掉。
/// 合成事件携带本进程 pid，回调里据此识别避免无限循环。
func repostInverted(_ event: CGEvent) {
    let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let pd1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    guard let reposted = CGEvent(
        scrollWheelEvent2Source: nil, units: .line,
        wheelCount: 1, wheel1: Int32(-d1), wheel2: 0, wheel3: 0
    ) else { return }
    if d1 == 0, pd1 != 0 {
        reposted.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pd1)
    }
    logDebug("repost：注入反转事件 d1=\(-d1)")
    reposted.post(tap: .cghidEventTap)
}

/// C 函数指针回调，不能捕获上下文，只能访问全局变量。
let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        logDebug("事件监听被系统禁用（\(type == .tapDisabledByTimeout ? "超时" : "用户输入")），正在重新启用")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return nil
    case .scrollWheel:
        if tapInterrupted {
            tapInterrupted = false
            logDebug("✅ 滚轮事件流已恢复")
        }
        lastWheelCGEventAt = CFAbsoluteTimeGetCurrent()
        // repost 模式：自己注入的事件直接放行，硬件事件吞掉后重新注入反转版
        if invertMode == .repost,
           event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            if event.getIntegerValueField(.eventSourceUnixProcessID) == Int32(getpid()) {
                return Unmanaged.passUnretained(event)
            }
            logScrollEvent(event, action: "离散 → repost 反转")
            repostInverted(event)
            return nil
        }
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            // 离散事件：一定来自传统滚轮，直接反转。
            logScrollEvent(event, action: "离散 → 已反转")
            invertScrollEvent(event)
        } else if mouseWheelRecentlyActive() {
            // 连续事件但物理滚轮刚动过：平滑滚轮/系统惯性，反转。
            logScrollEvent(event, action: "连续·滚轮近期有动作 → 已反转")
            invertScrollEvent(event)
        } else {
            // 连续事件且滚轮没动：触摸板手势，放行。
            logScrollEvent(event, action: "连续 → 放行")
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let help = """
用法：ScrollReverser [选项]

选项：
  --invert-x             同时反转水平滚动（滚轮左右倾斜）
  --mode=delta           只反转行增量（默认，macOS 26 验证有效）
  --mode=fields          反转全部增量字段（旧系统可用）
  --mode=repost          吞掉原事件并注入反转的合成事件（终极后备）
  --debug                调试模式：把每个滚轮事件记录到日志（排查用）
  -h, --help             显示本帮助

说明：
  反转鼠标滚轮（含平滑滚轮、系统惯性滚动）的方向；
  触摸板手势不受影响。适配 macOS 13+，含 macOS 26 (Tahoe)。
"""

for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--invert-x", "--invert-horizontal":
        invertHorizontal = true
    case "--mode=delta":
        invertMode = .deltaOnly
    case "--mode=fields":
        invertMode = .allFields
    case "--mode=repost":
        invertMode = .repost
    case "--debug":
        debug = true
    case "-h", "--help":
        print(help)
        exit(0)
    default:
        fail("未知参数：\(arg)\n\n\(help)")
    }
}

guard installTap() else {
    fail("""
    无法创建事件监听（CGEventTap），通常是没有“辅助功能”权限。

    授权步骤：
      1. 系统设置 → 隐私与安全性 → 辅助功能
      2. 若列表中已有 ScrollReverser / 滚轮反转，把它的开关关掉再打开；
         否则点 “+” 添加：~/Applications/ScrollReverser.app
      3. 授权后 LaunchAgent 会自动恢复运行（约 10 秒内重试成功）；
         也可手动重启：launchctl kickstart -k gui/\(getuid())/com.local.scroll-reverser
    """)
}

setupMouseWheelMonitor()

print("滚轮反转已启动（PID \(getpid())）：鼠标滚轮已反转，触摸板不受影响。")
if invertHorizontal {
    print("已同时反转水平方向（--invert-x）。")
}
if debug {
    print("调试模式：所有滚轮事件将记录到日志。")
}
fflush(stdout)

CFRunLoopRun()
