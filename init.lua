-- universal-control-capslock-fix v8
-- 修复 macOS 通用控制下中/英键(Caps Lock)无法切换输入法的问题。原理见 README。
-- https://github.com/jncdke/universal-control-capslock-fix
--
-- 铁律: 通用控制自己记着大写状态,被控端活跃期绝不许写,
--       任何按键动作进行中的 capslock.set() 都会引发"重新同步风暴"。
-- v8 新增"空闲保洁": 底层大写状态挂在"开"会点亮系统蓝色A角标(状态驱动,事件治不了),
-- 只在用户完全空闲>=IDLE秒时悄悄清一次,并带三重护栏:
--   护栏1: 只清空闲时刻,绝不在按键动作进行中碰状态
--   护栏2: 切换延迟DEFER秒执行,期间若来了打字键=通用控制的"顺带同步"伪装信号,取消切换
--   护栏3: 清完0.6秒内若状态被压回"开",本轮空闲期收手不再清(防拉锯)

require("hs.ipc") -- 让终端 hs 命令能查询状态(可选)

-- ===== 配置区 =====
local ABC      = "com.apple.keylayout.ABC"          -- 英文输入法 ID
local PINYIN   = "com.apple.inputmethod.SCIM.ITABC" -- 中文输入法 ID
local DEBOUNCE = 0.6  -- 一次按键的脉冲余波合并窗口(秒),可试 0.3
local DEFER    = 0.12 -- 护栏2: 切换延迟(秒)
local IDLE     = 5    -- 护栏1: 空闲判定秒数
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

local types = hs.eventtap.event.types
local lastSeen = hs.hid.capslock.get()
local lastTrigger = 0
local lastAnyActivity = hs.timer.secondsSinceEpoch()
local pending = nil           -- 待执行的切换(护栏2)
local selfClearUntil = 0      -- 保洁自产事件的豁免窗口
local clearedThisIdle = false -- 护栏3: 本轮空闲期是否已清过

local function stripCaps(e)
  local rf = e:rawFlags()
  if rf & ALPHASHIFT ~= 0 then
    e:rawFlags(rf & ~ALPHASHIFT)
  end
end

capsWatcher = hs.eventtap.new(
  {types.flagsChanged, types.keyDown, types.keyUp,
   types.leftMouseDown, types.leftMouseUp, types.rightMouseDown, types.rightMouseUp},
  function(e)
    local now = hs.timer.secondsSinceEpoch()
    lastAnyActivity = now
    local kc = e:getKeyCode()
    local t = e:getType()

    if t == types.flagsChanged then
      -- 57 = 本机键盘 Caps Lock; 255 = 通用控制转发的虚拟键号
      if kc == 57 or kc == 255 then
        local caps = hs.hid.capslock.get()
        local capsRelated = (e:rawFlags() & ALPHASHIFT ~= 0) or (caps ~= lastSeen)
        if caps ~= lastSeen then
          -- 状态和上次不同 = 一次按键(不挑开关方向,防相位错位)
          lastSeen = caps
          if now < selfClearUntil then
            if caps then dlog("janitor: state re-imposed within guard window, backing off") end
            -- 豁免窗口内的变化不当按键处理
          elseif pending == nil and now - lastTrigger > DEBOUNCE then
            pending = hs.timer.doAfter(DEFER, function()
              pending = nil
              lastTrigger = hs.timer.secondsSinceEpoch()
              switchInput()
            end)
          end
        end
        if capsRelated or kc == 57 then
          if hs.hid.capslock.get() then
            return true -- "大写开了"的消息吞掉,系统和输入法看不到
          end
          stripCaps(e)
          return false -- "大写关了"的消息洗净放行,让界面撤掉蓝色角标
        end
      end
      stripCaps(e)
      return false
    end

    if t == types.keyDown then
      clearedThisIdle = false -- 真实活动恢复,保洁额度重置
      if pending then
        pending:stop(); pending = nil
        dlog("pending switch canceled by typing (resync guard)")
      end
      if kc == 57 then return true end -- 大写锁定键本体吞掉
      stripCaps(e) -- 剥掉大写标志:打字永远小写(要大写按住 Shift)
      return false
    end

    -- keyUp / 鼠标点击(点击也携带大写标志,一并剥掉,防点亮角标)
    if t ~= types.keyUp then clearedThisIdle = false end -- 鼠标点击也算真实活动
    if kc == 57 and t == types.keyUp then return true end
    stripCaps(e)
    return false
  end)
capsWatcher:start()

-- 空闲保洁: 完全空闲>=IDLE秒且状态挂"开"时清一次(每轮空闲期最多一次)
capsJanitor = hs.timer.doEvery(1, function()
  local now = hs.timer.secondsSinceEpoch()
  if hs.hid.capslock.get() and pending == nil and not clearedThisIdle
     and now - lastAnyActivity > IDLE and now >= selfClearUntil then
    clearedThisIdle = true
    selfClearUntil = now + 0.6
    lastSeen = false -- 预记账,自产的"关"事件不当按键
    hs.hid.capslock.set(false)
    dlog("janitor: cleared stale caps (idle)")
  end
end)
