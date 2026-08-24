# MouseWheelReverser · 滚轮反转

只反转**鼠标滚轮**的滚动方向、**触摸板不受影响**的 macOS 轻量工具。
特别适配 **macOS 26 (Tahoe)** 的滚动事件管线变更——同类老工具（Scroll Reverser、Mos、UnnaturalScrollWheels）在新系统上集体失效的问题已解决。

纯本地命令行守护进程 + 开机自启，无 UI 常驻、无网络行为。

## 特性

- ✅ 只反转鼠标滚轮方向，触摸板 / Magic Mouse 手势完全不受影响
- ✅ 支持 MX Master 等高分辨率/平滑/无极滚轮，以及系统为蓝牙鼠标合成的惯性滚动
- ✅ **适配 macOS 26 (Tahoe)**：在 HID 层拦截（会话层修改在新系统已无效，见[技术说明](#macos-26-tahoe-技术说明)）
- ✅ 自愈机制：事件监听被系统静默失效时自动重建，无需重启
- ✅ 固定本地证书签名：升级、重新编译后**不需要**重新授权
- ✅ 无障碍权限缺失时自动重试，授权后 10 秒内自动恢复

## 系统要求

- macOS 13+（在 macOS 26.5 / Apple Silicon 上验证）
- Xcode Command Line Tools：没有就执行 `xcode-select --install`

## 快速开始

```bash
git clone https://github.com/BI4IWN/MouseWheelReverser.git
cd MouseWheelReverser
./install.sh
```

安装脚本会：编译 → 打包 `~/Applications/ScrollReverser.app` → 注册 LaunchAgent 开机自启。

然后**手动授权一次**（必须，否则无法拦截事件）：

1. 打开 系统设置 → 隐私与安全性 → **辅助功能**
2. 列表出现「滚轮反转 / ScrollReverser」就打开开关；没有就点 “+” 添加
   `~/Applications/ScrollReverser.app`（文件对话框里按 `Cmd+Shift+G` 输入路径）
3. 授权后最多 10 秒自动生效

> 前提：系统设置里的「滚动方向：自然」保持**打开**。
> 这样触摸板是自然滚动，鼠标滚轮被本工具反转变回传统方向。

## 工作原理

macOS 把滚轮事件分为两类，程序通过 HID 层 CGEventTap 全局拦截并区别处理：

| 事件类型 | 来源 | 处理 |
|---|---|---|
| 离散事件（IsContinuous = 0） | 传统滚轮 | 反转行增量 DeltaAxis1 |
| 连续事件 + 物理滚轮 0.6 秒内有动作 | 平滑滚轮 / 系统惯性 | 反转 |
| 连续事件 + 滚轮无动作 | 触摸板手势 | 原样放行 |

「物理滚轮是否刚动过」由 IOHIDManager 在**硬件层**被动监测判断（不独占设备），
这也是自愈机制的旁证：真实滚轮持续滚动而 CG 事件流中断超过 0.5 秒 → 自动重建事件监听。

## macOS 26 (Tahoe) 技术说明

如果你在维护类似的滚轮工具，这些是用日志逐事件验证过的结论：

1. **会话层修改已无效**：`cgSessionEventTap` 上反转增量，事件确实被修改、应用照常收到，
   但屏幕上的滚动方向**纹丝不动**——系统的平滑滚动引擎在会话层之前就已完成方向计算。
   [Scroll Reverser #200](https://github.com/pilotmoon/Scroll-Reverser/issues/200)、
   [Mos #767](https://github.com/Caldis/Mos/issues/767)、
   [UnnaturalScrollWheels #106](https://github.com/ther0n/UnnaturalScrollWheels/issues/106)
   都是这个坑。
2. **正确姿势**：挂在 HID 层 `cghidEventTap` + `tailAppendEventTap`，且**只反转 DeltaAxis1**
   （与 UnnaturalScrollWheels 1.3.0 在 macOS 26 上被用户确认有效的方式一致）。
   反转全部三个增量字段（Delta/PointDelta/FixedPt）时系统会忽略修改。
3. **高分辨率滚轮噪声**：MX Master 3S 等鼠标的滚轮传感器空闲时也以约 100Hz 持续发送
   **零值**报告，必须按值过滤，否则会淹没日志并触发自愈误判。
4. **事件监听静默失效**：CGEventTap 可能被系统失效且不回调任何通知，
   需要独立旁证（如本项目的 HID 监测）来检测并重建。

## 选项

安装时把参数传给 `./install.sh` 即永久生效（如 `./install.sh --invert-x`）：

| 选项 | 说明 |
|---|---|
| `--invert-x` | 同时反转水平方向（滚轮左右倾斜） |
| `--mode=delta` | 只反转行增量（**默认**，macOS 26 验证有效） |
| `--mode=fields` | 反转全部增量字段（旧系统可用） |
| `--mode=repost` | 吞掉原事件并注入反转的合成事件（终极后备手段） |
| `--debug` | 记录每个滚轮事件到日志（排查用） |

## 日志与卸载

```bash
tail -f ~/Library/Logs/scroll-reverser.log   # 日志
./uninstall.sh                               # 停止并完全卸载
```

## 常见问题

- **为什么不用系统自带的“自然滚动”开关？** 那个开关同时影响鼠标和触摸板。
  本工具让你两者各走各的方向：触摸板保持自然滚动，鼠标滚轮是传统方向。
- **Magic Mouse 会被反转吗？** 不会。Magic Mouse 表面滚动属于连续手势事件，
  与触摸板同等对待（事件层面无法区分两者）。
- **重新编译后失效？** 本项目安装脚本会优先使用本地固定证书签名（首次运行自动创建），
  签名稳定则授权不受重编译影响。若用的是回退的 ad-hoc 签名（无证书机器），
  到“辅助功能”里把开关关掉再打开即可。
- **隐私：** 纯本地运行，无任何网络行为，只处理滚轮事件。

## 致谢

- [UnnaturalScrollWheels](https://github.com/ther0n/UnnaturalScrollWheels) — macOS 26 兼容的关键思路来源
- [Scroll Reverser](https://pilotmoon.com/scrollreverser/) / [Mos](https://github.com/Caldis/Mos) — 领域先驱

## License

[MIT](LICENSE)
