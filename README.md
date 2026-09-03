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

## 方案：四条腿

脚本守在被控 Mac 事件链的最上游（CGEventTap），做四件事：

1. **识别按键**：keycode 57/255 的 `flagsChanged` 且大写状态与上次不同 = 一次按键（不挑"开→关"方向，防止相位错位后失灵），600ms 防抖把脉冲余波合并成一次，然后切换 ABC ↔ 拼音；
2. **吞掉事件**：这些大写锁定事件用完后整个吞掉（`return true`），系统和输入法根本不知道有人按过 Caps Lock——没有蓝色 A⇧ 标记，拼音不会进大写模式；
3. **剥掉标志**：其余所有 keyDown/keyUp/flagsChanged/鼠标点击事件，把附带的 alphashift（大写锁定）标志位剥掉——即使底层状态短暂为"开"，打出来的也永远是小写，点进输入框也不会点亮系统的蓝色 <kbd>A⇧</kbd> 大写角标；"大写已关"的消息则洗净放行，让已挂出的角标能及时撤下。
4. **空闲保洁（治顽固角标）**：系统的蓝色大写角标不听事件、直接读底层状态，而状态每按一次键就翻转一次，翻到"开"时角标就亮。活跃期写状态必然和通用控制打架（见下），所以只在**用户完全空闲 ≥5 秒**时悄悄清一次，每轮空闲期最多一次；配合两道护栏——切换延迟 0.12 秒执行（期间若跟来打字键，判定为通用控制的"顺带同步"伪装信号，取消切换）、清理被对方压回就本轮收手（防拉锯）。实测：角标挂着时手离开键盘 6 秒即自动熄灭。

通用控制内部的大写状态**活跃期一个字节不碰**（空闲保洁是唯一例外，且有护栏），从根本上避免同步冲突。

## 蓝色大写角标：为什么被控端治不了，以及终极解法

（v8 上线一个月后的实战复盘，2026-09）

**现象**：即便 v8 的空闲保洁把状态清掉了，一恢复打字角标又亮。

**证据**：`switch.log` 一个月的统计——保洁清理 **50 次**，其中 **36 次**在用户恢复打字的第一个按键上，通用控制就把大写状态压了回来（被护栏拦下、没有误切换，但灯又亮了）。

**结论**：大写状态的"真身"在通用控制的虚拟键盘里——它每次向被控 Mac 送按键时都会重申自己记着的锁定状态，被控端任何清理都只是擦掉投影。而这个角标（macOS Sonoma 起的"文字光标指示器"，由 `CursorUIViewService` 绘制）读的正是这个状态位。所以：**从被控端不可能让角标在打字期间保持熄灭，它亮不亮本质上取决于你按过多少次键的奇偶性。**

### 解法 A：关掉指示器本身（已实施，macOS 26.3 验证有效）

角标属于系统功能 `redesigned_text_cursor`，没有界面开关，但可以通过系统功能开关文件关闭（社区在 Sonoma/Sequoia 上验证过，本项目在 macOS 26.3 上验证有效）。在**被控 Mac** 上执行：

```bash
sudo mkdir -p /Library/Preferences/FeatureFlags/Domain && sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool NO
```

然后**重启**生效。想恢复就把 `NO` 改成 `YES` 再重启。注意：需要管理员权限、非苹果官方支持、未来系统版本可能失效；会连带关闭光标旁的其他指示器（如切换输入法时的小提示）。在被控 Mac 上大写状态本来就没有任何意义（本脚本已剥掉一切大写效果），所以关掉零损失。

### 解法 B：从源头消灭大写锁定（未实测，治本思路）

在**主控 Mac** 上用苹果自带的 `hidutil` 把 Caps Lock 重映射为一个空闲功能键（如 F18），再把两台 Mac 的系统快捷键"选择上一个输入法"都设为 F18。这样中/英键从源头就不再产生大写锁定状态：本机按它走原生切换，控制远端时 F18 作为普通按键被通用控制忠实转发、被控端同样走原生切换。理论上无需本脚本、无防抖延迟、无角标，还顺带解决主控 Mac 本机"短按被误判为大写"的老毛病。代价：主控 Mac 本机也失去大写锁定（按住 Shift 代替）。欢迎实测反馈。

## 安装

**0. 前提**：被控 Mac 已启用两个输入法（如 ABC + 简体拼音）。

**1. 装 Hammerspoon**（开源的 macOS 自动化工具，[github.com/Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon)）：

```bash
brew install --cask hammerspoon
```

**2. 放置配置**：把本仓库的 `init.lua` 放到被控 Mac 的 `~/.hammerspoon/init.lua`（已有配置的话把内容合并进去）。

**3. 授权**：启动 Hammerspoon，在 系统设置 → 隐私与安全性 → 辅助功能 中允许 Hammerspoon（eventtap 必需），然后点菜单栏图标 → Reload Config。

**4. 开机自启（可选）**：勾选 Hammerspoon 偏好设置里的 "Launch Hammerspoon at login"，或在 Hammerspoon Console 执行一次 `hs.autoLaunch(true)`。

> 不建议用 `open -a Hammerspoon` 之类的 LaunchAgent 实现自启：macOS 会把它登记成大众脸的 "open"，"后台活动"通知每次重启都会重新弹一遍，很烦。用 Hammerspoon 自带的登录启动则以应用本尊的名义注册，安静得多。

## 自定义

`init.lua` 开头三个常量：

```lua
local ABC      = "com.apple.keylayout.ABC"                  -- 英文输入法 ID
local PINYIN   = "com.apple.inputmethod.SCIM.ITABC"         -- 中文输入法 ID
local DEBOUNCE = 0.6   -- 防抖窗口(秒)
local DEFER    = 0.12  -- 切换延迟(秒),防"同步伪装按键"误触发
local IDLE     = 5     -- 空闲保洁的空闲判定秒数
```

- 输入法 ID 可在 Hammerspoon Console 里执行 `hs.keycodes.currentSourceID()` 查看（先手动切到目标输入法再执行）。用微信输入法、搜狗等第三方输入法的话改成对应 ID 即可。
- 防抖窗口实测可以压到 0.3s（回声余波两倍余量），更跟手，但保守起见默认 0.6s。

## 已知限制

- **被控 Mac 上大写锁定键不再锁大写**（这是刻意的，让它专职切输入法，和中文键盘上这个键的本职一致）。要连续大写请按住 Shift。
- 600ms 防抖意味着一秒内连按多次只认第一次；切换在按键后延迟 0.12 秒执行（防误触发护栏）。正常使用均无感，参数可调（见上）。
- 若某次按键连事件都没传到被控 Mac（被主控 Mac 自己吃掉了），本方案无从接手——用 Ctrl+空格 兜底（系统自带快捷键，不受此 bug 影响）。
- 仅在 macOS 26.3（Tahoe）+ Hammerspoon 1.1.1 上实测。事件模式若随系统版本变化，欢迎提 issue 附抓包日志。

## 排查

脚本会把每次切换写进 `~/.hammerspoon/switch.log`（每次 Reload 清空）。命令行查看运行状态：

```bash
hs -c "capsWatcher:isEnabled()"
```

## License

MIT
