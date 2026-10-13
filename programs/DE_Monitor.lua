-- Reactor and energy core stats on a monitor. Any computer with a monitor and a wireless or ender modem:
-- it draws what the DE_Reactor and DE_Core computers broadcast. A wide monitor shows both side by side,
-- a narrower one has REACTOR / CORE buttons on its bottom row (right-click to switch).
-- A speaker on this computer sounds the same alarm Butler does.
-- @desc Draconic reactor + energy core stats on a monitor, touch to switch (needs DE_Reactor / DE_Core running)
-- @deps cn_lib de_view
-- @config TextScale|Monitor text scale (0.5 = most data)|0.5
local cfg = dofile("/lib/cn.lua")
local V = dofile("/lib/de_view.lua")
local SCALE = tonumber(cfg.TextScale) or 0.5
local VIEWS = { "REACTOR", "CORE" }
local BOTH = 100 -- columns from which reactor and core fit side by side

if not V.open() then error("no modem: put a wireless or ender modem on this computer", 0) end
local mons = {}
peripheral.find("monitor", function(name, m)
  m.setTextScale(SCALE)
  mons[#mons + 1] = { name = name, m = m, view = "REACTOR" }
end)
if #mons == 0 then error("no monitor", 0) end
local speaker = peripheral.find("speaker")

local function draw()
  for _, mo in ipairs(mons) do
    local W, H = mo.m.getSize()
    mo.W, mo.H = W, H
    local win = window.create(mo.m, 1, 1, W, H, false) -- drawn hidden, shown once: no flicker
    win.setBackgroundColour(colours.black)
    win.clear()
    local alarm, clock = V.alarm(), os.date("%H:%M:%S")
    win.setCursorPos(1, 1)
    win.setBackgroundColour(alarm and colours.red or colours.blue)
    win.setTextColour(colours.white)
    win.write((" DRACONIC REACTOR" .. (" "):rep(W)):sub(1, W - #clock - 1) .. clock .. " ")
    if W >= BOTH then
      local lw = math.floor(W / 2) - 1
      V.reactor(win, 1, 3, lw, H - 2)
      V.core(win, lw + 3, 3, W - lw - 2, H - 2)
    else
      (mo.view == "CORE" and V.core or V.reactor)(win, 1, 3, W, H - 3)
      V.tabs(win, H, W, VIEWS, mo.view)
    end
    win.setVisible(true)
  end
end
local function redraw() pcall(draw) end -- a monitor resized or broken mid-frame: next frame sorts it out

local function touch()
  while true do
    local _, name, x, y = os.pullEvent("monitor_touch")
    for _, mo in ipairs(mons) do
      if mo.name == name and mo.W and mo.W < BOTH and y == mo.H then mo.view = VIEWS[V.tabAt(x, mo.W, #VIEWS)] end
    end
    redraw()
  end
end

print("showing the reactor on " .. #mons .. " monitor(s)" .. (speaker and ", alarm on the speaker" or ""))
redraw()
parallel.waitForAny(function() V.listen(redraw) end, function() V.alarmLoop(speaker, redraw) end, touch)
