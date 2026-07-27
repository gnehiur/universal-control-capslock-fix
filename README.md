# universal-control-capslock-fix

修复 macOS **通用控制（Universal Control）** 下，中文键盘的 **中/英键（Caps Lock）无法切换输入法** 的问题。

> **TL;DR (English):** Over Universal Control, macOS forwards the Caps Lock key to the remote Mac as a bare caps-lock toggle (virtual keycode 255) and drops its "switch input source" semantics. This Hammerspoon script intercepts those events on the remote Mac, uses them as an input-source-switch signal, swallows them so the system never sees Caps Lock, and strips the alphashift flag from all other key events. Result: the 中/英 key switches ABC ↔ Pinyin on the controlled Mac, with no caps-lock side effects.

## 现象

用一台 Mac（比如 MacBook）通过通用控制操控另一台 Mac（比如 Mac mini）时，按中文键盘上的中/英键（就是 Caps Lock 键）：

- ❌ 被控 Mac 的输入法**不会切换**
- ❌ 反而经常触发**大写锁定**，打出来全是大写字母
- ❌ 输入框旁边出现蓝色 <kbd>A⇧</kbd> 大写标记，拼音输入法进入"大写英文"模式

这是 macOS 的已知 bug，苹果多年未修：**"短按 Caps Lock 切换输入法"的判定只在键盘直连的那台 Mac 上生效**，通用控制转发按键时只保留了"大写锁定"这一层语义。相关讨论：

- [Apple 社区：Universal Control - issue with Caps Lock](https://discussions.apple.com/thread/254457459)
- [Apple 社区：Universal control can not switch language](https://discussions.apple.com/thread/254700984)
- [V2EX：关于 macOS 通用控制输入法切换的 Bug](https://www.v2ex.com/t/842450)

社区流行的"解决方案"都是绕路：改用 Ctrl+空格、换 Fn 键、用 Karabiner 映射别的键。**本项目把中/英键本身救活**——在被控 Mac 上体验和原生几乎一致。

## 原理：抓包发现了什么

用 Hammerspoon 的 eventtap 在被控 Mac 上抓事件，得到三条关键事实（这也是网上搜不到的部分）：

**1. 中/英键被转成 255 号虚拟键**

通用控制转发过来的不是标准 Caps Lock（keycode 57），而是 `flagsChanged` 事件、keycode **255**。这就是为什么监听 57 号键的常规方案全部失效。

**2. 一次按键 = 两对"开→关"脉冲**

一次物理按键，被控 Mac 实际收到最多 **4 个事件**（按下、松开各产生一对大写状态"开→关"的脉冲）：

```
44.370s  caps → 开     ← 按下
44.402s  caps → 关     ← 32ms 后
44.506s  caps → 开     ← 松开
44.510s  caps → 关     ← 4ms 后
```

对内间隔 4~30ms，整个余波在 350ms 内散完。若把每个状态变化都当一次按键，就会"切 4 次转一圈回到原点"，表现为图标闪一下又弹回去。长按时状态则会保持"开"直到松开。

**3. 大写状态归通用控制管，本地绝对不能写**

被控 Mac 上任何 `capslock.set(false)` 之类的"纠正"，都会在下一次击键时被通用控制**强行同步回来**，形成拉锯：轻则敲一个字切一次输入法的风暴，重则相位错位、按键完全失效。本项目开发过程中在这上面翻过两次车，实测结论：**它的状态只许看、不许写**。

## 方案：三条腿

脚本守在被控 Mac 事件链的最上游（CGEventTap），做三件事：

1. **识别按键**：keycode 57/255 的 `flagsChanged` 且大写状态与上次不同 = 一次按键（不挑"开→关"方向，防止相位错位后失灵），600ms 防抖把脉冲余波合并成一次，然后切换 ABC ↔ 拼音；
2. **吞掉事件**：这些大写锁定事件用完后整个吞掉（`return true`），系统和输入法根本不知道有人按过 Caps Lock——没有蓝色 A⇧ 标记，拼音不会进大写模式；
3. **剥掉标志**：其余所有 keyDown/keyUp/flagsChanged 事件，把附带的 alphashift（大写锁定）标志位剥掉——即使底层状态短暂为"开"，打出来的也永远是小写。

通用控制内部的大写状态从头到尾一个字节不碰，从根本上避免同步冲突。

## 安装

**0. 前提**：被控 Mac 已启用两个输入法（如 ABC + 简体拼音）。

**1. 装 Hammerspoon**（开源的 macOS 自动化工具，[github.com/Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon)）：

```bash
brew install --cask hammerspoon
```

**2. 放置配置**：把本仓库的 `init.lua` 放到被控 Mac 的 `~/.hammerspoon/init.lua`（已有配置的话把内容合并进去）。

**3. 授权**：启动 Hammerspoon，在 系统设置 → 隐私与安全性 → 辅助功能 中允许 Hammerspoon（eventtap 必需），然后点菜单栏图标 → Reload Config。

**4. 开机自启（可选）**：把 `org.hammerspoon.autostart.plist` 放到 `~/Library/LaunchAgents/` 并执行：

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.hammerspoon.autostart.plist
```

（用了这个就不要再勾 Hammerspoon 自带的 "Launch at login"，会重复。）

## 自定义

`init.lua` 开头三个常量：

```lua
local ABC      = "com.apple.keylayout.ABC"                  -- 英文输入法 ID
local PINYIN   = "com.apple.inputmethod.SCIM.ITABC"         -- 中文输入法 ID
local DEBOUNCE = 0.6                                        -- 防抖窗口(秒)
```

- 输入法 ID 可在 Hammerspoon Console 里执行 `hs.keycodes.currentSourceID()` 查看（先手动切到目标输入法再执行）。用微信输入法、搜狗等第三方输入法的话改成对应 ID 即可。
- 防抖窗口实测可以压到 0.3s（回声余波两倍余量），更跟手，但保守起见默认 0.6s。

## 已知限制

- **被控 Mac 上大写锁定键不再锁大写**（这是刻意的，让它专职切输入法，和中文键盘上这个键的本职一致）。要连续大写请按住 Shift。
- 600ms 防抖意味着一秒内连按多次只认第一次。正常使用无感，强迫症可调小（见上）。
- 若某次按键连事件都没传到被控 Mac（被主控 Mac 自己吃掉了），本方案无从接手——用 Ctrl+空格 兜底（系统自带快捷键，不受此 bug 影响）。
- 仅在 macOS 26（Tahoe）+ Hammerspoon 1.1.1 上实测。事件模式若随系统版本变化，欢迎提 issue 附抓包日志。

## 排查

脚本会把每次切换写进 `~/.hammerspoon/switch.log`（每次 Reload 清空）。命令行查看运行状态：

```bash
hs -c "capsWatcher:isEnabled()"
```

## License

MIT
