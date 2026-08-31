# MouseWheelReverser · 滚轮反转

只反转**鼠标滚轮**的滚动方向、**触摸板不受影响**的 macOS 轻量工具，并附带**手势键**与**前进/后退侧键**增强功能。
特别适配 **macOS 26 (Tahoe)** 的滚动事件管线变更——同类老工具（Scroll Reverser、Mos、UnnaturalScrollWheels）在新系统上集体失效的问题已解决。

纯本地命令行守护进程 + 开机自启，无 UI 常驻、无网络行为。

## 特性

- ✅ 只反转鼠标滚轮方向，触摸板 / Magic Mouse 手势完全不受影响
- ✅ 支持 MX Master 等高分辨率/平滑/无极滚轮，以及系统为蓝牙鼠标合成的惯性滚动
- ✅ **手势键**：按住鼠标手势键（如 MX Master 拇指键）并移动——左/右=切换桌面空间，上=任务控制，下=应用窗口（检测到 MX Master 系列自动启用）
- ✅ **前进/后退侧键**：合成为 `Cmd+[` / `Cmd+]`，浏览器、Finder 等全应用通用
- ✅ **按鼠标型号自动适配**：自动枚举识别（`--list-mice` 可查看）
- ✅ **适配 macOS 26 (Tahoe)**：HID 层拦截 + 自愈（见[技术说明](#macos-26-tahoe-技术说明)）
- ✅ 固定本地证书签名：升级、重新编译后**不需要**重新授权

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

## 按钮与手势

### 前进 / 后退侧键（任何 5 键以上鼠标）

默认把侧键拦截并合成为 `Cmd+[`（后退）/ `Cmd+]`（前进），比系统原生映射覆盖面更广。
想用回系统原生行为：`./install.sh --nav=native`。

### 手势键（MX Master 系列自动启用）

按住手势键（MX Master 拇指位置的宽键）并移动鼠标：

| 方向 | 动作 |
|---|---|
| 左 / 右 | 切换到上一个 / 下一个桌面空间 |
| 上 | 任务控制（Mission Control） |
| 下 | 当前应用的所有窗口（App Exposé） |

- 单击（不移动）默认无动作，`--gesture-click=mission` 可设为打开任务控制
- 其他型号鼠标强制开启：`--gesture=on --gesture-button=N`（用 `--debug` 日志可查按钮编号）
- 关闭：`--gesture=off`

### 查看鼠标型号

```bash
./ScrollReverser --list-mice   # 安装后: ~/Applications/ScrollReverser.app/Contents/MacOS/ScrollReverser --list-mice
```

## 工作原理

macOS 把滚轮事件分为两类，程序通过 HID 层 CGEventTap 全局拦截并区别处理：

| 事件类型 | 来源 | 处理 |
|---|---|---|
| 离散事件（IsContinuous = 0） | 传统滚轮 | 反转行增量 DeltaAxis1 |
| 连续事件 + 物理滚轮 0.6 秒内有动作 | 平滑滚轮 / 系统惯性 | 反转 |
| 连续事件 + 滚轮无动作 | 触摸板手势 | 原样放行 |

「物理滚轮是否刚动过」由 IOHIDManager 在**硬件层**被动监测判断（不独占设备）。
按钮功能同样在 HID 层监测（Usage Page 9），方向手势通过累积 X/Y 位移判定。

## macOS 26 (Tahoe) 技术说明

如果你在维护类似的滚轮/按钮工具，这些是用日志逐事件验证过的结论：

1. **会话层修改已无效**：`cgSessionEventTap` 上反转增量，事件确实被修改、应用照常收到，
   但屏幕上的滚动方向**纹丝不动**——系统的平滑滚动引擎在会话层之前就已完成方向计算。
   [Scroll Reverser #200](https://github.com/pilotmoon/Scroll-Reverser/issues/200)、
   [Mos #767](https://github.com/Caldis/Mos/issues/767)、
   [UnnaturalScrollWheels #106](https://github.com/ther0n/UnnaturalScrollWheels/issues/106)
   都是这个坑。
2. **正确姿势**：挂在 HID 层 `cghidEventTap` + `tailAppendEventTap`，且**只反转 DeltaAxis1**
   （与 UnnaturalScrollWheels 1.3.0 在 macOS 26 上被用户确认有效的方式一致）。
   反转全部三个增量字段（Delta/PointDelta/FixedPt）时系统会忽略修改。
3. **合成键盘事件无法触发系统级快捷键**：`Ctrl+方向键`（任务控制/切换空间）无论用什么
   事件源、是否带完整修饰键序列，系统一概无视——只有**应用级**快捷键（如 `Cmd+[`）有效。
   规避：任务控制直接 `open /System/Applications/Mission Control.app`；
   切换空间/应用窗口通过 System Events（osascript 特权通道）发送。
4. **高分辨率滚轮噪声**：MX Master 3S 等鼠标的滚轮传感器空闲时也以约 100Hz 持续发送
   **零值**报告，必须按值过滤，否则会淹没日志并触发自愈误判。
5. **事件监听静默失效**：CGEventTap 可能被系统失效且不回调任何通知，
   需要独立旁证（如本项目的 HID 监测）来检测并重建。

## 选项

安装时把参数传给 `./install.sh` 即永久生效（如 `./install.sh --invert-x --gesture-click=mission`）：

| 选项 | 说明 |
|---|---|
| `--invert-x` | 同时反转水平方向（滚轮左右倾斜） |
| `--mode=delta` | 只反转行增量（**默认**，macOS 26 验证有效） |
| `--mode=fields` | 反转全部增量字段（旧系统可用） |
| `--mode=repost` | 吞掉原事件并注入反转的合成事件（终极后备手段） |
| `--nav=keys` / `--nav=native` | 侧键：合成 `Cmd+[`/`Cmd+]`（默认）/ 系统原生 |
| `--gesture=auto` / `on` / `off` | 手势键：MX Master 自动开启（默认）/ 强制开 / 关 |
| `--gesture-button=N` | 手势键的 HID 按钮编号（默认 6） |
| `--gesture-click=none` / `mission` | 手势键单击动作 |
| `--debug` | 记录每个滚轮/按钮事件到日志（排查用） |

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
- **手势键切空间没反应？** 左右切换需要至少两个桌面空间（任务控制里把鼠标移到
  顶部可添加）。上方向的任务控制不受此影响。
- **重新编译后失效？** 本项目安装脚本会优先使用本地固定证书签名（首次运行自动创建），
  签名稳定则授权不受重编译影响。若用的是回退的 ad-hoc 签名（无证书机器），
  到“辅助功能”里把开关关掉再打开即可。
- **隐私：** 纯本地运行，无任何网络行为，只处理滚轮与按钮事件。

## 致谢

- [UnnaturalScrollWheels](https://github.com/ther0n/UnnaturalScrollWheels) — macOS 26 兼容的关键思路来源
- [Scroll Reverser](https://pilotmoon.com/scrollreverser/) / [Mos](https://github.com/Caldis/Mos) — 领域先驱

## License

[MIT](LICENSE)
