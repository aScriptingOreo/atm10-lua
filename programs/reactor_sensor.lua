-- Computer A: next to the reactor redstone port (Energy mode). Broadcasts gate state over rednet.
-- @desc Oritech reactor redstone port -> rednet gate broadcast
-- @deps cn_lib
-- @config ReactorName|Reactor name (same on sensor + RS computer)
-- @config InSide|Side touching redstone port comparator|back
local cfg = dofile("/lib/cn.lua")
local IN_SIDE = cfg.InSide or "back" -- side touching the port's comparator output
local PROTO = "reactor:" .. (cfg.ReactorName or error("cookienet config ReactorName=<name>", 0))
local HEARTBEAT = 10   -- seconds; receiver fails closed if it hears nothing for longer

rednet.open(peripheral.getName(peripheral.find("modem")))
local function send()
  local sig = redstone.getAnalogInput(IN_SIDE)
  rednet.broadcast({ open = sig > 0, signal = sig }, PROTO)
  print(("signal=%d gate=%s"):format(sig, sig > 0 and "open" or "closed"))
end

while true do
  send()
  local t = os.startTimer(HEARTBEAT)
  repeat
    local e, id = os.pullEvent()
    if e == "redstone" then break end
  until e == "timer" and id == t
end
