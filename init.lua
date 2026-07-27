-- universal-control-capslock-fix
-- 修复 macOS 通用控制下中/英键(Caps Lock)无法切换输入法的问题。原理见 README。
-- https://github.com/jncdke/universal-control-capslock-fix
--
-- 铁律: 通用控制自己记着大写状态,被控端只许看、绝不许写,
--       任何 capslock.set() 都会引发"重新同步风暴"。

require("hs.ipc") -- 让终端 hs 命令能查询状态(可选)

-- ===== 配置区 =====
local ABC      = "com.apple.keylayout.ABC"          -- 英文输入法 ID
local PINYIN   = "com.apple.inputmethod.SCIM.ITABC" -- 中文输入法 ID
local DEBOUNCE = 0.6                                -- 防抖窗口(秒),可试 0.3
-- ==================

local ALPHASHIFT = 0x10000 -- 事件里"大写锁定"标志位

local dbg = io.open(os.getenv("HOME") .. "/.hammerspoon/switch.log", "w")
local function dlog(m)
  if dbg then dbg:write(string.format("%.3f %s\n", hs.timer.secondsSinceEpoch(), m)); dbg:flush() end
end

local function switchInput()
  local cur = hs.keycodes.currentSourceID()
  if cur == PINYIN then
    hs.keycodes.currentSourceID(ABC)
  else
    hs.keycodes.currentSourceID(PINYIN)
  end
  dlog("switched to " .. hs.keycodes.currentSourceID())
end

local lastSeen = hs.hid.capslock.get()
local lastTrigger = 0
local types = hs.eventtap.event.types

local function stripCaps(e)
  local rf = e:rawFlags()
  if rf & ALPHASHIFT ~= 0 then
    e:rawFlags(rf & ~ALPHASHIFT)
  end
end

capsWatcher = hs.eventtap.new(
  {types.flagsChanged, types.keyDown, types.keyUp},
  function(e)
    local kc = e:getKeyCode()
    if e:getType() == types.flagsChanged then
      -- 57 = 本机键盘 Caps Lock; 255 = 通用控制转发的虚拟键号
      if kc == 57 or kc == 255 then
        local caps = hs.hid.capslock.get()
        local capsRelated = (e:rawFlags() & ALPHASHIFT ~= 0) or (caps ~= lastSeen)
        if caps ~= lastSeen then
          -- 状态和上次不同 = 一次按键(不挑开关方向,防相位错位)
          lastSeen = caps
          local now = hs.timer.secondsSinceEpoch()
          if now - lastTrigger > DEBOUNCE then
            lastTrigger = now
            switchInput()
          end
        end
        if capsRelated or kc == 57 then
          return true -- 吞掉,系统和输入法看不到大写锁定
        end
      end
      stripCaps(e)
      return false
    end
    -- keyDown / keyUp
    if kc == 57 then return true end -- 大写锁定键本体也吞掉
    stripCaps(e) -- 剥掉大写标志,底层状态开着也照常打小写(要大写按住 Shift)
    return false
  end)
capsWatcher:start()
