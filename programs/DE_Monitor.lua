-- Reactor and energy core stats on a monitor. Any computer with a monitor and a wireless or ender modem:
-- it draws what the DE_Reactor and DE_Core computers broadcast, on every monitor it has, by shape:
-- a short strip (1 block high) is a row of thick gauges, a wide monitor shows reactor and core side by
-- side, a narrower one has REACTOR / CORE buttons on its bottom row (right-click to switch).
-- A speaker on this computer sounds the same alarm Butler does.
-- @desc Draconic reactor + energy core stats on a monitor, touch to switch (needs DE_Reactor / DE_Core running)
-- @deps cn_lib de_view
-- @config TextScale|Monitor text scale (0.5 = most data)|0.5
local cfg = dofile("/lib/cn.lua")
local V = dofile("/lib/de_view.lua")
local SCALE = tonumber(cfg.TextScale) or 0.5
local VIEWS = { "REACTOR", "CORE" }
local BOTH = 100 -- columns from which reactor and core fit side by side
local STRIP = 14 -- rows under which a monitor is a strip of gauges

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
    mo.tabs = H >= STRIP and W < BOTH
    if H < STRIP then
      V.strip(win, 1, 1, W, H) -- has its own status line
    else
      local clock = os.date("%H:%M:%S")
      win.setCursorPos(1, 1)
      win.setBackgroundColour(V.alarm() and colours.red or colours.blue)
      win.setTextColour(colours.white)
      win.write((" DRACONIC REACTOR" .. (" "):rep(W)):sub(1, W - #clock - 1) .. clock .. " ")
      if mo.tabs then
        local screen = mo.view == "CORE" and V.core or V.reactor
        screen(win, 1, 3, W, H - 3)
        V.tabs(win, H, W, VIEWS, mo.view)
      else
        local lw = math.floor(W / 2) - 1
        V.reactor(win, 1, 3, lw, H - 2)
        V.core(win, lw + 3, 3, W - lw - 2, H - 2)
      end
    end
    win.setVisible(true)
  end
end
local function redraw() pcall(draw) end -- a monitor resized or broken mid-frame: next frame sorts it out

local function touch()
  while true do
    local _, name, x, y = os.pullEvent("monitor_touch")
    for _, mo in ipairs(mons) do
      if mo.name == name and mo.tabs and y == mo.H then mo.view = VIEWS[V.tabAt(x, mo.W, #VIEWS)] end
    end
    redraw()
  end
end

print("showing the reactor on " .. #mons .. " monitor(s)" .. (speaker and ", alarm on the speaker" or ""))
redraw()
parallel.waitForAny(function() V.listen(redraw) end, function() V.alarmLoop(speaker, redraw) end, touch)
